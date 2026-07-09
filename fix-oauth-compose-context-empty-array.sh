#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

TARGET="scripts/oauth-compose-context.sh"
INSTALLER="fix-oauth-shared-state-topology.sh"

fail() {
  printf '[oauth-compose-array-fix][FAIL] %s\n' "$*" >&2
  exit 1
}

[[ -f docker-compose.yml ]] ||
  fail "docker-compose.yml is missing."

[[ -f "$TARGET" ]] ||
  fail "$TARGET is missing."

timestamp="$(date +%Y%m%d-%H%M%S)"
backup="${TARGET}.before-bash32-array-fix.${timestamp}"
cp "$TARGET" "$backup"

temporary_file="$(mktemp)"
trap 'rm -f "$temporary_file"' EXIT

cat > "$temporary_file" <<'CONTEXT'
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

bash -n "$temporary_file" ||
  fail "The replacement helper has invalid Bash syntax."

cp "$temporary_file" "$TARGET"
chmod +x "$TARGET"

# Also repair the installer template so rerunning it does not restore the
# defective zero-element-array implementation.
if [[ -f "$INSTALLER" ]]; then
  python3 - \
    "$INSTALLER" \
    "$temporary_file" <<'PY'
from pathlib import Path
import sys

installer_path = Path(sys.argv[1])
helper_path = Path(sys.argv[2])

installer = installer_path.read_text(encoding="utf-8")
helper = helper_path.read_text(encoding="utf-8").rstrip()

start_marker = (
    "cat > scripts/oauth-compose-context.sh <<'CONTEXT'\n"
)
end_marker = "\nCONTEXT\n"

start = installer.find(start_marker)

if start < 0:
    print(
        "[oauth-compose-array-fix] "
        "Installer template does not contain the helper heredoc; skipped."
    )
    raise SystemExit(0)

content_start = start + len(start_marker)
end = installer.find(end_marker, content_start)

if end < 0:
    raise SystemExit(
        "[oauth-compose-array-fix][FAIL] "
        "Could not find the end of the installer helper heredoc."
    )

updated = (
    installer[:content_start]
    + helper
    + installer[end:]
)

installer_path.write_text(updated, encoding="utf-8")

print(
    "[oauth-compose-array-fix] "
    f"Updated installer template: {installer_path}"
)
PY

  bash -n "$INSTALLER" ||
    fail "The installer template became invalid."
fi

echo "[oauth-compose-array-fix] Testing under nounset mode."

bash -u -c '
  set -e

  source "$1"
  resolve_oauth_compose_context "$2"

  printf "[oauth-compose-array-fix] Project: %s\n" \
    "$OAUTH_COMPOSE_PROJECT"

  printf "%s\n" \
    "[oauth-compose-array-fix] Compose files:"

  for file in "${OAUTH_COMPOSE_FILES[@]}"; do
    printf "  %s\n" "$file"
  done

  services="$(
    "${OAUTH_COMPOSE[@]}" config --services
  )"

  grep -Fxq apim-bootstrapper <<<"$services"

  printf "%s\n" \
    "[oauth-compose-array-fix] apim-bootstrapper is present."
' _ "$TARGET" "$ROOT" ||
  {
    cp "$backup" "$TARGET"
    fail "Nounset validation failed; original helper restored."
  }

cat <<EOF

[oauth-compose-array-fix] Fix completed.

Backup:
  ${backup}

Resume with:
  COMPOSE_IGNORE_ORPHANS=1 bash scripts/complete-oauth-post-start.sh

EOF
