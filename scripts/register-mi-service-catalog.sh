#!/usr/bin/env bash

set -euo pipefail

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/telco-mi-catalog.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "[service-catalog] Registering WSO2 Integrator: MI services."
echo "[service-catalog] API Manager: $APIM_URL"

# ---------------------------------------------------------------------------
# Obtain an OAuth client through APIM Dynamic Client Registration.
# A unique local-demo client name avoids conflicts on repeated executions.
# ---------------------------------------------------------------------------

CLIENT_NAME="telco-mi-service-catalog-$(date +%s)-$$"

cat > "$WORK_DIR/dcr.json" <<JSON
{
  "callbackUrl": "https://localhost",
  "clientName": "$CLIENT_NAME",
  "owner": "$APIM_USER",
  "grantType": "password client_credentials refresh_token",
  "saasApp": true
}
JSON

DCR_RESPONSE="$(
  curl -ksS \
    -u "${APIM_USER}:${APIM_PASSWORD}" \
    -H 'Content-Type: application/json' \
    --data-binary @"$WORK_DIR/dcr.json" \
    "${APIM_URL}/client-registration/v0.17/register"
)"

CLIENT_ID="$(
  printf '%s\n' "$DCR_RESPONSE" |
    jq -r '.clientId // empty'
)"

CLIENT_SECRET="$(
  printf '%s\n' "$DCR_RESPONSE" |
    jq -r '.clientSecret // empty'
)"

if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
  echo "[service-catalog] ERROR: dynamic client registration failed." >&2
  printf '%s\n' "$DCR_RESPONSE" | jq . >&2 || printf '%s\n' "$DCR_RESPONSE" >&2
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

ACCESS_TOKEN="$(
  printf '%s\n' "$TOKEN_RESPONSE" |
    jq -r '.access_token // empty'
)"

if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "[service-catalog] ERROR: could not obtain a Service Catalog token." >&2
  printf '%s\n' "$TOKEN_RESPONSE" | jq . >&2 || printf '%s\n' "$TOKEN_RESPONSE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Generate official Service Catalog metadata and OpenAPI 3 definitions.
# ---------------------------------------------------------------------------

python3 - "$WORK_DIR" <<'PY' > "$WORK_DIR/manifest.tsv"
import json
import re
import sys
from pathlib import Path

output_dir = Path(sys.argv[1])

services = [
    {
        "name": "SecureTransactionRiskAssessmentAPI",
        "title": "Secure Transaction Risk Assessment API",
        "version": "1.0.0",
        "description": (
            "WSO2 Integrator orchestration service that aggregates subscriber "
            "CRM, SIM-swap, device-location and OSS evidence to calculate a "
            "normalized transaction risk decision."
        ),
        "service_url": (
            "http://wso2-mi:8290/secure-transaction-risk/v1"
        ),
        "operations": [
            ("get", "/health", "Check orchestration service health"),
            ("post", "/assessments", "Assess secure transaction risk"),
        ],
    },
    {
        "name": "CrmRiskAdapterAPI",
        "title": "Subscriber CRM Risk Adapter API",
        "version": "1.0.0",
        "description": (
            "WSO2 Integrator adapter that transforms canonical JSON into the "
            "legacy CRM XML contract and normalizes the CRM response."
        ),
        "service_url": (
            "http://wso2-mi:8290/internal/risk/crm/v1"
        ),
        "operations": [
            ("post", "/account-status", "Retrieve subscriber account status"),
        ],
    },
    {
        "name": "SimSwapRiskAdapterAPI",
        "title": "SIM Swap Risk Adapter API",
        "version": "1.0.0",
        "description": (
            "WSO2 Integrator adapter for retrieving and normalizing recent "
            "SIM-swap evidence."
        ),
        "service_url": (
            "http://wso2-mi:8290/internal/risk/sim-swap/v1"
        ),
        "operations": [
            ("post", "/check", "Check recent SIM-swap activity"),
        ],
    },
    {
        "name": "DeviceLocationRiskAdapterAPI",
        "title": "Device Location Risk Adapter API",
        "version": "1.0.0",
        "description": (
            "WSO2 Integrator adapter for verifying device location and "
            "normalizing network-location evidence."
        ),
        "service_url": (
            "http://wso2-mi:8290/internal/risk/device-location/v1"
        ),
        "operations": [
            ("post", "/verify", "Verify device location"),
        ],
    },
    {
        "name": "OssRiskAdapterAPI",
        "title": "OSS Network Risk Adapter API",
        "version": "1.0.0",
        "description": (
            "WSO2 Integrator adapter that exchanges pipe-delimited legacy OSS "
            "messages and normalizes roaming and network-status evidence."
        ),
        "service_url": (
            "http://wso2-mi:8290/internal/risk/oss/v1"
        ),
        "operations": [
            ("post", "/network-status", "Retrieve OSS network status"),
        ],
    },

    {
        "name": "RuntimePolicyAlertAPI",
        "title": "Runtime Policy Alert API",
        "version": "1.0.0",
        "description": (
            "WSO2 Integrator: MI service that validates APIM runtime throttling "
            "events and publishes them to the telco.runtime.policy.alerts Kafka topic."
        ),
        "service_url": (
            "http://wso2-mi:8290/internal/runtime-policy-alerts/v1"
        ),
        "operations": [
            ("get", "/health", "Check runtime policy alert integration health"),
            ("post", "/events", "Publish a normalized runtime policy alert"),
        ],
    },
]


