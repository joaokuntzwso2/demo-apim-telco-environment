#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  echo "[Telco AI MCP] $*"
}

fail() {
  echo "[Telco AI MCP][FAIL] $*" >&2
  exit 1
}

ENV_NAME="${APIM_ENVIRONMENT:-am47}"

APIM_BASE_URL="${WSO2_APIM_URL:-${APIM_URL:-https://wso2-apim:9443}}"

APIM_LOGIN_USER="${APIM_USERNAME:-${APIM_USER:-admin}}"

APIM_LOGIN_PASSWORD="${APIM_PASSWORD:-${APIM_PASS:-admin}}"

MCP_PROJECT="${TELCO_AI_MCP_PROJECT:-/workspace/artifacts/apictl/mcp/TelcoOperationsMCP-1.0.0}"

required_files=(
  "mcp_server.yaml"
  "mcp_server_meta.yaml"
  "backends.yaml"
  "deployment_environments.yaml"
  "Definitions/swagger.yaml"
)

command -v apictl >/dev/null 2>&1 ||
  fail "apictl is not installed"

for required_file in "${required_files[@]}"; do
  [[ -s "$MCP_PROJECT/$required_file" ]] ||
    fail "Missing MCP artifact: $MCP_PROJECT/$required_file"
done

if find "$MCP_PROJECT" \
  -type f \
  \( -name '*.bak' \
     -o -name '*.before-*' \
     -o -name '*~' \) \
  -print \
  | grep -q .
then
  fail "Temporary or backup files exist in the MCP project"
fi

log "Configuring APICTL environment: $ENV_NAME"

set +e

ADD_ENV_OUTPUT="$(
  apictl add env "$ENV_NAME" \
    --apim "$APIM_BASE_URL" \
    --token "$APIM_BASE_URL/oauth2/token" \
    -k \
    2>&1
)"

ADD_ENV_RC=$?

set -e

if [[ "$ADD_ENV_RC" -eq 0 ]]; then
  printf '%s\n' "$ADD_ENV_OUTPUT"
elif grep -Fq "already exists" <<<"$ADD_ENV_OUTPUT"; then
  log "APICTL environment already configured: $ENV_NAME"
else
  printf '%s\n' "$ADD_ENV_OUTPUT" >&2
  fail "Unable to configure APICTL environment: $ENV_NAME"
fi

log "Logging into API Manager"

printf '%s' "$APIM_LOGIN_PASSWORD" |
  apictl login "$ENV_NAME" \
    --username "$APIM_LOGIN_USER" \
    --password-stdin \
    -k

apictl set --http-request-timeout 240000

log "Importing MCP server from $MCP_PROJECT"

apictl import mcp-server \
  --file "$MCP_PROJECT" \
  --environment "$ENV_NAME" \
  --update \
  --rotate-revision \
  -k

log "MCP server import completed"
