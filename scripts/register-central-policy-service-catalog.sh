#!/usr/bin/env bash
set -euo pipefail

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/central-policy-catalog.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

for command in curl jq python3; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "[central-policy-catalog] ERROR: missing command: $command" >&2
    exit 1
  }
done

cat > "$WORK_DIR/dcr.json" <<JSON
{
  "callbackUrl": "http://localhost:8080/callback",
  "clientName": "central-policy-service-catalog-$(date +%s)-$$",
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
CLIENT_ID="$(jq -r '.clientId // empty' <<<"$DCR_RESPONSE")"
CLIENT_SECRET="$(jq -r '.clientSecret // empty' <<<"$DCR_RESPONSE")"
[[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]] || {
  echo "[central-policy-catalog] ERROR: DCR failed." >&2
  jq . <<<"$DCR_RESPONSE" >&2 || true
  exit 1
}

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
ACCESS_TOKEN="$(jq -r '.access_token // empty' <<<"$TOKEN_RESPONSE")"
[[ -n "$ACCESS_TOKEN" ]] || {
  echo "[central-policy-catalog] ERROR: token request failed." >&2
  jq . <<<"$TOKEN_RESPONSE" >&2 || true
  exit 1
}

cat > "$WORK_DIR/metadata.json" <<'JSON'
{
  "name": "CentralPolicyDecisionAPI",
  "version": "1.0.0",
  "description": "WSO2 Integrator: MI service that preserves correlation, wraps policy descriptors for OPA, normalizes decisions and uses bounded retry, failover and endpoint suspension.",
  "serviceUrl": "http://wso2-mi:8290/internal/central-policy/v1",
  "definitionType": "OAS3",
  "securityType": "NONE",
  "mutualSSLEnabled": false
}
JSON

python3 - "$WORK_DIR/openapi.json" <<'PY'
import json
import sys

definition = {
    "openapi": "3.0.3",
    "info": {
        "title": "Central Policy Decision API",
        "version": "1.0.0",
        "description": "MI-managed OPA decision facade with correlation, normalized errors and failover."
    },
    "servers": [
        {"url": "http://wso2-mi:8290/internal/central-policy/v1"}
    ],
    "paths": {
        "/health": {
            "get": {
                "operationId": "centralPolicyHealth",
                "responses": {
                    "200": {
                        "description": "Healthy",
                        "content": {
                            "application/json": {
                                "schema": {
                                    "type": "object",
                                    "additionalProperties": True
                                }
                            }
                        }
                    }
                }
            }
        },
        "/decisions": {
            "post": {
                "operationId": "evaluateCentralPolicy",
                "requestBody": {
                    "required": True,
                    "content": {
                        "application/json": {
                            "schema": {
                                "type": "object",
                                "additionalProperties": True
                            }
                        }
                    }
                },
                "responses": {
                    "200": {
                        "description": "Evaluated policy decision",
                        "content": {
                            "application/json": {
                                "schema": {
                                    "type": "object",
                                    "additionalProperties": True
                                }
                            }
                        }
                    },
                    "503": {
                        "description": "Both bounded OPA endpoints unavailable"
                    }
                }
            }
        }
    }
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(definition, handle, indent=2)
    handle.write("\n")
PY

SEARCH_RESPONSE="$(
  curl -ksS -G \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H 'Accept: application/json' \
    --data-urlencode 'name=CentralPolicyDecisionAPI' \
    --data-urlencode 'version=1.0.0' \
    --data-urlencode 'limit=100' \
    "${APIM_URL}/api/am/service-catalog/v1/services"
)"
EXISTING_ID="$(
  jq -r \
    'first(.list[]? | select(.name == "CentralPolicyDecisionAPI" and .version == "1.0.0") | .id) // empty' \
    <<<"$SEARCH_RESPONSE"
)"

RESPONSE_FILE="$WORK_DIR/response.json"
if [[ -n "$EXISTING_ID" ]]; then
  STATUS="$(
    curl -ksS -o "$RESPONSE_FILE" -w '%{http_code}' \
      -X PUT \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H 'Accept: application/json' \
      -F "definitionFile=@$WORK_DIR/openapi.json;type=application/json" \
      -F "serviceMetadata=@$WORK_DIR/metadata.json;type=application/json" \
      "${APIM_URL}/api/am/service-catalog/v1/services/${EXISTING_ID}"
  )"
  ACTION=updated
else
  STATUS="$(
    curl -ksS -o "$RESPONSE_FILE" -w '%{http_code}' \
      -X POST \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H 'Accept: application/json' \
      -F "definitionFile=@$WORK_DIR/openapi.json;type=application/json" \
      -F "serviceMetadata=@$WORK_DIR/metadata.json;type=application/json" \
      "${APIM_URL}/api/am/service-catalog/v1/services"
  )"
  ACTION=created
fi

case "$STATUS" in
  200|201)
    echo "[central-policy-catalog] CentralPolicyDecisionAPI:1.0.0 ${ACTION}."
    ;;
  *)
    echo "[central-policy-catalog] ERROR: HTTP ${STATUS}" >&2
    cat "$RESPONSE_FILE" >&2
    exit 1
    ;;
esac

FINAL="$(
  curl -ksS \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "${APIM_URL}/api/am/service-catalog/v1/services?limit=100"
)"
jq -e \
  'any(.list[]?; .name == "CentralPolicyDecisionAPI" and .version == "1.0.0")' \
  <<<"$FINAL" >/dev/null
echo "[central-policy-catalog] Verified CentralPolicyDecisionAPI in APIM Service Catalog."
