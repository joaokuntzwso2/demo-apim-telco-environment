#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="${1:-$PWD}"
cd "$ROOT_DIR"

RECONCILE="scripts/reconcile-oauth-control-plane.sh"
HELPER="scripts/complete-oauth-post-start.sh"

log() {
  printf '[oauth-client-refresh-fix] %s\n' "$*"
}

fail() {
  printf '[oauth-client-refresh-fix][FAIL] %s\n' "$*" >&2
  exit 1
}

for command in docker bash grep; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Required command is missing: $command"
done

[[ -f docker-compose.yml ]] ||
  fail "docker-compose.yml is missing."

[[ -f "$HELPER" ]] ||
  fail "$HELPER is missing."

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/oauth-client-refresh-${timestamp}"
mkdir -p "$backup_dir"

[[ -f "$RECONCILE" ]] &&
  cp "$RECONCILE" "$backup_dir/reconcile-oauth-control-plane.sh"

cp "$HELPER" "$backup_dir/complete-oauth-post-start.sh"

log "Backups written under $backup_dir"

cat > "$RECONCILE" <<'RECONCILE_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"
cd "$ROOT_DIR"

log() {
  printf '[oauth-reconcile] %s\n' "$*"
}

fail() {
  printf '[oauth-reconcile][FAIL] %s\n' "$*" >&2
  exit 1
}

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose)
else
  fail "Docker Compose is unavailable."
fi

# Resolve the exact Compose project from the currently running APIM container.
anchor_id="$(
  docker ps -q \
    --filter 'label=com.docker.compose.service=wso2-apim' |
    head -n 1
)"

if [[ -z "$anchor_id" ]]; then
  anchor_id="$(
    docker ps -aq \
      --filter 'label=com.docker.compose.service=wso2-apim' |
      head -n 1
  )"
fi

if [[ -z "$anchor_id" ]]; then
  anchor_id="$(
    docker inspect \
      --format '{{.Id}}' \
      wso2-apim-4-7 \
      2>/dev/null ||
      true
  )"
fi

[[ -n "$anchor_id" ]] ||
  fail "Could not locate the WSO2 APIM container."

compose_project="$(
  docker inspect \
    --format '{{ index .Config.Labels "com.docker.compose.project" }}' \
    "$anchor_id" \
    2>/dev/null ||
    true
)"

if [[ -z "$compose_project" ||
      "$compose_project" == "<no value>" ]]; then
  compose_project="${COMPOSE_PROJECT_NAME:-$(basename "$ROOT_DIR")}"
fi

COMPOSE=(
  "${DC[@]}"
  -p "$compose_project"
  -f "${ROOT_DIR}/docker-compose.yml"
)

log "Using Compose project: $compose_project"

services="$(
  "${COMPOSE[@]}" config --services
)"

grep -Fxq 'apim-bootstrapper' <<<"$services" ||
  fail "apim-bootstrapper is absent from docker-compose.yml."

log "Refreshing the OAuth demo application state and key mappings."

"${COMPOSE[@]}" run \
  --rm \
  --no-deps \
  --entrypoint /bin/bash \
  apim-bootstrapper \
  -lc '
    set -Eeuo pipefail

    state_file="/workspace/state/oauth-business-controls.json"
    history_dir="/workspace/state/oauth-history"

    mkdir -p "${history_dir}"

    if [[ -f "${state_file}" ]]; then
      backup_file="${
        history_dir
      }/oauth-business-controls.$(date +%Y%m%d-%H%M%S).json"

      cp "${state_file}" "${backup_file}"

      echo \
        "[oauth-reconcile] Archived stale OAuth state as ${backup_file}"
    fi

    #
    # The OAuth setup creates/reconciles the demo applications and writes a
    # new state file containing the current application IDs and key mappings.
    # Removing the stale state prevents obsolete application UUIDs and secrets
    # from being reused after APIM has recreated or removed those objects.
    #
    rm -f "${state_file}"

    node src/oauth-business-controls-setup.js

    [[ -s "${state_file}" ]] || {
      echo \
        "[oauth-reconcile][FAIL] OAuth setup did not create ${state_file}" \
        >&2
      exit 1
    }

    node - "${state_file}" <<"NODE"
const fs = require("fs");

const file = process.argv[2];
const text = fs.readFileSync(file, "utf8");

