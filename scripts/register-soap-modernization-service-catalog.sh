#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/soap-modernization-catalog.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

for command in curl jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "[soap-catalog] ERROR: required command not found: $command" >&2
    exit 1
  }
done

CLIENT_NAME="soap-modernization-catalog-$(date +%s)-$$"

cat > "$WORK_DIR/dcr.json" <<JSON
{
  "callbackUrl": "http://localhost:8080/callback",
  "clientName": "${CLIENT_NAME}",
  "owner": "${APIM_USER}",
  "grantType": "password refresh_token client_credentials",
  "saasApp": true
}
JSON

DCR_RESPONSE="$(
  curl -ksS \
    -u "${APIM_USER}:${APIM_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d @"$WORK_DIR/dcr.json" \
    "${APIM_URL}/client-registration/v0.17/register"
)"

CLIENT_ID="$(printf '%s' "$DCR_RESPONSE" | jq -r '.clientId // empty')"
CLIENT_SECRET="$(printf '%s' "$DCR_RESPONSE" | jq -r '.clientSecret // empty')"

if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
  echo "[soap-catalog] ERROR: DCR failed" >&2
  printf '%s\n' "$DCR_RESPONSE" >&2
  exit 1
fi

TOKEN_RESPONSE="$(
  curl -ksS \
    -u "${CLIENT_ID}:${CLIENT_SECRET}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${APIM_USER}" \
    --data-urlencode "password=${APIM_PASSWORD}" \
    --data-urlencode \
      'scope=service_catalog:service_view service_catalog:service_write' \
    "${APIM_URL}/oauth2/token"
)"

ACCESS_TOKEN="$(printf '%s' "$TOKEN_RESPONSE" | jq -r '.access_token // empty')"

if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "[soap-catalog] ERROR: token request failed" >&2
  printf '%s\n' "$TOKEN_RESPONSE" >&2
  exit 1
fi

cat > "$WORK_DIR/rest-metadata.json" <<'JSON'
{
  "name": "BillingAdjustmentModernizationAPI",
  "version": "1.0.0",
  "description": "WSO2 Integrator REST-to-SOAP modernization service with WS-Security, primary/DR failover, endpoint suspension and normalized legacy faults.",
  "serviceUrl": "http://wso2-mi:8290/billing-adjustments/v1",
  "definitionType": "OAS3",
  "securityType": "NONE",
  "mutualSSLEnabled": false
}
JSON

cat > "$WORK_DIR/soap-metadata.json" <<'JSON'
{
  "name": "LegacyBillingAdjustmentSOAPService",
  "version": "1.0.0",
  "description": "Legacy BSS SOAP 1.1 billing service. The Service Catalog entry uses an OpenAPI XML service descriptor because APIM validates catalog definitions as supported service specifications. The authoritative SOAP contract remains the repository WSDL.",
  "serviceUrl": "http://legacy-billing-primary:8080/LegacyBillingAdjustmentService",
  "definitionType": "OAS3",
  "securityType": "NONE",
  "mutualSSLEnabled": false
}
JSON

upsert_service() {
  local name="$1"
  local version="$2"
  local metadata="$3"
  local definition="$4"
  local mime_type="$5"

  local search
  local existing_id
  local response_file
  local status
  local method
  local url

  search="$(
    curl -ksS -G \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H 'Accept: application/json' \
      --data-urlencode "name=${name}" \
      --data-urlencode "version=${version}" \
      --data-urlencode 'limit=100' \
      "${APIM_URL}/api/am/service-catalog/v1/services"
  )"

  existing_id="$(
    printf '%s' "$search" |
      jq -r --arg n "$name" --arg v "$version" \
        'first(.list[]? | select(.name == $n and .version == $v) | .id) // empty'
  )"

  response_file="$WORK_DIR/${name}-response.json"

  if [[ -n "$existing_id" ]]; then
    method=PUT
    url="${APIM_URL}/api/am/service-catalog/v1/services/${existing_id}"
  else
    method=POST
    url="${APIM_URL}/api/am/service-catalog/v1/services"
  fi

  status="$(
    curl -ksS \
      -o "$response_file" \
      -w '%{http_code}' \
      -X "$method" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H 'Accept: application/json' \
      -F "definitionFile=@${definition};type=${mime_type}" \
      -F "serviceMetadata=@${metadata};type=application/json" \
      "$url"
  )"

  case "$status" in
    200|201)
      echo "[soap-catalog] ${name}:${version} registered (HTTP ${status})"
      ;;
    *)
      echo \
        "[soap-catalog] ERROR: ${name}:${version} returned HTTP ${status}" \
        >&2
      cat "$response_file" >&2
      echo >&2
      exit 1
      ;;
  esac
}

upsert_service \
  BillingAdjustmentModernizationAPI \
  1.0.0 \
  "$WORK_DIR/rest-metadata.json" \
  "$REPO_DIR/contracts/openapi/billing-adjustment-modernization.openapi.yaml" \
  application/yaml

upsert_service \
  LegacyBillingAdjustmentSOAPService \
  1.0.0 \
  "$WORK_DIR/soap-metadata.json" \
  "$REPO_DIR/contracts/openapi/legacy-billing-adjustment-soap-service.openapi.yaml" \
  application/yaml

CATALOG="$(
  curl -ksS \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H 'Accept: application/json' \
    "${APIM_URL}/api/am/service-catalog/v1/services?limit=100"
)"

for required in \
  BillingAdjustmentModernizationAPI \
  LegacyBillingAdjustmentSOAPService
do
  if ! printf '%s' "$CATALOG" |
    jq -e --arg n "$required" \
      'any(.list[]?; .name == $n and .version == "1.0.0")' \
      >/dev/null
  then
    echo "[soap-catalog] ERROR: missing catalog service: $required" >&2
    exit 1
  fi
done

printf '%s' "$CATALOG" |
  jq '{
    services: [
      .list[]
      | select(
          .name == "BillingAdjustmentModernizationAPI"
          or .name == "LegacyBillingAdjustmentSOAPService"
        )
      | {
          name,
          version,
          definitionType,
          serviceUrl
        }
    ]
  }'

echo "[soap-catalog] Both modernization services are registered."
