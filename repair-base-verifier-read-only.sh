#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

VERIFY="scripts/verify-apim-bootstrap.sh"
COMPOSE_HELPER="scripts/oauth-compose-context.sh"

log() {
  printf '[base-verifier-repair] %s\n' "$*"
}

fail() {
  printf '[base-verifier-repair][FAIL] %s\n' "$*" >&2
  exit 1
}

for command in bash python3 docker curl; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Required command is missing: $command"
done

[[ -f "$VERIFY" ]] ||
  fail "Missing $VERIFY"

[[ -f "$COMPOSE_HELPER" ]] ||
  fail "Missing $COMPOSE_HELPER"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/base-verifier-read-only-${timestamp}"

mkdir -p "$backup_dir"
cp "$VERIFY" "$backup_dir/verify-apim-bootstrap.sh"

log "Backup written to $backup_dir"

python3 - "$VERIFY" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

# The verifier now uses Bash because oauth-compose-context.sh exports
# the OAUTH_COMPOSE array containing the complete running topology.
lines = text.splitlines()

if lines and lines[0].startswith("#!"):
    lines[0] = "#!/usr/bin/env bash"
else:
    lines.insert(0, "#!/usr/bin/env bash")

text = "\n".join(lines) + "\n"

old_command = (
    "docker-compose run --rm "
    "apim-bootstrapper sh -lc '"
)

new_command = (
    '"${OAUTH_COMPOSE[@]}" run '
    '--rm --no-deps '
    "apim-bootstrapper sh -lc '"
)

if old_command in text:
    text = text.replace(
        old_command,
        new_command,
        1,
    )
elif new_command not in text:
    raise SystemExit(
        "[base-verifier-repair][FAIL] "
        "Could not locate the apim-bootstrapper Compose command."
    )

visibility_marker = (
    'echo "Checking APIM DevPortal API visibility..."'
)

preflight = r'''
echo "Resolving the running stack's complete Compose topology."

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"

# shellcheck source=scripts/oauth-compose-context.sh
source "${ROOT_DIR}/scripts/oauth-compose-context.sh"

resolve_oauth_compose_context "${ROOT_DIR}"

echo "Waiting for WSO2 API Manager to become ready."

apim_ready=false

for attempt in $(seq 1 120); do
  if curl -kfsS \
      --connect-timeout 2 \
      --max-time 5 \
      "${APIM_URL}/services/Version" \
      >/dev/null 2>&1
  then
    echo "WSO2 API Manager is ready."
    apim_ready=true
    break
  fi

  printf \
    'Waiting for APIM: attempt %d/120\n' \
    "${attempt}"

  sleep 2
done

if [[ "${apim_ready}" != "true" ]]; then
  echo "ERROR: WSO2 API Manager did not become ready."

  docker ps -a \
    --filter name=wso2-apim-4-7

  docker logs \
    --tail=200 \
    wso2-apim-4-7 \
    2>/dev/null ||
    true

  exit 1
fi

'''

if preflight.strip() not in text:
    if visibility_marker not in text:
        raise SystemExit(
            "[base-verifier-repair][FAIL] "
            "Could not locate the DevPortal visibility section."
        )

    text = text.replace(
        visibility_marker,
        preflight + visibility_marker,
        1,
    )

path.write_text(
    text,
    encoding="utf-8",
)

print(
    "[base-verifier-repair] "
    "Installed APIM readiness check and read-only Compose execution."
)
PY

chmod +x "$VERIFY"

bash -n "$VERIFY" ||
  {
    cp "$backup_dir/verify-apim-bootstrap.sh" "$VERIFY"
    fail "Verifier syntax failed; original restored."
  }

grep -Fq \
  '"${OAUTH_COMPOSE[@]}" run --rm --no-deps apim-bootstrapper' \
  "$VERIFY" ||
  fail "Read-only Compose run command was not installed."

grep -Fq \
  'Waiting for WSO2 API Manager to become ready.' \
  "$VERIFY" ||
  fail "APIM readiness check was not installed."

log "Static validation passed."

###############################################################################
# APIM may currently be starting because the previous verifier launched it.
# Wait for it instead of restarting or recreating anything.
###############################################################################

log "Waiting for the currently running APIM container."

ready=false

for attempt in $(seq 1 120); do
  status="$(
    docker inspect \
      --format '{{.State.Status}}' \
      wso2-apim-4-7 \
      2>/dev/null ||
      true
  )"

  if curl -kfsS \
      --connect-timeout 2 \
      --max-time 5 \
      https://127.0.0.1:9443/services/Version \
      >/dev/null 2>&1
  then
    printf \
      '[base-verifier-repair] APIM ready on attempt %d.\n' \
      "$attempt"

    ready=true
    break
  fi

  printf \
    '[base-verifier-repair] Attempt %d/120: container=%s, API not ready\n' \
    "$attempt" \
    "${status:-absent}"

  sleep 2
done

if [[ "$ready" != "true" ]]; then
  docker ps -a \
    --filter name=wso2-apim-4-7

  docker logs \
    --tail=200 \
    wso2-apim-4-7 \
    2>/dev/null ||
    true

  fail "APIM did not become ready."
fi

###############################################################################
# Run the repaired verifier. Its one-off bootstrapper cannot start, stop,
# recreate, or restart APIM because --no-deps is now mandatory.
###############################################################################

log "Running repaired base verification."

COMPOSE_IGNORE_ORPHANS=1 \
bash "$VERIFY"

cat <<EOF

[base-verifier-repair] COMPLETE

The base verifier is now read-only with respect to APIM dependencies:

  full running Compose topology
  + APIM readiness check
  + docker compose run --no-deps
  + temporary bootstrapper container only

Backup:
  ${backup_dir}

EOF
