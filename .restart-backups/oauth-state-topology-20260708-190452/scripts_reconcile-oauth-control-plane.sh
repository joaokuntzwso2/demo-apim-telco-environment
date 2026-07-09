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
      backup_file="${history_dir}/oauth-business-controls.$(date +%Y%m%d-%H%M%S).json"

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
