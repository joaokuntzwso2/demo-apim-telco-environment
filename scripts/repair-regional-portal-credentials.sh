#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"

APPLICATION_NAME="${PORTAL_APP_NAME:-Regional Portal}"
API_NAME="CentralPolicyDecisionAPI"
API_VERSION="1.0.0"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/regional-portal-key-repair.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
chmod 700 "$WORK_DIR"

fail() {
  echo "[regional-portal-key-repair] FAIL: $*" >&2
  exit 1
}

log() {
  echo "[regional-portal-key-repair] $*"
}

for command in curl jq docker; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Missing required command: $command"
done

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose)
else
  fail "Docker Compose was not found."
fi

COMPOSE_FILES=(docker-compose.yml)

for file in \
  docker-compose.kafka.yml \
  docker-compose.opa.yml \
  docker-compose.mi.yml \
  docker-compose.commercial.yml \
  docker-compose.mi.soap.yml \
  docker-compose.observability.yml \
  docker-compose.runtime-persistence.yml \
  docker-compose.central-policy.yml
do
  [[ -f "$file" ]] && COMPOSE_FILES+=("$file")
done

COMPOSE=("${DC[@]}")

for file in "${COMPOSE_FILES[@]}"; do
  COMPOSE+=(-f "$file")
done

log "Registering an administrative REST client."

DCR_RESPONSE="$(
  curl -ksS \
    -u "${APIM_USER}:${APIM_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d "{
      \"callbackUrl\": \"http://localhost:8080/callback\",
      \"clientName\": \"regional-portal-key-repair-$(date +%s)-$$\",
      \"owner\": \"${APIM_USER}\",
      \"grantType\": \"password refresh_token client_credentials\",
      \"saasApp\": true
    }" \
    "${APIM_URL}/client-registration/v0.17/register"
)"

DCR_CLIENT_ID="$(jq -r '.clientId // empty' <<<"$DCR_RESPONSE")"
DCR_CLIENT_SECRET="$(jq -r '.clientSecret // empty' <<<"$DCR_RESPONSE")"

[[ -n "$DCR_CLIENT_ID" && -n "$DCR_CLIENT_SECRET" ]] || {
  jq . <<<"$DCR_RESPONSE" >&2 || true
  fail "Dynamic client registration did not return credentials."
}

ADMIN_TOKEN_RESPONSE="$(
  curl -ksS \
    -u "${DCR_CLIENT_ID}:${DCR_CLIENT_SECRET}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${APIM_USER}" \
    --data-urlencode "password=${APIM_PASSWORD}" \
    --data-urlencode \
      'scope=apim:app_manage apim:sub_manage apim:subscribe apim:api_key apim:api_generate_key' \
    "${APIM_URL}/oauth2/token"
)"

ADMIN_TOKEN="$(jq -r '.access_token // empty' <<<"$ADMIN_TOKEN_RESPONSE")"

[[ -n "$ADMIN_TOKEN" ]] || {
  jq '{error, error_description}' <<<"$ADMIN_TOKEN_RESPONSE" >&2 || true
  fail "Could not obtain the DevPortal administrative token."
}

log "Locating the ${APPLICATION_NAME} application."

APPLICATIONS="$(
  curl -ksS -G \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H 'Accept: application/json' \
    --data-urlencode "query=${APPLICATION_NAME}" \
    --data-urlencode 'limit=100' \
    "${APIM_URL}/api/am/devportal/v3/applications"
)"

APPLICATION_ID="$(
  jq -r --arg name "$APPLICATION_NAME" '
    (
      if type == "array" then .
      else (.list // .data // [])
      end
    )
    | first(
        .[]
        | select(.name == $name)
        | (.applicationId // .id)
      ) // empty
  ' <<<"$APPLICATIONS"
)"

if [[ -z "$APPLICATION_ID" ]]; then
  log "Application absent; creating ${APPLICATION_NAME}."

  CREATE_RESPONSE="$(
    curl -ksS \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json' \
      -d "{
        \"name\": \"${APPLICATION_NAME}\",
        \"throttlingPolicy\": \"Unlimited\",
        \"description\": \"Server-side application used by the Regional Telco API Business Portal demo.\"
      }" \
      "${APIM_URL}/api/am/devportal/v3/applications"
  )"

  APPLICATION_ID="$(
    jq -r '.applicationId // .id // empty' <<<"$CREATE_RESPONSE"
  )"

  [[ -n "$APPLICATION_ID" ]] || {
    jq . <<<"$CREATE_RESPONSE" >&2 || true
    fail "Application creation did not return an ID."
  }
