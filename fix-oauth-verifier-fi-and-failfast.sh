#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

VERIFY="scripts/verify-oauth-consent-risk-controls.sh"
HELPER="scripts/complete-oauth-post-start.sh"

log() {
  printf '[oauth-verifier-control-fix] %s\n' "$*"
}

fail() {
  printf '[oauth-verifier-control-fix][FAIL] %s\n' "$*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 ||
  fail "python3 is required."

[[ -f "$VERIFY" ]] ||
  fail "Missing $VERIFY"

[[ -f "$HELPER" ]] ||
  fail "Missing $HELPER"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/oauth-verifier-control-${timestamp}"

mkdir -p "$backup_dir"

cp "$VERIFY" "$backup_dir/verify-oauth-consent-risk-controls.sh"
cp "$HELPER" "$backup_dir/complete-oauth-post-start.sh"

log "Backups written under $backup_dir"

python3 - "$VERIFY" <<'PY'
from pathlib import Path
import re
import subprocess
import sys
import tempfile

path = Path(sys.argv[1])
original = path.read_text(encoding="utf-8")
lines = original.splitlines(keepends=True)


def syntax_result(content: str):
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        suffix=".sh",
        delete=False,
    ) as temporary:
        temporary.write(content)
        temporary_path = temporary.name

    result = subprocess.run(
        ["/bin/bash", "-n", temporary_path],
        text=True,
        capture_output=True,
    )

    Path(temporary_path).unlink(missing_ok=True)

    return result.returncode, result.stderr


return_code, error_text = syntax_result(original)

if return_code == 0:
    print(
        "[oauth-verifier-control-fix] "
        "Verifier syntax is already valid."
    )
    raise SystemExit(0)

print(
    "[oauth-verifier-control-fix] "
    f"Current verifier syntax error: {error_text.strip()}"
)

bootstrap_pass_index = None

for index, line in enumerate(lines):
    if "Bootstrap state exists." in line:
        bootstrap_pass_index = index
        break

if bootstrap_pass_index is None:
    raise SystemExit(
        "[oauth-verifier-control-fix][FAIL] "
        "Could not locate the bootstrap-state PASS line."
    )

# The previous state-section replacement ended at the PASS statement but left
# the closing `fi` from the original condition. Remove an immediately
# following standalone fi first.
candidate_indexes = []

for index in range(
    bootstrap_pass_index + 1,
    min(len(lines), bootstrap_pass_index + 15),
):
    stripped = lines[index].strip()

    if not stripped or stripped.startswith("#"):
        continue

    if stripped == "fi":
        candidate_indexes.append(index)

    # Do not wander into the next functional section.
    if (
        "API Product bootstrap state" in stripped
        or "Sandbox persona exists" in stripped
        or stripped.startswith("echo ")
    ):
        break

# Also examine the exact line reported by Bash.
line_match = re.search(r"line\s+([0-9]+)", error_text)

if line_match:
    error_index = int(line_match.group(1)) - 1

    for index in range(
        max(0, error_index - 8),
        min(len(lines), error_index + 9),
    ):
        if lines[index].strip() == "fi":
            candidate_indexes.append(index)

candidate_indexes = list(dict.fromkeys(candidate_indexes))

successful_repairs = []

for candidate_index in candidate_indexes:
    candidate_lines = lines[:candidate_index] + lines[candidate_index + 1:]
    candidate_content = "".join(candidate_lines)

    candidate_status, candidate_error = syntax_result(candidate_content)

    if candidate_status == 0:
        distance = abs(candidate_index - bootstrap_pass_index)

        successful_repairs.append(
            (
                distance,
                candidate_index,
                candidate_content,
            )
        )

if not successful_repairs:
    print(
        "[oauth-verifier-control-fix][FAIL] "
        "Could not safely identify the orphan fi.",
        file=sys.stderr,
    )

    start = max(0, bootstrap_pass_index - 12)
    end = min(len(lines), bootstrap_pass_index + 25)

    print(
        "[oauth-verifier-control-fix] "
        "State section requiring inspection:",
        file=sys.stderr,
    )

    for index in range(start, end):
        print(
            f"{index + 1:4d}: {lines[index].rstrip()}",
            file=sys.stderr,
        )

    raise SystemExit(1)

successful_repairs.sort(key=lambda item: item[0])

_, removed_index, repaired = successful_repairs[0]

path.write_text(repaired, encoding="utf-8")

print(
    "[oauth-verifier-control-fix] "
    f"Removed orphan fi from original line {removed_index + 1}."
)
PY

cat > "$HELPER" <<'HELPER'
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
HELPER

chmod +x \
  "$VERIFY" \
  "$HELPER"

log "Validating both scripts"

if ! bash -n "$VERIFY"; then
  cp \
    "$backup_dir/verify-oauth-consent-risk-controls.sh" \
    "$VERIFY"

  cp \
    "$backup_dir/complete-oauth-post-start.sh" \
    "$HELPER"

  fail "Verifier remains invalid; original files were restored."
fi

if ! bash -n "$HELPER"; then
  cp \
    "$backup_dir/verify-oauth-consent-risk-controls.sh" \
    "$VERIFY"

  cp \
    "$backup_dir/complete-oauth-post-start.sh" \
    "$HELPER"

  fail "Helper is invalid; original files were restored."
fi

log "Verifier syntax now passes"

echo
echo "[oauth-verifier-control-fix] Corrected state-reading section:"

state_line="$(
  grep -n \
    'Reading bootstrap state from the running Compose' \
    "$VERIFY" |
    head -n 1 |
    cut -d: -f1
)"

if [[ -n "$state_line" ]]; then
  start_line=$((state_line > 3 ? state_line - 3 : 1))
  end_line=$((state_line + 35))

  sed -n "${start_line},${end_line}p" "$VERIFY" |
    nl -ba -v "$start_line"
fi

cat <<EOF

[oauth-verifier-control-fix] Repair completed.

Backups:
  ${backup_dir}

First, run the verifier directly:

  bash scripts/verify-oauth-consent-risk-controls.sh

Only after it passes, validate the complete automatic flow:

  COMPOSE_IGNORE_ORPHANS=1 bash scripts/complete-oauth-post-start.sh

EOF
