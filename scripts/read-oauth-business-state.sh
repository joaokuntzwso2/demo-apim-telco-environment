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
