#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

CONTROL="scripts/telco-demo-control.sh"
VERIFY="scripts/verify-oauth-consent-risk-controls.sh"
REGISTER="scripts/register-oauth-business-control-service-catalog.sh"
HELPER="scripts/complete-oauth-post-start.sh"

log() {
  printf '[oauth-restart-v2] %s\n' "$*"
}

fail() {
  printf '[oauth-restart-v2][FAIL] %s\n' "$*" >&2
  exit 1
}

for command in bash python3 curl jq docker; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Required command is missing: $command"
done

required_files=(
  docker-compose.yml
  docker-compose.oauth-business-controls.yml
  "$CONTROL"
  "$VERIFY"
  "$REGISTER"
)

for file in "${required_files[@]}"; do
  [[ -f "$file" ]] || fail "Required file is missing: $file"
done

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/oauth-v2-${timestamp}"
mkdir -p "$backup_dir"

cp "$CONTROL" "$backup_dir/telco-demo-control.sh"
cp "$VERIFY" "$backup_dir/verify-oauth-consent-risk-controls.sh"

log "Backups written under $backup_dir"

python3 - "$CONTROL" "$VERIFY" <<'PY'
from pathlib import Path
import re
import sys

control_path = Path(sys.argv[1])
verify_path = Path(sys.argv[2])

control = control_path.read_text(encoding="utf-8")
verify = verify_path.read_text(encoding="utf-8")

# ---------------------------------------------------------------------------
# 1. Add the OAuth Compose overlay as the final Compose file.
#
# Adding it immediately before COMPOSE is constructed means it overrides the
# base MI configuration instead of being overridden by docker-compose.mi.yml.
# ---------------------------------------------------------------------------

overlay_name = "docker-compose.oauth-business-controls.yml"
compose_constructor = re.search(
    r'COMPOSE\s*=\s*\(\s*"\$\{DC\[@\]\}"\s*\)',
    control,
)

if compose_constructor is None:
    raise SystemExit(
        "[oauth-restart-v2][FAIL] "
        "Could not locate the COMPOSE constructor in telco-demo-control.sh."
    )

compose_prefix = control[:compose_constructor.start()]

if overlay_name not in compose_prefix:
    overlay_statement = (
        '[[ -f docker-compose.oauth-business-controls.yml ]] && '
        'COMPOSE_FILES+=(docker-compose.oauth-business-controls.yml)\n'
    )

    control = (
        control[:compose_constructor.start()]
        + overlay_statement
        + control[compose_constructor.start():]
    )

# ---------------------------------------------------------------------------
# 2. Insert the OAuth post-start hook.
#
# First try the known command sequence. If the controller was reformatted,
# locate verify_base_demo inside start_stack() and inject directly after it.
# ---------------------------------------------------------------------------

helper_call = "bash scripts/complete-oauth-post-start.sh"

if helper_call not in control:
    sequence = re.compile(
        r"\bstart_portals\b"
        r"(?P<ws1>\s+)"
        r"\bverify_base_demo\b"
        r"(?P<ws2>\s+)"
        r"\bseed_observability\b"
    )

    match = sequence.search(control)

    if match:
        replacement = (
            "start_portals"
            + match.group("ws1")
            + "verify_base_demo"
            + match.group("ws2")
            + helper_call
            + match.group("ws2")
            + "seed_observability"
        )

        control = (
            control[:match.start()]
            + replacement
            + control[match.end():]
        )
    else:
        start_index = control.find("start_stack()")

        if start_index < 0:
            raise SystemExit(
                "[oauth-restart-v2][FAIL] "
                "Could not locate start_stack()."
            )

        case_index = control.find('case "$ACTION"', start_index)

        if case_index < 0:
            raise SystemExit(
                "[oauth-restart-v2][FAIL] "
                "Could not locate command dispatch after start_stack()."
            )

        start_segment = control[start_index:case_index]
        verification_calls = list(
            re.finditer(r"\bverify_base_demo\b", start_segment)
        )

        if not verification_calls:
            raise SystemExit(
                "[oauth-restart-v2][FAIL] "
                "Could not locate verify_base_demo inside start_stack()."
            )

        call = verification_calls[-1]
        insertion_index = start_index + call.end()

        control = (
            control[:insertion_index]
            + "\n  "
            + helper_call
            + control[insertion_index:]
        )

# ---------------------------------------------------------------------------
# 3. Make restart recreate all containers, but preserve named volumes.
#
# reset still removes named volumes and therefore remains the completely clean
# initialization option.
# ---------------------------------------------------------------------------

if "recreate_stack()" not in control:
    case_index = control.find('case "$ACTION"')

    if case_index < 0:
        raise SystemExit(
            "[oauth-restart-v2][FAIL] "
            "Could not locate the ACTION dispatch block."
        )

    recreate_function = r'''
recreate_stack() {
  log "Recreating the complete demo while preserving named volumes"

  "${COMPOSE[@]}" down \
    --remove-orphans \
    --timeout 30 ||
    true

  start_stack
}

'''

    control = (
        control[:case_index]
        + recreate_function
        + control[case_index:]
    )