def operation(service_name: str, method: str, path: str, summary: str) -> dict:
    operation_id = re.sub(
        r"[^A-Za-z0-9]+",
        "_",
        f"{service_name}_{method}_{path}",
    ).strip("_")

    result = {
        "summary": summary,
        "operationId": operation_id,
        "responses": {
            "200": {
                "description": "Successful response",
                "content": {
                    "application/json": {
                        "schema": {
                            "type": "object",
                            "additionalProperties": True,
                        }
                    }
                },
            },
            "500": {
                "description": "Integration or backend error",
            },
        },
    }

    if method.lower() in {"post", "put", "patch"}:
        result["requestBody"] = {
            "required": True,
            "content": {
                "application/json": {
                    "schema": {
                        "type": "object",
                        "additionalProperties": True,
                    }
                }
            },
        }

    return result


for service in services:
    safe_name = re.sub(
        r"[^a-z0-9]+",
        "-",
        service["name"].lower(),
    ).strip("-")

    metadata_path = output_dir / f"{safe_name}-metadata.json"
    definition_path = output_dir / f"{safe_name}-openapi.json"

    metadata = {
        "name": service["name"],
        "version": service["version"],
        "description": service["description"],
        "serviceUrl": service["service_url"],
        "definitionType": "OAS3",
        "securityType": "NONE",
        "mutualSSLEnabled": False,
    }

    paths = {}

    for method, resource_path, summary in service["operations"]:
        paths.setdefault(resource_path, {})[method.lower()] = operation(
            service["name"],
            method,
            resource_path,
            summary,
        )

    definition = {
        "openapi": "3.0.3",
        "info": {
            "title": service["title"],
            "version": service["version"],
            "description": service["description"],
        },
        "servers": [
            {
                "url": service["service_url"],
            }
        ],
        "paths": paths,
    }

    metadata_path.write_text(
        json.dumps(metadata, indent=2) + "\n",
        encoding="utf-8",
    )

    definition_path.write_text(
        json.dumps(definition, indent=2) + "\n",
        encoding="utf-8",
    )

    print(
        "\t".join(
            [
                service["name"],
                service["version"],
                str(metadata_path),
                str(definition_path),
            ]
        )
    )
PY

# ---------------------------------------------------------------------------
# Idempotently create or update every service.
# ---------------------------------------------------------------------------

