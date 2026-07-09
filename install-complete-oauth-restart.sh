#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

log() {
  printf '[oauth-restart-install] %s\n' "$*"
}

fail() {
  printf '[oauth-restart-install][FAIL] %s\n' "$*" >&2
  exit 1
}

required_files=(
  docker-compose.yml
  docker-compose.oauth-business-controls.yml
  scripts/telco-demo-control.sh
  scripts/register-mi-service-catalog.sh
  scripts/register-oauth-business-control-service-catalog.sh
  scripts/verify-oauth-consent-risk-controls.sh
  services/apim-bootstrapper/package.json
)

for file in "${required_files[@]}"; do
  [[ -f "$file" ]] || fail "Required file is missing: $file"
done

for command in bash python3 docker grep; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Required command is missing: $command"
done

grep -q 'oauth-business-controls-setup.js' \
  services/apim-bootstrapper/package.json ||
  fail "The APIM bootstrap start chain does not include oauth-business-controls-setup.js."

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/oauth-${timestamp}"
mkdir -p "$backup_dir"

cp scripts/telco-demo-control.sh \
  "$backup_dir/telco-demo-control.sh"

cp scripts/verify-oauth-consent-risk-controls.sh \
  "$backup_dir/verify-oauth-consent-risk-controls.sh"

log "Backups written under $backup_dir"

python3 <<'PY'
from pathlib import Path
import re

control_path = Path("scripts/telco-demo-control.sh")
text = control_path.read_text(encoding="utf-8")

# ---------------------------------------------------------------------------
# 1. Ensure the OAuth Compose overlay is part of the authoritative controller.
# ---------------------------------------------------------------------------

if "docker-compose.oauth-business-controls.yml" not in text:
    replacements = [
        (
            "docker-compose.mi.yml \\\n",
            "docker-compose.mi.yml \\\n"
            "  docker-compose.oauth-business-controls.yml \\\n",
        ),
        (
            '"$ROOT_DIR/docker-compose.mi.yml"\n',
            '"$ROOT_DIR/docker-compose.mi.yml"\n'
            '  "$ROOT_DIR/docker-compose.oauth-business-controls.yml"\n',
        ),
        (
            '"docker-compose.mi.yml"\n',
            '"docker-compose.mi.yml"\n'
            '  "docker-compose.oauth-business-controls.yml"\n',
        ),
    ]

    for old, new in replacements:
        if old in text:
            text = text.replace(old, new, 1)
            break
    else:
        raise SystemExit(
            "[oauth-restart-install][FAIL] "
            "Could not add docker-compose.oauth-business-controls.yml "
            "to the controller."
        )

# ---------------------------------------------------------------------------
# 2. Add lifecycle hooks.
#
# restart_stack:
#   Removes/recreates project containers and the network, but preserves named
#   volumes. This ensures rebuilt APIM/MI images and changed health checks are
#   actually applied.
#
# register_oauth_business_controls:
#   Runs the comprehensive MI catalog registration followed by the dedicated
#   OAuth service registration.
#
# verify_oauth_business_controls:
#   Makes the complete restart fail if OAuth scopes, personas, consent,
#   subscriptions, API Product, Service Catalog, or runtime behavior are wrong.
# ---------------------------------------------------------------------------

hook_marker = "# BEGIN OAUTH BUSINESS CONTROLS RESTART HOOKS"

hook_block = r'''
# BEGIN OAUTH BUSINESS CONTROLS RESTART HOOKS

register_oauth_business_controls() {
  if [[ "${SKIP_OAUTH_CATALOG:-false}" == "true" ]]; then
    log "Skipping OAuth/MI Service Catalog registration"
    return 0
  fi

  [[ -f scripts/register-mi-service-catalog.sh ]] ||
    die "scripts/register-mi-service-catalog.sh is missing."

  [[ -f scripts/register-oauth-business-control-service-catalog.sh ]] ||
    die "OAuth business-control Service Catalog script is missing."

  wait_http \
    http://localhost:8290/subscriber-authorization/v1/health \
    "MI subscriber authorization API" \
    false \
    120

  log "Registering the complete MI service inventory"
  bash scripts/register-mi-service-catalog.sh

  log "Registering SubscriberAuthorizationControlAPI in Service Catalog"
  bash scripts/register-oauth-business-control-service-catalog.sh
}

verify_oauth_business_controls() {
  if [[ "${SKIP_OAUTH_VERIFY:-false}" == "true" ]]; then
    log "Skipping OAuth consent/risk verification"
    return 0
  fi

  [[ -f scripts/verify-oauth-consent-risk-controls.sh ]] ||
    die "OAuth consent/risk verification script is missing."

  local attempts
  local delay
  local attempt

  attempts="${OAUTH_VERIFY_ATTEMPTS:-2}"
  delay="${OAUTH_VERIFY_RETRY_DELAY_SECONDS:-15}"

  for attempt in $(seq 1 "$attempts"); do
    log "Running complete OAuth consent/risk verification (${attempt}/${attempts})"

    if bash scripts/verify-oauth-consent-risk-controls.sh; then
      log "OAuth consent/risk controls passed complete verification"
      return 0
    fi

    if (( attempt < attempts )); then
      log "APIM indexing may still be converging; retrying after ${delay} seconds"
      sleep "$delay"
    fi
  done

  die "OAuth consent/risk verification failed after ${attempts} attempt(s)."
}

restart_stack() {
  log "Recreating all project containers while preserving named volumes"

  "${COMPOSE[@]}" down \
    --remove-orphans \
    --timeout 30 ||
    true

  start_stack
}

# END OAUTH BUSINESS CONTROLS RESTART HOOKS
'''

