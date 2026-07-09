#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"
cd "$ROOT_DIR"

REGISTER_SCRIPT="scripts/register-oauth-business-control-service-catalog.sh"
VERIFY_SCRIPT="scripts/verify-oauth-consent-risk-controls.sh"
RECONCILE_SCRIPT="scripts/reconcile-oauth-control-plane.sh"

APIM_HEALTH_URL="${APIM_HEALTH_URL:-https://localhost:9443/services/Version}"
OAUTH_MI_HEALTH_URL="${OAUTH_MI_HEALTH_URL:-http://localhost:8290/subscriber-authorization/v1/health}"

export COMPOSE_IGNORE_ORPHANS="${COMPOSE_IGNORE_ORPHANS:-1}"

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
  local status=1

  for attempt in $(seq 1 "$attempts"); do
    log "${label} (${attempt}/${attempts})"

    set +e
    "$@"
    status=$?
    set -e

    if [[ "$status" -eq 0 ]]; then
      log "${label} succeeded"
      return 0
    fi

    log "${label} failed with exit status ${status}"

    if (( attempt < attempts )); then
      log "Retrying after ${delay} seconds"
      sleep "$delay"
    fi
  done

  return "$status"
}

if [[ "${SKIP_OAUTH_POST_START:-false}" == "true" ]]; then
  log "OAuth post-start initialization was skipped"
  exit 0
fi

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

if [[ "${SKIP_OAUTH_RECONCILE:-false}" != "true" ]]; then
  [[ -f "$RECONCILE_SCRIPT" ]] ||
    fail "Missing $RECONCILE_SCRIPT"

  if ! run_with_retries \
    "Reconciling OAuth API deployment, applications, credentials and API Product" \
    "${OAUTH_RECONCILE_ATTEMPTS:-3}" \
    "${OAUTH_RECONCILE_RETRY_DELAY_SECONDS:-15}" \
    bash "$RECONCILE_SCRIPT"
  then
    fail "OAuth control-plane reconciliation failed."
  fi
else
  log "OAuth control-plane reconciliation was skipped"
fi

if [[ "${SKIP_OAUTH_CATALOG_REGISTRATION:-false}" != "true" ]]; then
  [[ -f "$REGISTER_SCRIPT" ]] ||
    fail "Missing $REGISTER_SCRIPT"

  if ! run_with_retries \
    "Registering OAuth business-control service in APIM Service Catalog" \
    "${OAUTH_CATALOG_ATTEMPTS:-3}" \
    "${OAUTH_CATALOG_RETRY_DELAY_SECONDS:-10}" \
    bash "$REGISTER_SCRIPT"
  then
    fail "OAuth Service Catalog registration failed."
  fi
else
  log "OAuth Service Catalog registration was skipped"
fi

if [[ "${SKIP_OAUTH_VERIFY:-false}" != "true" ]]; then
  [[ -f "$VERIFY_SCRIPT" ]] ||
    fail "Missing $VERIFY_SCRIPT"

  log "Checking OAuth verifier syntax before execution"

  if ! bash -n "$VERIFY_SCRIPT"; then
    fail "OAuth verifier has invalid Bash syntax."
  fi

  if ! run_with_retries \
    "Running complete OAuth consent and risk-control verification" \
    "${OAUTH_VERIFY_ATTEMPTS:-3}" \
    "${OAUTH_VERIFY_RETRY_DELAY_SECONDS:-15}" \
    bash "$VERIFY_SCRIPT"
  then
    fail "OAuth consent and risk-control verification failed."
  fi

  log "OAuth business controls are fully initialized and verified"
else
  log "OAuth business controls initialized; verification was skipped"
fi