fi

log "Application ID resolved."

log "Ensuring subscription to ${API_NAME}:${API_VERSION}."

APIS="$(
  curl -ksS -G \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H 'Accept: application/json' \
    --data-urlencode "query=${API_NAME}" \
    --data-urlencode 'limit=100' \
    "${APIM_URL}/api/am/devportal/v3/apis"
)"

API_ID="$(
  jq -r \
    --arg name "$API_NAME" \
    --arg version "$API_VERSION" '
      (
        if type == "array" then .
        else (.list // .data // [])
        end
      )
      | first(
          .[]
          | select(
              .name == $name
              and (.version // "1.0.0") == $version
            )
          | .id
        ) // empty
    ' <<<"$APIS"
)"

[[ -n "$API_ID" ]] ||
  fail "${API_NAME}:${API_VERSION} is absent from the Developer Portal API."

SUBSCRIPTION_BODY="$WORK_DIR/subscription.json"

SUBSCRIPTION_STATUS="$(
  curl -ksS \
    -o "$SUBSCRIPTION_BODY" \
    -w '%{http_code}' \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -d "{
      \"applicationId\": \"${APPLICATION_ID}\",
      \"apiId\": \"${API_ID}\",
      \"throttlingPolicy\": \"Unlimited\"
    }" \
    "${APIM_URL}/api/am/devportal/v3/subscriptions"
)"

case "$SUBSCRIPTION_STATUS" in
  200|201|202)
    log "Subscription created."
    ;;
  409)
    log "Subscription already exists."
    ;;
  *)
    cat "$SUBSCRIPTION_BODY" >&2
    fail "Subscription request returned HTTP ${SUBSCRIPTION_STATUS}."
    ;;
esac

OAUTH_KEYS_ENDPOINT="$(
  printf '%s/api/am/devportal/v3/applications/%s/oauth-keys' \
    "$APIM_URL" \
    "$APPLICATION_ID"
)"

log "Inspecting existing production key mappings."

KEYS_RESPONSE="$(
  curl -ksS \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H 'Accept: application/json' \
    "$OAUTH_KEYS_ENDPOINT"
)"

PRODUCTION_MAPPING_IDS=()

while IFS= read -r mapping_id; do
  [[ -n "$mapping_id" ]] &&
    PRODUCTION_MAPPING_IDS+=("$mapping_id")
done < <(
  jq -r '
    (
      if type == "array" then .
      else (.list // .data // [])
      end
    )
    | .[]
    | select(
        ((.keyType // "") | ascii_upcase) == "PRODUCTION"
      )
    | (.keyMappingId // .id // empty)
  ' <<<"$KEYS_RESPONSE"
)

for mapping_id in "${PRODUCTION_MAPPING_IDS[@]}"; do
  [[ -n "$mapping_id" ]] || continue

  log "Removing stale production key mapping."

  DELETE_STATUS="$(
    curl -ksS \
      -o "$WORK_DIR/delete-response.json" \
      -w '%{http_code}' \
      -X DELETE \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      "${OAUTH_KEYS_ENDPOINT}/${mapping_id}"
  )"

  case "$DELETE_STATUS" in
    200|202|204|404) ;;
    *)
      cat "$WORK_DIR/delete-response.json" >&2 || true
      fail "Could not remove production mapping; HTTP ${DELETE_STATUS}."
      ;;
  esac
done

GENERATE_ENDPOINT="$(
  printf '%s/api/am/devportal/v3/applications/%s/generate-keys' \
    "$APIM_URL" \
    "$APPLICATION_ID"
)"

generate_keys() {
  local payload="$1"
  local response_file="$2"

  curl -ksS \
    -o "$response_file" \
    -w '%{http_code}' \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -d "$payload" \
    "$GENERATE_ENDPOINT"
}

log "Generating a fresh client-credentials production key."

GENERATE_RESPONSE="$WORK_DIR/generated-key.json"

GENERATE_STATUS="$(
  generate_keys \
    '{
      "keyType": "PRODUCTION",
      "grantTypesToBeSupported": ["client_credentials"],
      "callbackUrl": "http://localhost:8080/callback",
      "validityTime": "3600"
    }' \
    "$GENERATE_RESPONSE"
)"

