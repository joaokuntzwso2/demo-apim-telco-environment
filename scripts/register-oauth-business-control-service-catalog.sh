#!/usr/bin/env bash
set -euo pipefail

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/telco-oauth-catalog.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

for command in curl jq python3; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "[oauth-catalog] ERROR: missing required command: ${command}" >&2
    exit 1
  }
done

CLIENT_NAME="telco-oauth-service-catalog-$(date +%s)-$$"
cat > "${WORK_DIR}/dcr.json" <<JSON
{
  "callbackUrl": "http://localhost:8080/callback",
  "clientName": "${CLIENT_NAME}",
  "owner": "${APIM_USER}",
  "grantType": "password refresh_token client_credentials",
  "saasApp": true
}
JSON

DCR_RESPONSE="$(curl -ksS \
  -u "${APIM_USER}:${APIM_PASSWORD}" \
  -H 'Content-Type: application/json' \
  --data-binary @"${WORK_DIR}/dcr.json" \
  "${APIM_URL}/client-registration/v0.17/register")"
CLIENT_ID="$(jq -r '.clientId // empty' <<<"${DCR_RESPONSE}")"
CLIENT_SECRET="$(jq -r '.clientSecret // empty' <<<"${DCR_RESPONSE}")"
if [[ -z "${CLIENT_ID}" || -z "${CLIENT_SECRET}" ]]; then
  echo '[oauth-catalog] ERROR: APIM dynamic client registration failed.' >&2
  jq . <<<"${DCR_RESPONSE}" >&2 || printf '%s\n' "${DCR_RESPONSE}" >&2
  exit 1
fi

TOKEN_RESPONSE="$(curl -ksS \
  -u "${CLIENT_ID}:${CLIENT_SECRET}" \
  --data-urlencode 'grant_type=password' \
  --data-urlencode "username=${APIM_USER}" \
  --data-urlencode "password=${APIM_PASSWORD}" \
  --data-urlencode 'scope=service_catalog:service_view service_catalog:service_write' \
  "${APIM_URL}/oauth2/token")"
ACCESS_TOKEN="$(jq -r '.access_token // empty' <<<"${TOKEN_RESPONSE}")"
if [[ -z "${ACCESS_TOKEN}" ]]; then
  echo '[oauth-catalog] ERROR: could not obtain a Service Catalog token.' >&2
  jq . <<<"${TOKEN_RESPONSE}" >&2 || printf '%s\n' "${TOKEN_RESPONSE}" >&2
  exit 1
fi

cat > "${WORK_DIR}/metadata.json" <<'JSON'
{
  "name": "SubscriberAuthorizationControlAPI",
  "version": "1.0.0",
  "description": "WSO2 Integrator: MI business authorization facade for OAuth persona, consent, purpose, country, partner isolation, masking and risk enforcement.",
  "serviceUrl": "http://wso2-mi:8290/subscriber-authorization/v1",
  "definitionType": "OAS3",
  "securityType": "NONE",
  "mutualSSLEnabled": false
}
JSON

python3 - "${WORK_DIR}/definition.json" <<'PY'
import json
import re
import sys
from pathlib import Path

paths = {
    "/health": {"get": {"summary": "Check authorization facade health"}},
    "/number-verifications": {"post": {"summary": "Authorize number verification"}},
    "/sim-swap-checks": {"post": {"summary": "Authorize SIM-swap risk access"}},
    "/device-location-verifications": {"post": {"summary": "Authorize device-location verification"}},
    "/qod-requests": {"post": {"summary": "Authorize Quality-on-Demand request"}},
    "/partners/{partnerId}/commercial-usage": {"get": {"summary": "Authorize partner commercial-usage access"}},
}
for path, methods in paths.items():
    for method, operation in methods.items():
        operation["operationId"] = (
            "SubscriberAuthorizationControlAPI_" + method + "_" +
            path.strip("/").replace("/", "_").replace("{", "").replace("}", "").replace("-", "_")
        )
        path_parameters = re.findall(r"\{([^}]+)\}", path)
        if path_parameters:
            operation["parameters"] = [
                {
                    "name": parameter_name,
                    "in": "path",
                    "required": True,
                    "schema": {"type": "string"},
                }
                for parameter_name in path_parameters
            ]
        if method in {"post", "put", "patch"}:
            operation["requestBody"] = {
                "required": True,
                "content": {"application/json": {"schema": {"type": "object", "additionalProperties": True}}},
            }
        operation["responses"] = {
            "200": {
                "description": "Authorization decision",
                "content": {"application/json": {"schema": {"type": "object", "additionalProperties": True}}},
            },
            "401": {"description": "Authentication context missing or invalid"},
            "403": {"description": "Business authorization denied"},
            "503": {"description": "Risk or downstream evidence unavailable"},
        }