let state;

try {
  state = JSON.parse(text);
} catch (error) {
  console.error(
    `[oauth-reconcile][FAIL] Invalid OAuth state JSON: ${error.message}`
  );
  process.exit(1);
}

const serialized = JSON.stringify(state);

const expectedEvidence = [
  "partner.alpha",
  "partner.beta",
  "telco.operations",
  "telco.product",
  "telco.admin"
];

for (const value of expectedEvidence) {
  if (!serialized.includes(value)) {
    console.error(
      `[oauth-reconcile][FAIL] New OAuth state does not contain ${value}`
    );
    process.exit(1);
  }
}

console.log(
  `[oauth-reconcile] Fresh OAuth state validated: ${file}`
);
NODE
  '

log "Reconciling API Product publication after refreshing applications."

"${COMPOSE[@]}" run \
  --rm \
  --no-deps \
  --entrypoint /bin/bash \
  apim-bootstrapper \
  -lc '
    set -Eeuo pipefail
    node src/developer-experience-setup.js
  '

log "OAuth demo applications, keys, subscriptions and state were refreshed."
RECONCILE_SCRIPT

chmod +x "$RECONCILE"

# Ensure the normal restart helper invokes reconciliation before verification.
if ! grep -q \
  'bash scripts/reconcile-oauth-control-plane.sh' \
  "$HELPER"
then
  python3 - "$HELPER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

anchor = (
    'if [[ "${SKIP_OAUTH_CATALOG_REGISTRATION:-false}" != "true" ]]; then'
)

index = text.find(anchor)

if index < 0:
    raise SystemExit(
        "[oauth-client-refresh-fix][FAIL] "
        "Could not locate catalog registration in complete-oauth-post-start.sh."
    )

block = r'''
if [[ "${SKIP_OAUTH_RECONCILE:-false}" != "true" ]]; then
  run_with_retries \
    "Refreshing OAuth demo applications, credentials and subscriptions" \
    "${OAUTH_RECONCILE_ATTEMPTS:-2}" \
    "${OAUTH_RECONCILE_RETRY_DELAY_SECONDS:-10}" \
    bash scripts/reconcile-oauth-control-plane.sh
else
  log "OAuth application reconciliation was skipped"
fi

'''

text = text[:index] + block + text[index:]
path.write_text(text, encoding="utf-8")
PY
fi

chmod +x "$HELPER"

bash -n "$RECONCILE"
bash -n "$HELPER"

grep -q \
  'rm -f "${state_file}"' \
  "$RECONCILE" ||
  fail "Stale OAuth state removal was not installed."

grep -q \
  'oauth-business-controls-setup.js' \
  "$RECONCILE" ||
  fail "OAuth bootstrap execution was not installed."

grep -q \
  'reconcile-oauth-control-plane.sh' \
  "$HELPER" ||
  fail "The normal post-start helper does not call reconciliation."

# Resolve the running project for the one-time rebuild.
anchor_id="$(
  docker ps -q \
    --filter 'label=com.docker.compose.service=wso2-apim' |
    head -n 1
)"

compose_project="$(
  docker inspect \
    --format '{{ index .Config.Labels "com.docker.compose.project" }}' \
    "$anchor_id" \
    2>/dev/null ||
    true
)"

if [[ -z "$compose_project" ||
      "$compose_project" == "<no value>" ]]; then
  compose_project="${COMPOSE_PROJECT_NAME:-$(basename "$ROOT_DIR")}"
fi

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
else
  DC=(docker-compose)
fi

COMPOSE=(
  "${DC[@]}"
  -p "$compose_project"
  -f "${ROOT_DIR}/docker-compose.yml"
)

log "Rebuilding apim-bootstrapper so it contains the latest local OAuth code."
"${COMPOSE[@]}" build apim-bootstrapper

log "Refreshing OAuth applications and running complete verification."
bash scripts/complete-oauth-post-start.sh

cat <<EOF

[oauth-client-refresh-fix] OAuth client repair completed.

The normal restart path now refreshes the demo OAuth application IDs, key
mappings, consumer credentials and subscriptions before verification.

Normal restart:

  bash scripts/telco-demo-control.sh restart

Previous state backups are retained inside the shared volume under:

  /workspace/state/oauth-history

Installer backups:

  ${backup_dir}

EOF