if [[ "$GENERATE_STATUS" != "200" &&
      "$GENERATE_STATUS" != "201" &&
      "$GENERATE_STATUS" != "202" ]]; then
  GENERATE_STATUS="$(
    generate_keys \
      '{
        "keyType": "PRODUCTION",
        "grantTypesToBeSupported": ["client_credentials"]
      }' \
      "$GENERATE_RESPONSE"
  )"
fi

case "$GENERATE_STATUS" in
  200|201|202) ;;
  *)
    cat "$GENERATE_RESPONSE" >&2
    fail "Key generation returned HTTP ${GENERATE_STATUS}."
    ;;
esac

CONSUMER_KEY="$(
  jq -r '
    (.keyMapping // .)
    | (.consumerKey // .consumer_key // empty)
  ' "$GENERATE_RESPONSE"
)"

CONSUMER_SECRET="$(
  jq -r '
    (.keyMapping // .)
    | (.consumerSecret // .consumer_secret // empty)
  ' "$GENERATE_RESPONSE"
)"

[[ -n "$CONSUMER_KEY" && -n "$CONSUMER_SECRET" ]] || {
  jq . "$GENERATE_RESPONSE" >&2
  fail "Generated response did not contain both consumer credentials."
}

log "Validating the new client credentials."

TOKEN_RESPONSE="$(
  curl -ksS \
    -u "${CONSUMER_KEY}:${CONSUMER_SECRET}" \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode \
      'scope=central-policy:evaluate central-policy:read' \
    "${APIM_URL}/oauth2/token"
)"

ACCESS_TOKEN="$(jq -r '.access_token // empty' <<<"$TOKEN_RESPONSE")"

if [[ -z "$ACCESS_TOKEN" ]]; then
  TOKEN_RESPONSE="$(
    curl -ksS \
      -u "${CONSUMER_KEY}:${CONSUMER_SECRET}" \
      --data-urlencode 'grant_type=client_credentials' \
      "${APIM_URL}/oauth2/token"
  )"

  ACCESS_TOKEN="$(jq -r '.access_token // empty' <<<"$TOKEN_RESPONSE")"
fi

[[ -n "$ACCESS_TOKEN" ]] || {
  jq '{error, error_description, scope}' <<<"$TOKEN_RESPONSE" >&2 || true
  fail "The new production credentials could not obtain an access token."
}

log "Refreshing the APIM bootstrap runtime state."

CURRENT_RUNTIME="$(
  "${COMPOSE[@]}" run \
    --rm \
    --no-deps \
    -T \
    --entrypoint cat \
    apim-bootstrapper \
    /workspace/state/runtime.json 2>/dev/null \
  || printf '{}'
)"

if ! jq -e 'type == "object"' <<<"$CURRENT_RUNTIME" >/dev/null 2>&1; then
  CURRENT_RUNTIME='{}'
fi

UPDATED_RUNTIME="$(
  jq \
    --arg updatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg name "$APPLICATION_NAME" \
    --arg applicationId "$APPLICATION_ID" \
    --arg consumerKey "$CONSUMER_KEY" \
    --arg consumerSecret "$CONSUMER_SECRET" '
      .status = "READY"
      | .updatedAt = $updatedAt
      | .application = (
          (.application // {})
          + {
              name: $name,
              applicationId: $applicationId,
              keyType: "PRODUCTION",
              consumerKey: $consumerKey,
              consumerSecret: $consumerSecret
            }
        )
    ' <<<"$CURRENT_RUNTIME"
)"

printf '%s\n' "$UPDATED_RUNTIME" |
  "${COMPOSE[@]}" run \
    --rm \
    --no-deps \
    -T \
    --entrypoint sh \
    apim-bootstrapper \
    -c 'umask 077; cat > /workspace/state/runtime.json'

log "Runtime state refreshed."

STORED_STATE="$(
  "${COMPOSE[@]}" run \
    --rm \
    --no-deps \
    -T \
    --entrypoint cat \
    apim-bootstrapper \
    /workspace/state/runtime.json
)"

jq -e \
  --arg applicationId "$APPLICATION_ID" \
  --arg consumerKey "$CONSUMER_KEY" '
    .status == "READY"
    and .application.applicationId == $applicationId
    and .application.consumerKey == $consumerKey
    and (.application.consumerSecret | length) > 0
  ' <<<"$STORED_STATE" >/dev/null ||
  fail "The refreshed credentials were not persisted."

log "SUCCESS: Regional Portal keys, subscription and runtime state are valid."