if hook_marker not in text:
    index = text.find("start_stack()")
    if index < 0:
        raise SystemExit(
            "[oauth-restart-install][FAIL] "
            "Could not find start_stack() in telco-demo-control.sh."
        )

    text = text[:index] + hook_block + "\n" + text[index:]

# ---------------------------------------------------------------------------
# 3. Run catalog registration after APIM bootstrap.
# ---------------------------------------------------------------------------

if not re.search(
    r"\bfi\s+register_oauth_business_controls\s+start_portals\b",
    text,
):
    text, count = re.subn(
        r"(\brun_base_bootstrap\s+"
        r"publish_observability_api\s+"
        r"register_all_mi_services\s+fi)\s+"
        r"(start_portals\b)",
        r"\1 register_oauth_business_controls \2",
        text,
        count=1,
    )

    if count != 1:
        raise SystemExit(
            "[oauth-restart-install][FAIL] "
            "Could not add OAuth catalog registration to start_stack()."
        )

# ---------------------------------------------------------------------------
# 4. Run complete OAuth verification before observability traffic is seeded.
# ---------------------------------------------------------------------------

if not re.search(
    r"\bverify_base_demo\s+verify_oauth_business_controls\s+"
    r"seed_observability\b",
    text,
):
    text, count = re.subn(
        r"(\bstart_portals\s+verify_base_demo)\s+"
        r"(seed_observability\b)",
        r"\1 verify_oauth_business_controls \2",
        text,
        count=1,
    )

    if count != 1:
        raise SystemExit(
            "[oauth-restart-install][FAIL] "
            "Could not add OAuth verification to start_stack()."
        )

# ---------------------------------------------------------------------------
# 5. Make restart recreate containers instead of merely stopping/starting them.
# ---------------------------------------------------------------------------

if not re.search(r"restart\)\s*restart_stack\s*;;", text):
    text, count = re.subn(
        r"restart\)\s*stop_stack\s*;?\s*start_stack\s*;;",
        "restart) restart_stack ;;",
        text,
        count=1,
    )

    if count != 1:
        raise SystemExit(
            "[oauth-restart-install][FAIL] "
            "Could not replace the controller restart action."
        )

control_path.write_text(text, encoding="utf-8")
print("[oauth-restart-install] Patched scripts/telco-demo-control.sh")
PY

python3 <<'PY'
from pathlib import Path

path = Path("scripts/verify-oauth-consent-risk-controls.sh")
text = path.read_text(encoding="utf-8")

start_marker = (
    'echo "[oauth-controls-verify] Checking Developer Portal visibility '
    'and application subscriptions."'
)

start = text.find(start_marker)
end = text.find('partner_application_id=', start)

if start < 0 or end < 0:
    raise SystemExit(
        "[oauth-restart-install][FAIL] "
        "Could not locate the Developer Portal verification section."
    )

