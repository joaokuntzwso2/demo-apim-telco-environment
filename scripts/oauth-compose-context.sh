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
