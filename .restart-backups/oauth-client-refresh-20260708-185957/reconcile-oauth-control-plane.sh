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

# ---------------------------------------------------------------------------
# Resolve the authoritative Compose project from the running APIM container.
#
# This avoids guessing:
# - COMPOSE_PROJECT_NAME
# - repository directory name
# - Compose overlay ordering
# - optional local Compose files
# ---------------------------------------------------------------------------

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
  for container_name in \
    wso2-apim-4-7 \
    wso2-apim
  do
    candidate="$(
      docker inspect \
        --format '{{.Id}}' \
        "$container_name" \
        2>/dev/null ||
        true
    )"

    if [[ -n "$candidate" ]]; then
      anchor_id="$candidate"
      break
    fi
  done
fi

[[ -n "$anchor_id" ]] ||
  fail "Could not locate the running WSO2 APIM Compose container."

compose_project="$(
  docker inspect \
    --format '{{ index .Config.Labels "com.docker.compose.project" }}' \
    "$anchor_id" \
    2>/dev/null ||
    true
)"

compose_working_dir="$(
  docker inspect \
    --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' \
    "$anchor_id" \
    2>/dev/null ||
    true
)"

compose_config_files="$(
  docker inspect \
    --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' \
    "$anchor_id" \
    2>/dev/null ||
    true
)"

if [[ -z "$compose_project" || "$compose_project" == "<no value>" ]]; then
  compose_project="${COMPOSE_PROJECT_NAME:-$(basename "$ROOT_DIR")}"
fi

if [[ -z "$compose_working_dir" || "$compose_working_dir" == "<no value>" ]]; then
  compose_working_dir="$ROOT_DIR"
fi

log "Using running Compose project: $compose_project"
log "Compose working directory: $compose_working_dir"

COMPOSE=(
  "${DC[@]}"
  -p "$compose_project"
)

resolved_files=()

resolve_compose_file() {
  local configured_file="$1"
  local resolved=""

  # Remove whitespace that can appear around comma-separated labels.
  configured_file="$(
    printf '%s' "$configured_file" |
      sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
  )"

  [[ -n "$configured_file" ]] || return 0

  if [[ "$configured_file" = /* && -f "$configured_file" ]]; then
    resolved="$configured_file"
  elif [[ -f "${compose_working_dir}/${configured_file}" ]]; then
    resolved="${compose_working_dir}/${configured_file}"
  elif [[ -f "${ROOT_DIR}/${configured_file}" ]]; then
    resolved="${ROOT_DIR}/${configured_file}"
  fi

  if [[ -n "$resolved" ]]; then
    resolved_files+=("$resolved")
  else
    log "Ignoring unavailable Compose file from container label: $configured_file"
  fi
}

if [[ -n "$compose_config_files" &&
      "$compose_config_files" != "<no value>" ]]; then
  IFS=',' read -r -a configured_files <<<"$compose_config_files"

  for configured_file in "${configured_files[@]}"; do
    resolve_compose_file "$configured_file"
  done
fi

# Older Compose versions may not expose project.config_files. The base file is
# sufficient to run apim-bootstrapper because it defines the service, network,
# state volume and APIM connection settings.
if ((${#resolved_files[@]} == 0)); then
  resolved_files=("${ROOT_DIR}/docker-compose.yml")
fi

for compose_file in "${resolved_files[@]}"; do
  COMPOSE+=(-f "$compose_file")
done

service_list="$(
  "${COMPOSE[@]}" config --services 2>/dev/null ||
  true
)"

if ! grep -Fxq 'apim-bootstrapper' <<<"$service_list"; then
  log "Running topology does not expose apim-bootstrapper through its stored file list."
  log "Falling back to the base Compose definition with the same project name."

  COMPOSE=(
    "${DC[@]}"
    -p "$compose_project"
    -f "${ROOT_DIR}/docker-compose.yml"
  )

  service_list="$(
    "${COMPOSE[@]}" config --services 2>/dev/null ||
    true
  )"
fi

if ! grep -Fxq 'apim-bootstrapper' <<<"$service_list"; then
  printf '%s\n' \
    "[oauth-reconcile] Services visible in the resolved topology:" >&2
  printf '%s\n' "$service_list" >&2

  fail "apim-bootstrapper is not defined in docker-compose.yml."
fi

log "Resolved apim-bootstrapper in Compose topology."

run_bootstrap_module() {
  local module="$1"
  local description="$2"

  log "$description"

  "${COMPOSE[@]}" run \
    --rm \
    --no-deps \
    --entrypoint /bin/bash \
    apim-bootstrapper \
    -lc "
      set -Eeuo pipefail

      if [[ ! -f '${module}' ]]; then
        printf '[oauth-reconcile][FAIL] Missing module inside image: %s\n' \
          '${module}' >&2
        exit 1
      fi

      node '${module}'
    "
}

run_bootstrap_module \
  "src/oauth-business-controls-setup.js" \
  "Reconciling OAuth API, personas, applications, subscriptions and credentials."

run_bootstrap_module \
  "src/developer-experience-setup.js" \
  "Reconciling OAuth API Product deployment and Developer Portal publication."

log "OAuth API, applications, credentials and API Product were reconciled."
