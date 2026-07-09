#!/usr/bin/env bash
set -Eeo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"
cd "$ROOT_DIR"

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"
PORTAL_STATUS_URL="${PORTAL_STATUS_URL:-http://127.0.0.1:8080/portal-status}"

WORK_DIR="$(
  mktemp -d \
    "${TMPDIR:-/tmp}/api-inventory.XXXXXX"
)"

trap 'rm -rf "$WORK_DIR"' EXIT

log() {
  printf '[api-inventory] %s\n' "$*"
}

fail() {
  printf '[api-inventory][FAIL] %s\n' "$*" >&2
  exit 1
}

log "Checking APIM readiness."

curl -kfsS \
  --connect-timeout 3 \
  --max-time 10 \
  "${APIM_URL}/services/Version" \
  >/dev/null ||
  fail "APIM is not ready at ${APIM_URL}."

log "Reading the Telco portal runtime state."

curl -fsS \
  --connect-timeout 3 \
  --max-time 10 \
  "$PORTAL_STATUS_URL" \
  >"$WORK_DIR/portal.json" ||
  fail "Portal status is unavailable at ${PORTAL_STATUS_URL}."

jq -e \
  '.status == "READY"' \
  "$WORK_DIR/portal.json" \
  >/dev/null ||
  {
    jq . "$WORK_DIR/portal.json" >&2
    fail "Portal runtime state is not READY."
  }

publisher_expected=()
devportal_expected=()

while IFS= read -r api_name; do
  [[ -n "$api_name" ]] ||
    continue

  publisher_expected+=("$api_name")
done < <(
  jq -r '
    .apis[]?
    | .name
    | select(type == "string" and length > 0)
  ' "$WORK_DIR/portal.json"
)

while IFS= read -r api_name; do
  [[ -n "$api_name" ]] ||
    continue

  devportal_expected+=("$api_name")
done < <(
  jq -r '
    .apis[]?
    | select(
        (
          .protocol // "REST"
          | ascii_upcase
        ) != "SOAP"
      )
    | select(
        (
          .protocol // "REST"
          | ascii_upcase
        ) != "ASYNC"
      )
    | .name
    | select(type == "string" and length > 0)
  ' "$WORK_DIR/portal.json"
)

publisher_expected+=(
  "TelcoObservabilityAPI"
  "SubscriberAuthorizationControlAPI"
)

devportal_expected+=(
  "SubscriberAuthorizationControlAPI"
)

if [[ "${#publisher_expected[@]}" -eq 0 ]]; then
  fail "No expected APIs were found in portal state."
fi

log "Registering a temporary read-only management client."

dcr_payload="$(
  jq -nc \
    --arg name \
      "api-inventory-$(date +%s)-$$" '
      {
        callbackUrl:
          "http://localhost:8080/callback",
        clientName: $name,
        owner: "admin",
        grantType:
          "password refresh_token",
        saasApp: true
      }
    '
)"

dcr_response="$(
  curl -ksS \
    -u "${APIM_USER}:${APIM_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d "$dcr_payload" \
    "${APIM_URL}/client-registration/v0.17/register"
)"

client_id="$(
  jq -r \
    '.clientId // empty' \
    <<<"$dcr_response"
)"

client_secret="$(
  jq -r \
    '.clientSecret // empty' \
    <<<"$dcr_response"
)"

if [[ -z "$client_id" ||
      -z "$client_secret" ]]
then
  jq . <<<"$dcr_response" >&2 || true
  fail "Management-client registration failed."
fi

token_response="$(
  curl -ksS \
    -u "${client_id}:${client_secret}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${APIM_USER}" \
    --data-urlencode "password=${APIM_PASSWORD}" \
    --data-urlencode \
      'scope=apim:api_view apim:subscribe' \
    "${APIM_URL}/oauth2/token"
)"

access_token="$(
  jq -r \
    '.access_token // empty' \
    <<<"$token_response"
)"

if [[ -z "$access_token" ]]; then
  jq '
    del(
      .access_token,
      .refresh_token,
      .id_token
    )
  ' <<<"$token_response" >&2 || true

  fail "Management-token acquisition failed."
fi

publisher_visible() {
  local api_name="$1"
  local response

  response="$(
    curl -ksS -G \
      -H "Authorization: Bearer ${access_token}" \
      --data-urlencode "query=name:${api_name}" \
      --data-urlencode 'limit=100' \
      "${APIM_URL}/api/am/publisher/v4/apis"
  )"

  jq -e \
    --arg name "$api_name" '
      any(
        (.list // .data // [])[]?;
        .name == $name and
        (
          .lifeCycleStatus == "PUBLISHED" or
          .lifecycleStatus == "PUBLISHED" or
          .state == "PUBLISHED"
        )
      )
    ' <<<"$response" \
    >/dev/null
}

devportal_visible() {
  local api_name="$1"
  local response

  response="$(
    curl -ksS -G \
      -H "Authorization: Bearer ${access_token}" \
      --data-urlencode "query=name:${api_name}" \
      --data-urlencode 'limit=100' \
      "${APIM_URL}/api/am/devportal/v3/apis"
  )"

  jq -e \
    --arg name "$api_name" '
      any(
        (.list // .data // [])[]?;
        .name == $name
      )
    ' <<<"$response" \
    >/dev/null
}

log "Checking Publisher inventory."

for api_name in "${publisher_expected[@]}"; do
  found=false

  for attempt in $(seq 1 30); do
    if publisher_visible "$api_name"; then
      printf \
        '[api-inventory][PASS] Publisher: %s\n' \
        "$api_name"

      found=true
      break
    fi

    sleep 2
  done

  if [[ "$found" != "true" ]]; then
    fail \
      "API is absent or not PUBLISHED in Publisher: ${api_name}"
  fi
done

log "Checking Developer Portal inventory."

for api_name in "${devportal_expected[@]}"; do
  found=false

  for attempt in $(seq 1 30); do
    if devportal_visible "$api_name"; then
      printf \
        '[api-inventory][PASS] Developer Portal: %s\n' \
        "$api_name"

      found=true
      break
    fi

    sleep 2
  done

  if [[ "$found" != "true" ]]; then
    fail \
      "API is not visible in Developer Portal: ${api_name}"
  fi
done

log "Publisher and Developer Portal inventories are complete."
