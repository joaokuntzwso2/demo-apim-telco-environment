#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(pwd)"

required=(
  "docker-compose.yml"
  "scripts/run-with-mi-risk.sh"
  "scripts/register-soap-modernization-service-catalog.sh"
  "scripts/verify-mi-resilience-config.sh"
  "services/apim-bootstrapper/package.json"
  "services/wso2-mi/synapse-configs/default/endpoints"
  "services/wso2-mi/synapse-configs/default/sequences"
)

for path in "${required[@]}"; do
  if [[ ! -e "${ROOT_DIR}/${path}" ]]; then
    echo "[dx-repair] ERROR: run this script from the repository root." >&2
    echo "[dx-repair] Missing: ${path}" >&2
    exit 1
  fi
done

backup_once() {
  local file="$1"
  local backup="${file}.before-dx-runtime-fix"
  if [[ -f "$file" && ! -f "$backup" ]]; then
    cp "$file" "$backup"
  fi
}

backup_once scripts/verify-mi-resilience-config.sh
backup_once scripts/register-soap-modernization-service-catalog.sh
backup_once scripts/run-with-mi-risk.sh

python3 <<'PY'
from pathlib import Path

path = Path("scripts/verify-mi-resilience-config.sh")
text = path.read_text()

text = text.replace(
    'endpoint_dir="services/wso2-mi/src/main/wso2mi/artifacts/endpoints"',
    'endpoint_dir="services/wso2-mi/synapse-configs/default/endpoints"',
)
text = text.replace(
    'sequence_dir="services/wso2-mi/src/main/wso2mi/artifacts/sequences"',
    'sequence_dir="services/wso2-mi/synapse-configs/default/sequences"',
)

path.write_text(text)
PY

mkdir -p contracts/openapi

cat > contracts/openapi/legacy-billing-adjustment-soap-service.openapi.yaml <<'YAML'
openapi: 3.0.3
info:
  title: Legacy Billing Adjustment SOAP Service
  version: 1.0.0
  description: |
    Service Catalog descriptor for the legacy SOAP 1.1 billing-adjustment
    backend used by the WSO2 Integrator modernization demonstration.

    The authoritative SOAP contract remains:
    contracts/soap/legacy-billing-adjustment.wsdl

    This OpenAPI document is intentionally used only as an APIM Service
    Catalog-compatible service descriptor. Requests and responses use XML.
servers:
  - url: http://legacy-billing-primary:8080
    description: Primary legacy billing node
  - url: http://legacy-billing-dr:8080
    description: Disaster-recovery legacy billing node
paths:
  /LegacyBillingAdjustmentService:
    post:
      operationId: adjustBillingSoap
      summary: Submit a SOAP 1.1 billing-adjustment message
      description: |
        Accepts the AdjustBilling SOAP operation. WSO2 Integrator supplies
        WS-Security UsernameToken credentials, correlation propagation,
        primary/DR failover, timeout handling and normalized faults.
      parameters:
        - name: SOAPAction
          in: header
          required: true
          schema:
            type: string
            example: urn:AdjustBilling
        - name: X-Correlation-ID
          in: header
          required: false
          schema:
            type: string
      requestBody:
        required: true
        content:
          text/xml:
            schema:
              type: string
            example: |
              <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
                                xmlns:bil="urn:americamovil:bss:billing:v1">
                <soapenv:Header/>
                <soapenv:Body>
                  <bil:AdjustBillingRequest>
                    <bil:transactionId>TXN-10001</bil:transactionId>
                    <bil:subscriberId>SUB-10001</bil:subscriberId>
                    <bil:amount>15.50</bil:amount>
                    <bil:currency>USD</bil:currency>
                    <bil:reasonCode>SERVICE_CREDIT</bil:reasonCode>
                    <bil:requestedBy>partner-sandbox-001</bil:requestedBy>
                    <bil:correlationId>demo-correlation-0001</bil:correlationId>
                  </bil:AdjustBillingRequest>
                </soapenv:Body>
              </soapenv:Envelope>
      responses:
        "200":
          description: SOAP AdjustBilling response
          content:
            text/xml:
              schema:
                type: string
        "500":
          description: SOAP fault
          content:
            text/xml:
              schema:
                type: string
  /LegacyBillingAdjustmentService:
    get:
      operationId: getLegacyBillingWsdl
      summary: Retrieve the legacy service WSDL
      parameters:
        - name: wsdl
          in: query
          required: false
          schema:
            type: string
            nullable: true
      responses:
        "200":
          description: WSDL document
          content:
            text/xml:
              schema:
                type: string
YAML

# Correct a duplicate YAML path key by merging GET and POST into one path item.
python3 <<'PY'
from pathlib import Path

path = Path("contracts/openapi/legacy-billing-adjustment-soap-service.openapi.yaml")
text = path.read_text()

first = """  /LegacyBillingAdjustmentService:
    post:
"""
second = """  /LegacyBillingAdjustmentService:
    get:
"""

if text.count(first) != 1 or text.count(second) != 1:
    raise SystemExit("[dx-repair] Unexpected generated OpenAPI structure.")

before, after = text.split(second, 1)
# The second path item is at the same indentation level. Replace it with a GET
# operation under the existing path item.
after = "    get:\n" + after
path.write_text(before + after)
PY

cat > scripts/register-soap-modernization-service-catalog.sh <<'SH'
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
SH

chmod +x scripts/register-soap-modernization-service-catalog.sh
chmod +x scripts/verify-mi-resilience-config.sh

python3 <<'PY'
from pathlib import Path

path = Path("scripts/run-with-mi-risk.sh")
text = path.read_text()

begin = "# BEGIN APIM BOOTSTRAPPER COMPLETION CHECK"
end = "# END APIM BOOTSTRAPPER COMPLETION CHECK"

if begin in text and end in text:
    prefix, remainder = text.split(begin, 1)
    _, suffix = remainder.split(end, 1)
    text = prefix.rstrip() + "\n" + suffix.lstrip()
    path.write_text(text)

# The correct sequence must start the one-shot container before waiting for it.
current = path.read_text()
up_marker = '"${COMPOSE[@]}" up -d --build --force-recreate apim-bootstrapper'
wait_marker = 'echo "Waiting for APIM bootstrapper to finish..."'

if up_marker not in current or wait_marker not in current:
    raise SystemExit(
        "[dx-repair] Could not confirm the correct bootstrapper start/wait block."
    )

if current.index(up_marker) > current.index(wait_marker):
    raise SystemExit(
        "[dx-repair] Bootstrapper wait still appears before container startup."
    )
PY

chmod +x scripts/run-with-mi-risk.sh

bash -n scripts/verify-mi-resilience-config.sh
bash -n scripts/register-soap-modernization-service-catalog.sh
bash -n scripts/run-with-mi-risk.sh

node --check services/apim-bootstrapper/src/developer-experience-setup.js

echo "[dx-repair] Repair applied successfully."
echo
echo "[dx-repair] Fast recovery commands for the currently running environment:"
echo "  ./scripts/verify-mi-resilience-config.sh"
echo "  ./scripts/register-soap-modernization-service-catalog.sh"
echo "  docker compose -f docker-compose.yml -f docker-compose.mi.yml -f docker-compose.mi.soap.yml rm -sf apim-bootstrapper"
echo "  docker compose -f docker-compose.yml -f docker-compose.mi.yml -f docker-compose.mi.soap.yml up -d --build --force-recreate apim-bootstrapper"
echo "  docker logs -f telco-apim-bootstrapper"
echo "  ./scripts/verify-developer-experience.sh"
