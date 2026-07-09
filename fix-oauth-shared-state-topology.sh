#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

log() {
  printf '[oauth-state-topology-fix] %s\n' "$*"
}

fail() {
  printf '[oauth-state-topology-fix][FAIL] %s\n' "$*" >&2
  exit 1
}

for command in bash docker jq python3; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Required command is missing: $command"
done

required_files=(
  docker-compose.yml
  scripts/complete-oauth-post-start.sh
  scripts/verify-oauth-consent-risk-controls.sh
  services/apim-bootstrapper/src/oauth-business-controls-setup.js
)

for file in "${required_files[@]}"; do
  [[ -f "$file" ]] || fail "Required file is missing: $file"
done

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/oauth-state-topology-${timestamp}"
mkdir -p "$backup_dir"

for file in \
  scripts/reconcile-oauth-control-plane.sh \
  scripts/verify-oauth-consent-risk-controls.sh
do
  if [[ -f "$file" ]]; then
    cp "$file" \
      "$backup_dir/$(printf '%s' "$file" | tr '/' '_')"
  fi
done

log "Backups written under $backup_dir"

cat > scripts/oauth-compose-context.sh <<'CONTEXT'
#!/usr/bin/env bash

resolve_oauth_compose_context() {
  local root_dir="$1"
  local anchor_id=""
  local compose_project=""
  local compose_working_dir=""
  local compose_config_files=""
  local configured_file=""
  local resolved_file=""
  local current=""
  local resolved_from_labels="false"

  local -a configured_files
  local -a fallback_files

  if docker compose version >/dev/null 2>&1; then
    OAUTH_DC=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    OAUTH_DC=(docker-compose)
  else
    printf '%s\n' \
      '[oauth-compose-context][FAIL] Docker Compose is unavailable.' \
      >&2
    return 1
  fi

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

  if [[ -z "$anchor_id" ]]; then
    printf '%s\n' \
      '[oauth-compose-context][FAIL] Could not locate the APIM container.' \
      >&2
    return 1
  fi

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

  if [[ -z "$compose_project" ||
        "$compose_project" == "<no value>" ]]; then
    compose_project="$(
      basename "$root_dir"
    )"
  fi

  if [[ -z "$compose_working_dir" ||
        "$compose_working_dir" == "<no value>" ]]; then
    compose_working_dir="$root_dir"
  fi

  OAUTH_COMPOSE_PROJECT="$compose_project"

  #
  # Bash 3.2 with `set -u` considers a zero-element array unset.
  # Seed the array with the required base Compose file so every later array
  # expansion is safe.
  #
  OAUTH_COMPOSE_FILES=(
    "${root_dir}/docker-compose.yml"
  )

  add_compose_file() {
    local candidate="$1"
    local existing_file=""

    [[ -n "$candidate" && -f "$candidate" ]] ||
      return 0

    for existing_file in "${OAUTH_COMPOSE_FILES[@]}"; do
      if [[ "$existing_file" == "$candidate" ]]; then
        return 0
      fi
    done

    OAUTH_COMPOSE_FILES+=("$candidate")
  }

  if [[ -n "$compose_config_files" &&
        "$compose_config_files" != "<no value>" ]]; then
    IFS=',' read -r -a configured_files \
      <<<"$compose_config_files"

    for configured_file in "${configured_files[@]}"; do
      configured_file="$(
        printf '%s' "$configured_file" |
          sed -E '
            s/^[[:space:]]+//
            s/[[:space:]]+$//
          '
      )"

      [[ -n "$configured_file" ]] ||
        continue

      resolved_file=""

      if [[ "$configured_file" = /* &&
            -f "$configured_file" ]]; then
        resolved_file="$configured_file"
      elif [[ -f "${compose_working_dir}/${configured_file}" ]]; then
        resolved_file="${compose_working_dir}/${configured_file}"
      elif [[ -f "${root_dir}/${configured_file}" ]]; then
        resolved_file="${root_dir}/${configured_file}"
      elif [[ -f "${root_dir}/$(basename "$configured_file")" ]]; then
        resolved_file="${root_dir}/$(basename "$configured_file")"
      fi

      if [[ -n "$resolved_file" ]]; then
        add_compose_file "$resolved_file"
        resolved_from_labels="true"
      fi
    done
  fi

  if [[ "$resolved_from_labels" != "true" ]]; then
    fallback_files=(
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

    for configured_file in "${fallback_files[@]}"; do
      add_compose_file "${root_dir}/${configured_file}"
    done
  fi

  # This overlay contains the OAuth-specific bootstrap and MI configuration.
  # add_compose_file is idempotent, so it will not duplicate the entry.
  add_compose_file \
    "${root_dir}/docker-compose.oauth-business-controls.yml"

  OAUTH_COMPOSE=(
    "${OAUTH_DC[@]}"
    -p "$OAUTH_COMPOSE_PROJECT"
  )

  for configured_file in "${OAUTH_COMPOSE_FILES[@]}"; do
    OAUTH_COMPOSE+=(
      -f
      "$configured_file"
    )
  done

  export COMPOSE_IGNORE_ORPHANS=1
}
CONTEXT

cat > scripts/read-oauth-business-state.sh <<'READ_STATE'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"
cd "$ROOT_DIR"

source scripts/oauth-compose-context.sh
resolve_oauth_compose_context "$ROOT_DIR"

services="$("${OAUTH_COMPOSE[@]}" config --services)"

grep -Fxq 'apim-bootstrapper' <<<"$services" || {
  echo "[oauth-state-reader][FAIL] apim-bootstrapper is absent." >&2
  exit 1
}

"${OAUTH_COMPOSE[@]}" run \
  --rm \
  --no-deps \
  -T \
  --entrypoint /bin/sh \
  apim-bootstrapper \
  -lc '
    set -eu

    for candidate in \
      "${OAUTH_BUSINESS_CONTROLS_STATE_FILE:-}" \
      "${OAUTH_BUSINESS_CONTROL_STATE_FILE:-}" \
      "${OAUTH_STATE_FILE:-}" \
      "/workspace/state/oauth-business-controls.json"
    do
      if [ -n "${candidate}" ] && [ -s "${candidate}" ]; then
        cat "${candidate}"
        exit 0
      fi
    done

    candidate="$(
      find /workspace/state \
        -maxdepth 3 \
        -type f \
        -name "oauth-business-controls.json" \
        2>/dev/null |
        head -n 1
    )"

    if [ -n "${candidate}" ] && [ -s "${candidate}" ]; then
      cat "${candidate}"
      exit 0
    fi

    echo "[oauth-state-reader][FAIL] OAuth state was not found." >&2
    exit 1
  '
READ_STATE

cat > scripts/reconcile-oauth-control-plane.sh <<'RECONCILE'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"
cd "$ROOT_DIR"

source scripts/oauth-compose-context.sh
resolve_oauth_compose_context "$ROOT_DIR"

log() {
  printf '[oauth-reconcile] %s\n' "$*"
}

fail() {
  printf '[oauth-reconcile][FAIL] %s\n' "$*" >&2
  exit 1
}

log "Using Compose project: $OAUTH_COMPOSE_PROJECT"
log "Using the running stack's complete Compose topology."

for file in "${OAUTH_COMPOSE_FILES[@]}"; do
  log "Compose file: $file"
done

services="$("${OAUTH_COMPOSE[@]}" config --services)"

grep -Fxq 'apim-bootstrapper' <<<"$services" ||
  fail "apim-bootstrapper is absent from the resolved topology."

log "Effective bootstrapper volumes and environment:"

"${OAUTH_COMPOSE[@]}" config --format json |
  jq '{
    environment: .services["apim-bootstrapper"].environment,
    volumes: .services["apim-bootstrapper"].volumes
  }'

log "Rebuilding apim-bootstrapper with the current OAuth source."
"${OAUTH_COMPOSE[@]}" build apim-bootstrapper

log "Archiving stale state and regenerating OAuth applications and keys."

"${OAUTH_COMPOSE[@]}" run \
  --rm \
  --no-deps \
  -T \
  --entrypoint /bin/bash \
  apim-bootstrapper \
  -lc '
    set -Eeuo pipefail

    state_dir="/workspace/state"
    canonical_state="${state_dir}/oauth-business-controls.json"
    history_dir="${state_dir}/oauth-history"
    stamp="$(date +%Y%m%d-%H%M%S)"

    mkdir -p "${history_dir}"

    while IFS= read -r old_state; do
      [[ -n "${old_state}" ]] || continue

      backup_name="$(
        basename "${old_state}"
      ).${stamp}.json"

      cp "${old_state}" "${history_dir}/${backup_name}"

      echo \
        "[oauth-reconcile] Archived ${old_state} as " \
        "${history_dir}/${backup_name}"
    done < <(
      find "${state_dir}" \
        -maxdepth 3 \
        -type f \
        -name "oauth-business-controls.json" \
        2>/dev/null ||
        true
    )

    find "${state_dir}" \
      -maxdepth 3 \
      -type f \
      -name "oauth-business-controls.json" \
      -delete \
      2>/dev/null ||
      true

    node src/oauth-business-controls-setup.js

    generated_state="$(
      find "${state_dir}" \
        -maxdepth 3 \
        -type f \
        -name "oauth-business-controls.json" \
        2>/dev/null |
        head -n 1
    )"

    [[ -n "${generated_state}" && -s "${generated_state}" ]] || {
      echo \
        "[oauth-reconcile][FAIL] OAuth bootstrap did not generate state." \
        >&2
      exit 1
    }

    if [[ "${generated_state}" != "${canonical_state}" ]]; then
      cp "${generated_state}" "${canonical_state}"
    fi

    node - "${canonical_state}" <<"NODE"
const fs = require("fs");

const file = process.argv[2];
const state = JSON.parse(fs.readFileSync(file, "utf8"));
const serialized = JSON.stringify(state);

for (const expected of [
  "partner.alpha",
  "partner.beta",
  "telco.operations",
  "telco.product",
  "telco.admin"
]) {
  if (!serialized.includes(expected)) {
    console.error(
      `[oauth-reconcile][FAIL] Generated state lacks ${expected}`
    );
    process.exit(1);
  }
}

console.log(
  `[oauth-reconcile] Generated fresh OAuth state: ${file}`
);
NODE
  '

log "Reconciling API Product publication."

"${OAUTH_COMPOSE[@]}" run \
  --rm \
  --no-deps \
  -T \
  --entrypoint /bin/bash \
  apim-bootstrapper \
  -lc '
    set -Eeuo pipefail
    node src/developer-experience-setup.js
  '

mkdir -p .runtime

bash scripts/read-oauth-business-state.sh \
  > .runtime/oauth-business-controls.json

chmod 600 .runtime/oauth-business-controls.json

jq -e 'type == "object"' \
  .runtime/oauth-business-controls.json \
  >/dev/null ||
  fail "Exported OAuth state is not valid JSON."

if grep -q \
  'e58c71d1-e78b-4e3d-a31b-769dbfae8bd6' \
  .runtime/oauth-business-controls.json
then
  fail "Regenerated state still contains the deleted short-lived application ID."
fi

log "Fresh OAuth state exported to .runtime/oauth-business-controls.json"
log "OAuth applications, keys, subscriptions and Product were reconciled."
RECONCILE

python3 - scripts/verify-oauth-consent-risk-controls.sh <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

marker = (
    'echo "[oauth-controls-verify] Reading bootstrap state."'
)

start = text.find(marker)

if start < 0:
    raise SystemExit(
        "[oauth-state-topology-fix][FAIL] "
        "Could not locate the state-reading section."
    )

remaining = text[start:]

end_match = re.search(
    r'^[ \t]*pass\s+["\']Bootstrap state exists\.["\'][ \t]*$',
    remaining,
    re.MULTILINE,
)

if end_match is None:
    raise SystemExit(
        "[oauth-state-topology-fix][FAIL] "
        "Could not locate the end of the state-reading section."
    )

end = start + end_match.end()

replacement = r'''echo "[oauth-controls-verify] Reading bootstrap state from the running Compose project's OAuth volume."

oauth_state_json="$(
  bash scripts/read-oauth-business-state.sh
)" || {
  echo "[oauth-controls-verify][FAIL] Could not read current OAuth bootstrap state." >&2
  exit 1
}

if ! jq -e 'type == "object"' <<<"${oauth_state_json}" >/dev/null 2>&1; then
  echo "[oauth-controls-verify][FAIL] Current OAuth bootstrap state is invalid JSON." >&2
  exit 1
fi

# Preserve the variable names used by previous verifier revisions.
state="${oauth_state_json}"
state_json="${oauth_state_json}"
bootstrap_state="${oauth_state_json}"
oauth_state="${oauth_state_json}"

pass "Bootstrap state exists."'''

updated = text[:start] + replacement + text[end:]

path.write_text(updated, encoding="utf-8")

print(
    "[oauth-state-topology-fix] "
    "Verifier now reads state from the running Compose project."
)
PY

chmod +x \
  scripts/oauth-compose-context.sh \
  scripts/read-oauth-business-state.sh \
  scripts/reconcile-oauth-control-plane.sh \
  scripts/verify-oauth-consent-risk-controls.sh

log "Validating Bash syntax"

bash -n scripts/oauth-compose-context.sh
bash -n scripts/read-oauth-business-state.sh
bash -n scripts/reconcile-oauth-control-plane.sh
bash -n scripts/verify-oauth-consent-risk-controls.sh

log "Patch installed successfully"

cat <<EOF

Run the corrected reconciliation and verification with:

  COMPOSE_IGNORE_ORPHANS=1 bash scripts/complete-oauth-post-start.sh

Backups:

  ${backup_dir}

EOF
