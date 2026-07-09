#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"
cd "$ROOT_DIR"

REGISTER_SCRIPT="scripts/register-oauth-business-control-service-catalog.sh"
VERIFY_SCRIPT="scripts/verify-oauth-consent-risk-controls.sh"

APIM_HEALTH_URL="${APIM_HEALTH_URL:-https://localhost:9443/services/Version}"

OAUTH_MI_HEALTH_URL="${OAUTH_MI_HEALTH_URL:-http://localhost:8290/subscriber-authorization/v1/health}"

log() {
  printf '[oauth-post-start] %s\n' "$*"
}

fail() {
  printf '[oauth-post-start][FAIL] %s\n' "$*" >&2
  exit 1
}

wait_http() {
  local url="$1"
  local label="$2"
  local insecure="${3:-false}"
  local attempts="${4:-180}"
  local attempt

  local curl_args=(
    -fsS
    --max-time
    5
  )

  if [[ "$insecure" == "true" ]]; then
    curl_args=(
      -kfsS
      --max-time
      5
    )
  fi

  log "Waiting for ${label}"

  for attempt in $(seq 1 "$attempts"); do
    if curl "${curl_args[@]}" "$url" >/dev/null 2>&1; then
      log "${label} is ready"
      return 0
    fi

    sleep 2
  done

  fail "${label} did not become ready: ${url}"
}

run_with_retries() {
  local label="$1"
  local attempts="$2"
  local delay="$3"
  shift 3

  local attempt

  for attempt in $(seq 1 "$attempts"); do
    log "${label} (${attempt}/${attempts})"

    if "$@"; then
      return 0
    fi

    if (( attempt < attempts )); then
      log "${label} failed; retrying after ${delay} seconds"
      sleep "$delay"
    fi
  done

  fail "${label} failed after ${attempts} attempt(s)"
}

if [[ "${SKIP_OAUTH_POST_START:-false}" == "true" ]]; then
  log "OAuth post-start initialization was skipped"
  exit 0
fi

[[ -f "$REGISTER_SCRIPT" ]] ||
  fail "Missing $REGISTER_SCRIPT"

[[ -f "$VERIFY_SCRIPT" ]] ||
  fail "Missing $VERIFY_SCRIPT"

wait_http \
  "$APIM_HEALTH_URL" \
  "WSO2 API Manager" \
  true \
  "${OAUTH_APIM_READY_ATTEMPTS:-180}"

wait_http \
  "$OAUTH_MI_HEALTH_URL" \
  "MI-managed subscriber authorization API" \
  false \
  "${OAUTH_MI_READY_ATTEMPTS:-180}"

if [[ "${SKIP_OAUTH_CATALOG_REGISTRATION:-false}" != "true" ]]; then
  run_with_retries \
    "Registering OAuth business-control service in APIM Service Catalog" \
    "${OAUTH_CATALOG_ATTEMPTS:-3}" \
    "${OAUTH_CATALOG_RETRY_DELAY_SECONDS:-10}" \
    bash "$REGISTER_SCRIPT"
else
  log "OAuth Service Catalog registration was skipped"
fi

if [[ "${SKIP_OAUTH_VERIFY:-false}" != "true" ]]; then
  run_with_retries \
    "Running complete OAuth consent and risk-control verification" \
    "${OAUTH_VERIFY_ATTEMPTS:-3}" \
    "${OAUTH_VERIFY_RETRY_DELAY_SECONDS:-15}" \
    bash "$VERIFY_SCRIPT"
else
  log "OAuth consent and risk-control verification was skipped"
fi

log "OAuth business controls are fully initialized and verified"