definition = {
    "openapi": "3.0.3",
    "info": {
        "title": "Subscriber Authorization Control API",
        "version": "1.0.0",
        "description": "MI-managed authorization facade exposed through WSO2 API Manager.",
    },
    "servers": [{"url": "http://wso2-mi:8290/subscriber-authorization/v1"}],
    "paths": paths,
}
Path(sys.argv[1]).write_text(json.dumps(definition, indent=2) + "\n", encoding="utf-8")
PY

SEARCH_RESPONSE="$(curl -ksS -G \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H 'Accept: application/json' \
  --data-urlencode 'name=SubscriberAuthorizationControlAPI' \
  --data-urlencode 'version=1.0.0' \
  --data-urlencode 'limit=100' \
  "${APIM_URL}/api/am/service-catalog/v1/services")"
EXISTING_ID="$(jq -r \
  'first(.list[]? | select(.name == "SubscriberAuthorizationControlAPI" and .version == "1.0.0") | .id) // empty' \
  <<<"${SEARCH_RESPONSE}")"

RESPONSE_FILE="${WORK_DIR}/response.json"
if [[ -n "${EXISTING_ID}" ]]; then
  HTTP_STATUS="$(curl -ksS -o "${RESPONSE_FILE}" -w '%{http_code}' \
    -X PUT \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H 'Accept: application/json' \
    -F "definitionFile=@${WORK_DIR}/definition.json;type=application/json" \
    -F "serviceMetadata=@${WORK_DIR}/metadata.json;type=application/json" \
    "${APIM_URL}/api/am/service-catalog/v1/services/${EXISTING_ID}")"
  ACTION='updated'
else
  HTTP_STATUS="$(curl -ksS -o "${RESPONSE_FILE}" -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H 'Accept: application/json' \
    -F "definitionFile=@${WORK_DIR}/definition.json;type=application/json" \
    -F "serviceMetadata=@${WORK_DIR}/metadata.json;type=application/json" \
    "${APIM_URL}/api/am/service-catalog/v1/services")"
  ACTION='created'
fi

case "${HTTP_STATUS}" in
  200|201)
    SERVICE_ID="$(jq -r '.id // empty' "${RESPONSE_FILE}")"
    echo "[oauth-catalog] SubscriberAuthorizationControlAPI:1.0.0 ${ACTION}; id=${SERVICE_ID:-${EXISTING_ID}}"
    ;;
  *)
    echo "[oauth-catalog] ERROR: Service Catalog upsert returned HTTP ${HTTP_STATUS}." >&2
    cat "${RESPONSE_FILE}" >&2
    exit 1
    ;;
esac

FINAL_RESPONSE="$(curl -ksS -G \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H 'Accept: application/json' \
  --data-urlencode 'name=SubscriberAuthorizationControlAPI' \
  --data-urlencode 'version=1.0.0' \
  --data-urlencode 'limit=100' \
  "${APIM_URL}/api/am/service-catalog/v1/services")"
if ! jq -e 'any(.list[]?; .name == "SubscriberAuthorizationControlAPI" and .version == "1.0.0")' \
  <<<"${FINAL_RESPONSE}" >/dev/null; then
  echo '[oauth-catalog] ERROR: service is absent after registration.' >&2
  exit 1
fi

echo '[oauth-catalog] SubscriberAuthorizationControlAPI is registered and discoverable.'
