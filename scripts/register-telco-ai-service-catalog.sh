#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"

WORK_DIR="$(
  mktemp -d "${TMPDIR:-/tmp}/telco-ai-catalog.XXXXXX"
)"

trap 'rm -rf "$WORK_DIR"' EXIT

for required_command in curl jq ruby; do
  command -v "$required_command" >/dev/null || {
    echo \
      "[telco-ai-catalog] ERROR: ${required_command} is required." \
      >&2
    exit 1
  }
done

CURL_OPTIONS=(
  -k
  -sS
  --connect-timeout 10
  --max-time 90
  --retry 3
  --retry-delay 2
)

echo "[telco-ai-catalog] API Manager: $APIM_URL"
echo "[telco-ai-catalog] Obtaining Service Catalog credentials."

CLIENT_NAME="telco-ai-service-catalog-$(date +%s)-$$"

jq -n \
  --arg callbackUrl "http://localhost:8080/callback" \
  --arg clientName "$CLIENT_NAME" \
  --arg owner "$APIM_USER" \
  '{
    callbackUrl: $callbackUrl,
    clientName: $clientName,
    owner: $owner,
    grantType: "password refresh_token client_credentials",
    saasApp: true
  }' \
  > "$WORK_DIR/dcr.json"

DCR_RESPONSE="$(
  curl "${CURL_OPTIONS[@]}" \
    -u "${APIM_USER}:${APIM_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    --data-binary "@$WORK_DIR/dcr.json" \
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
  echo "[telco-ai-catalog] ERROR: DCR failed." >&2
  printf '%s\n' "$DCR_RESPONSE" | jq . >&2 || true
  exit 1
fi

TOKEN_RESPONSE="$(
  curl "${CURL_OPTIONS[@]}" \
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
  echo "[telco-ai-catalog] ERROR: token request failed." >&2
  printf '%s\n' "$TOKEN_RESPONSE" | jq . >&2 || true
  exit 1
fi

register_service() {
  local service_name="$1"
  local service_version="$2"
  local description="$3"
  local service_url="$4"
  local source_definition="$5"

  if [[ ! -f "$source_definition" ]]; then
    echo \
      "[telco-ai-catalog] ERROR: missing definition: " \
      "$source_definition" \
      >&2
    exit 1
  fi

  local safe_name
  safe_name="$(
    printf '%s' "$service_name" |
      tr '[:upper:]' '[:lower:]' |
      tr -cs 'a-z0-9' '-'
  )"

  local metadata_file="$WORK_DIR/${safe_name}-metadata.json"
  local definition_file="$WORK_DIR/${safe_name}-openapi.json"

  jq -n \
    --arg name "$service_name" \
    --arg version "$service_version" \
    --arg description "$description" \
    --arg serviceUrl "$service_url" \
    '{
      name: $name,
      version: $version,
      description: $description,
      serviceUrl: $serviceUrl,
      definitionType: "OAS3",
      securityType: "NONE",
      mutualSSLEnabled: false
    }' \
    > "$metadata_file"

  ruby -ryaml -rjson \
    -e '
      source = ARGV.fetch(0)
      target = ARGV.fetch(1)

      definition = YAML.safe_load(
        File.read(source),
        aliases: true
      )

      File.write(
        target,
        JSON.pretty_generate(definition) + "\n"
      )
    ' \
    "$source_definition" \
    "$definition_file"

  echo
  echo \
    "[telco-ai-catalog] Processing " \
    "${service_name}:${service_version}"

  local search_response
  search_response="$(
    curl "${CURL_OPTIONS[@]}" \
      -G \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H 'Accept: application/json' \
      --data-urlencode "name=${service_name}" \
      --data-urlencode "version=${service_version}" \
      --data-urlencode 'limit=100' \
      "${APIM_URL}/api/am/service-catalog/v1/services"
  )"

  local existing_id
  existing_id="$(
    printf '%s\n' "$search_response" |
      jq -r \
        --arg name "$service_name" \
        --arg version "$service_version" \
        '
          first(
            .list[]?
            | select(
                .name == $name
                and .version == $version
              )
            | .id
          ) // empty
        '
  )"

  local response_file="$WORK_DIR/${safe_name}-response.json"
  local http_status
  local action

  if [[ -n "$existing_id" ]]; then
    action="updated"

    http_status="$(
      curl "${CURL_OPTIONS[@]}" \
        -o "$response_file" \
        -w '%{http_code}' \
        -X PUT \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H 'Accept: application/json' \
        -F \
          "definitionFile=@${definition_file};type=application/json" \
        -F \
          "serviceMetadata=@${metadata_file};type=application/json" \
        "${APIM_URL}/api/am/service-catalog/v1/services/${existing_id}"
    )"
  else
    action="created"

    http_status="$(
      curl "${CURL_OPTIONS[@]}" \
        -o "$response_file" \
        -w '%{http_code}' \
        -X POST \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H 'Accept: application/json' \
        -F \
          "definitionFile=@${definition_file};type=application/json" \
        -F \
          "serviceMetadata=@${metadata_file};type=application/json" \
        "${APIM_URL}/api/am/service-catalog/v1/services"
    )"
  fi

  case "$http_status" in
    200|201)
      local service_id

      service_id="$(
        jq -r '.id // empty' "$response_file"
      )"

      echo \
        "[telco-ai-catalog] ${service_name}:${service_version} " \
        "${action}; id=${service_id:-unknown}"
      ;;
    *)
      echo \
        "[telco-ai-catalog] ERROR: ${service_name}:${service_version} " \
        "returned HTTP ${http_status}." \
        >&2

      cat "$response_file" >&2
      echo >&2
      exit 1
      ;;
  esac
}

register_service \
  "TelcoSupportAssistantAPI" \
  "1.0.0" \
  "Governed telco support-assistant API implemented by WSO2 Integrator: MI." \
  "http://wso2-mi:8290/telco-support-assistant/v1" \
  "$ROOT_DIR/contracts/openapi/telco-support-assistant.openapi.yaml"

register_service \
  "TelcoAgentToolsAPI" \
  "1.0.0" \
  "Governed telco operational tools exposed to MI agents and MCP clients." \
  "http://wso2-mi:8290/telco-agent-tools/v1" \
  "$ROOT_DIR/contracts/openapi/telco-agent-tools.openapi.yaml"

echo
echo "[telco-ai-catalog] Verifying final entries."

CATALOG_RESPONSE="$(
  curl "${CURL_OPTIONS[@]}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H 'Accept: application/json' \
    "${APIM_URL}/api/am/service-catalog/v1/services?limit=100"
)"

for required_service in \
  TelcoSupportAssistantAPI \
  TelcoAgentToolsAPI
do
  if ! printf '%s\n' "$CATALOG_RESPONSE" |
    jq -e \
      --arg name "$required_service" \
      'any(.list[]?; .name == $name)' \
      >/dev/null
  then
    echo \
      "[telco-ai-catalog] ERROR: missing service: " \
      "$required_service" \
      >&2
    exit 1
  fi

  echo "[telco-ai-catalog] PASS: $required_service"
done

echo
echo "[telco-ai-catalog] Registration completed."