while IFS=$'\t' read -r \
  SERVICE_NAME \
  SERVICE_VERSION \
  METADATA_FILE \
  DEFINITION_FILE
do
  echo
  echo "[service-catalog] Processing ${SERVICE_NAME}:${SERVICE_VERSION}"

  SEARCH_RESPONSE="$(
    curl -ksS -G \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H 'Accept: application/json' \
      --data-urlencode "name=${SERVICE_NAME}" \
      --data-urlencode "version=${SERVICE_VERSION}" \
      --data-urlencode 'limit=100' \
      "${APIM_URL}/api/am/service-catalog/v1/services"
  )"

  EXISTING_ID="$(
    printf '%s\n' "$SEARCH_RESPONSE" |
      jq -r \
        --arg name "$SERVICE_NAME" \
        --arg version "$SERVICE_VERSION" \
        'first(
           .list[]?
           | select(
               .name == $name
               and .version == $version
             )
           | .id
         ) // empty'
  )"

  RESPONSE_FILE="$WORK_DIR/service-response.json"

  if [[ -n "$EXISTING_ID" ]]; then
    HTTP_STATUS="$(
      curl -ksS \
        -o "$RESPONSE_FILE" \
        -w '%{http_code}' \
        -X PUT \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H 'Accept: application/json' \
        -F "definitionFile=@${DEFINITION_FILE};type=application/json" \
        -F "serviceMetadata=@${METADATA_FILE};type=application/json" \
        "${APIM_URL}/api/am/service-catalog/v1/services/${EXISTING_ID}"
    )"

    ACTION="updated"
  else
    HTTP_STATUS="$(
      curl -ksS \
        -o "$RESPONSE_FILE" \
        -w '%{http_code}' \
        -X POST \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H 'Accept: application/json' \
        -F "definitionFile=@${DEFINITION_FILE};type=application/json" \
        -F "serviceMetadata=@${METADATA_FILE};type=application/json" \
        "${APIM_URL}/api/am/service-catalog/v1/services"
    )"

    ACTION="created"
  fi

  case "$HTTP_STATUS" in
    200|201)
      SERVICE_ID="$(
        jq -r '.id // empty' "$RESPONSE_FILE"
      )"

      echo \
        "[service-catalog] ${SERVICE_NAME}:${SERVICE_VERSION} " \
        "${ACTION}; id=${SERVICE_ID:-unknown}"
      ;;
    *)
      echo \
        "[service-catalog] ERROR: ${SERVICE_NAME}:${SERVICE_VERSION} " \
        "returned HTTP ${HTTP_STATUS}." >&2

      cat "$RESPONSE_FILE" >&2
      echo >&2
      exit 1
      ;;
  esac
done < "$WORK_DIR/manifest.tsv"

echo
echo "[service-catalog] Final Service Catalog entries:"

CATALOG_RESPONSE="$(
  curl -ksS \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H 'Accept: application/json' \
    "${APIM_URL}/api/am/service-catalog/v1/services?limit=100"
)"

printf '%s\n' "$CATALOG_RESPONSE" |
  jq '{
    count,
    services: [
      .list[]
      | {
          name,
          version,
          definitionType,
          serviceUrl
        }
    ]
  }'

EXPECTED_SERVICES=(
  SecureTransactionRiskAssessmentAPI
  CrmRiskAdapterAPI
  SimSwapRiskAdapterAPI
  DeviceLocationRiskAdapterAPI
  OssRiskAdapterAPI
  RuntimePolicyAlertAPI
)

for required in "${EXPECTED_SERVICES[@]}"; do
  if ! printf '%s\n' "$CATALOG_RESPONSE" |
       jq -e \
         --arg name "$required" \
         'any(.list[]?; .name == $name)' \
         >/dev/null
  then
    echo \
      "[service-catalog] ERROR: missing service after registration: " \
      "$required" >&2
    exit 1
  fi
done

echo
echo "[service-catalog] All six MI services are registered."
