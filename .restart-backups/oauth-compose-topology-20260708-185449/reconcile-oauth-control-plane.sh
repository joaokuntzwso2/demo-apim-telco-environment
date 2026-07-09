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
  compose=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  compose=(docker-compose)
else
  fail "Docker Compose is unavailable."
fi

PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$ROOT_DIR")}"

compose_command=(
  "${compose[@]}"
  -p "$PROJECT"
)

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

for file in "${compose_files[@]}"; do
  [[ -f "$file" ]] &&
    compose_command+=(-f "$file")
done

"${compose_command[@]}" config --services |
  grep -qx 'apim-bootstrapper' ||
  fail "apim-bootstrapper is absent from the merged Compose topology."

log "Running the dedicated OAuth bootstrap module."

"${compose_command[@]}" run \
  --rm \
  --no-deps \
  --entrypoint /bin/bash \
  apim-bootstrapper \
  -lc '
    set -Eeuo pipefail
    node src/oauth-business-controls-setup.js
  '

log "Reconciling API Product deployment and Developer Portal publication."

"${compose_command[@]}" run \
  --rm \
  --no-deps \
  --entrypoint /bin/bash \
  apim-bootstrapper \
  -lc '
    set -Eeuo pipefail
    node src/developer-experience-setup.js
  '

log "OAuth API, applications, keys, state and API Product reconciled."