if not re.search(r"restart\)\s*recreate_stack\s*;;", control):
    patterns = [
        re.compile(
            r"restart\)\s*stop_stack\s*;?\s*start_stack\s*;;"
        ),
        re.compile(
            r"restart\)\s*restart_stack\s*;;"
        ),
    ]

    replaced = False

    for pattern in patterns:
        control, count = pattern.subn(
            "restart) recreate_stack ;;",
            control,
            count=1,
        )

        if count == 1:
            replaced = True
            break

    if not replaced:
        raise SystemExit(
            "[oauth-restart-v2][FAIL] "
            "Could not update the restart action."
        )

# ---------------------------------------------------------------------------
# 4. Repair the blank API Product indexing variable.
#
# The verifier output showed:
#
#   Waiting for API Product  Developer Portal indexing
#
# Detect the exact variable used in that message and initialize it from the
# API Product object already retrieved earlier in the verifier.
# ---------------------------------------------------------------------------

product_fix_marker = "# BEGIN OAUTH API PRODUCT NAME RECOVERY"

if product_fix_marker not in verify:
    variable_patterns = [
        re.compile(
            r"Waiting for API Product "
            r"\$\{([A-Za-z_][A-Za-z0-9_]*)\} "
            r"Developer Portal indexing"
        ),
        re.compile(
            r"Waiting for API Product "
            r"\$([A-Za-z_][A-Za-z0-9_]*) "
            r"Developer Portal indexing"
        ),
    ]

    product_name_variable = None

    for pattern in variable_patterns:
        variable_match = pattern.search(verify)

        if variable_match:
            product_name_variable = variable_match.group(1)
            break

    if product_name_variable:
        portal_marker = (
            'echo "[oauth-controls-verify] Checking Developer Portal '
            'visibility and application subscriptions."'
        )

        portal_index = verify.find(portal_marker)

        if portal_index < 0:
            raise SystemExit(
                "[oauth-restart-v2][FAIL] "
                "Could not locate the Developer Portal verification section."
            )

        product_fix = r'''
# BEGIN OAUTH API PRODUCT NAME RECOVERY
oauth_product_json='{}'

if [[ -n "${api_product:-}" ]]; then
  oauth_product_json="${api_product}"
elif [[ -n "${product:-}" ]]; then
  oauth_product_json="${product}"
elif [[ -n "${api_product_response:-}" ]]; then
  oauth_product_json="${api_product_response}"
fi

if [[ -z "${__PRODUCT_NAME_VARIABLE__:-}" ]]; then
  __PRODUCT_NAME_VARIABLE__="$(
    jq -r '.name // empty' \
      <<<"${oauth_product_json}" \
      2>/dev/null ||
      true
  )"
fi

if [[ -z "${__PRODUCT_NAME_VARIABLE__}" ]]; then
  fail "Could not resolve the API Product name before Developer Portal indexing."
fi
# END OAUTH API PRODUCT NAME RECOVERY

'''

        product_fix = product_fix.replace(
            "__PRODUCT_NAME_VARIABLE__",
            product_name_variable,
        )

        verify = (
            verify[:portal_index]
            + product_fix
            + verify[portal_index:]
        )

control_path.write_text(control, encoding="utf-8")
verify_path.write_text(verify, encoding="utf-8")

print(
    "[oauth-restart-v2] "
    "Controller and verifier patches were written."
)
PY

cat > "$HELPER" <<'BASH_HELPER'
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
BASH_HELPER

cat > scripts/restart-complete-demo.sh <<'BASH_RESTART'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"

exec bash \
  "${ROOT_DIR}/scripts/telco-demo-control.sh" \
  restart
BASH_RESTART

chmod +x \
  "$CONTROL" \
  "$VERIFY" \
  "$REGISTER" \
  "$HELPER" \
  scripts/restart-complete-demo.sh

log "Validating Bash syntax"

syntax_failed=false

for script in \
  "$CONTROL" \
  "$VERIFY" \
  "$REGISTER" \
  "$HELPER" \
  scripts/restart-complete-demo.sh
do
  if ! bash -n "$script"; then
    printf '[oauth-restart-v2][FAIL] Syntax validation failed: %s\n' \
      "$script" >&2
    syntax_failed=true
  fi
done

if [[ "$syntax_failed" == "true" ]]; then
  log "Restoring controller and verifier backups"

  cp \
    "$backup_dir/telco-demo-control.sh" \
    "$CONTROL"

  cp \
    "$backup_dir/verify-oauth-consent-risk-controls.sh" \
    "$VERIFY"

  rm -f \
    "$HELPER" \
    scripts/restart-complete-demo.sh

  fail "Patch produced invalid shell syntax; original files were restored."
fi

grep -q \
  'docker-compose.oauth-business-controls.yml' \
  "$CONTROL" ||
  fail "OAuth Compose overlay was not added to the controller."

grep -q \
  'bash scripts/complete-oauth-post-start.sh' \
  "$CONTROL" ||
  fail "OAuth post-start hook was not added to start_stack()."

grep -Eq \
  'restart\)[[:space:]]*recreate_stack[[:space:]]*;;' \
  "$CONTROL" ||
  fail "Restart was not changed to container recreation."

log "Installation completed successfully"

cat <<EOF

The complete restart command is now either:

  bash scripts/telco-demo-control.sh restart

or:

  bash scripts/restart-complete-demo.sh

A completely clean reset that also deletes named volumes remains:

  bash scripts/telco-demo-control.sh reset

Backups are available under:

  ${backup_dir}

EOF