# Replace the current indexing section. The exact API and API Product names are
# intentional; they prevent an empty product-name variable from causing all 30
# indexing attempts to search for an empty name.
portal_block = r'''echo "[oauth-controls-verify] Checking Developer Portal visibility and application subscriptions."

devportal_apis=""
for attempt in $(seq 1 30); do
  devportal_apis="$(curl -ksS \
    -H "Authorization: Bearer ${devportal_token}" \
    "${APIM_URL}/api/am/devportal/v3/apis?limit=1000")"

  if jq -e '
    any(
      (.list // .data // [])[]?;
      .name == "SubscriberAuthorizationControlAPI" and
      .version == "1.0.0"
    )
  ' <<<"${devportal_apis}" >/dev/null 2>&1; then
    break
  fi

  echo "[oauth-controls-verify] Waiting for SubscriberAuthorizationControlAPI Developer Portal indexing (${attempt}/30)."
  sleep 2
done

if jq -e '
  any(
    (.list // .data // [])[]?;
    .name == "SubscriberAuthorizationControlAPI" and
    .version == "1.0.0"
  )
' <<<"${devportal_apis}" >/dev/null 2>&1; then
  pass "Managed API is visible in the Developer Portal."
else
  fail "Managed API is not visible in the Developer Portal."
  printf '%s\n' "${devportal_apis}" >&2
fi

devportal_products=""
for attempt in $(seq 1 30); do
  devportal_products="$(curl -ksS \
    -H "Authorization: Bearer ${devportal_token}" \
    "${APIM_URL}/api/am/devportal/v3/api-products?limit=1000")"

  if jq -e '
    any(
      (.list // .data // [])[]?;
      .name == "SubscriberAuthorizationBusinessControlsProduct" and
      .version == "1.0.0"
    )
  ' <<<"${devportal_products}" >/dev/null 2>&1; then
    break
  fi

  echo "[oauth-controls-verify] Waiting for API Product SubscriberAuthorizationBusinessControlsProduct Developer Portal indexing (${attempt}/30)."
  sleep 2
done

if jq -e '
  any(
    (.list // .data // [])[]?;
    .name == "SubscriberAuthorizationBusinessControlsProduct" and
    .version == "1.0.0"
  )
' <<<"${devportal_products}" >/dev/null 2>&1; then
  pass "Native API Product is visible and subscribable in the Developer Portal."
else
  fail "Native API Product is not visible in the Developer Portal."
  printf '%s\n' "${devportal_products}" >&2
fi

'''

text = text[:start] + portal_block + text[end:]
path.write_text(text, encoding="utf-8")

print(
    "[oauth-restart-install] "
    "Replaced Developer Portal indexing verification with exact names."
)
PY

chmod +x \
  scripts/telco-demo-control.sh \
  scripts/register-mi-service-catalog.sh \
  scripts/register-oauth-business-control-service-catalog.sh \
  scripts/verify-oauth-consent-risk-controls.sh

log "Checking shell syntax"

bash -n scripts/telco-demo-control.sh
bash -n scripts/register-mi-service-catalog.sh
bash -n scripts/register-oauth-business-control-service-catalog.sh
bash -n scripts/verify-oauth-consent-risk-controls.sh

if docker compose version >/dev/null 2>&1; then
  compose=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  compose=(docker-compose)
else
  fail "Docker Compose is unavailable."
fi

compose_files=(
  docker-compose.yml
  docker-compose.kafka.yml
  docker-compose.opa.yml
  docker-compose.mi.yml
  docker-compose.oauth-business-controls.yml
  docker-compose.commercial.yml
  docker-compose.mi.soap.yml
  docker-compose.observability.yml
  docker-compose.runtime-persistence.yml
  docker-compose.audit-siem.yml
  docker-compose.central-policy.yml
)

compose_command=("${compose[@]}")
for file in "${compose_files[@]}"; do
  [[ -f "$file" ]] && compose_command+=(-f "$file")
done

log "Validating merged Docker Compose topology"
"${compose_command[@]}" config >/dev/null

log "Checking resulting lifecycle integration"

grep -q 'docker-compose.oauth-business-controls.yml' \
  scripts/telco-demo-control.sh ||
  fail "OAuth Compose overlay is absent from the controller."

grep -q 'register_oauth_business_controls' \
  scripts/telco-demo-control.sh ||
  fail "OAuth catalog hook is absent from the controller."

grep -q 'verify_oauth_business_controls' \
  scripts/telco-demo-control.sh ||
  fail "OAuth verification hook is absent from the controller."

grep -Eq 'restart\)[[:space:]]*restart_stack' \
  scripts/telco-demo-control.sh ||
  fail "Restart does not use container recreation."

cat <<EOF

[oauth-restart-install] Installation passed.

Normal fresh-container restart, preserving APIM and other named-volume state:

  bash scripts/telco-demo-control.sh restart

Completely clean initialization, including deletion and recreation of named
volumes:

  bash scripts/telco-demo-control.sh reset

Backups:

  ${backup_dir}

EOF
