#!/usr/bin/env bash
set -Eeuo pipefail

cd "${1:-$PWD}"

SERVER="services/demo-portal/server.js"

fail() {
  printf '[portal-status-repair][FAIL] %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[portal-status-repair] %s\n' "$*"
}

for command in docker python3 curl jq; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Missing required command: $command"
done

[[ -f "$SERVER" ]] ||
  fail "Missing $SERVER"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup=".restart-backups/demo-portal-status-${timestamp}"

mkdir -p "$backup"
cp "$SERVER" "$backup/server.js"

log "Backup written to $backup"

python3 - "$SERVER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

if "/portal-status" in text:
    print(
        "[portal-status-repair] "
        "/portal-status is already present."
    )
    raise SystemExit(0)

port_anchor = (
    "const port = Number("
    "process.env.PORT || 8080"
    ");"
)

if port_anchor not in text:
    raise SystemExit(
        "[portal-status-repair][FAIL] "
        "Could not locate the Express port declaration."
    )

if "require('fs')" not in text and 'require("fs")' not in text:
    text = "const fs = require('fs');\n" + text

route = r'''

const portalStateFile =
  process.env.APIM_PORTAL_STATE_FILE ||
  '/workspace/apim-portal-state/runtime.json';

function normalizedStateKey(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/[^a-z0-9]/g, '');
}

function findStateValue(value, expectedKeys) {
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findStateValue(
        item,
        expectedKeys
      );

      if (found) {
        return found;
      }
    }

    return '';
  }

  if (
    !value ||
    typeof value !== 'object'
  ) {
    return '';
  }

  for (const [key, child] of Object.entries(value)) {
    if (
      expectedKeys.has(
        normalizedStateKey(key)
      ) &&
      typeof child === 'string' &&
      child
    ) {
      return child;
    }
  }

  for (const child of Object.values(value)) {
    const found = findStateValue(
      child,
      expectedKeys
    );

    if (found) {
      return found;
    }
  }

  return '';
}

app.get('/portal-status', (_req, res) => {
  try {
    const raw = fs.readFileSync(
      portalStateFile,
      'utf8'
    );

    const state = JSON.parse(raw);

    const consumerKey = findStateValue(
      state,
      new Set([
        'consumerkey',
        'clientid'
      ])
    );

    const consumerSecret = findStateValue(
      state,
      new Set([
        'consumersecret',
        'clientsecret'
      ])
    );

    const hasConsumerKey =
      Boolean(consumerKey);

    const hasConsumerSecret =
      Boolean(consumerSecret);

    const ready =
      hasConsumerKey &&
      hasConsumerSecret;

    const stateObject =
      state &&
      typeof state === 'object' &&
      !Array.isArray(state)
        ? state
        : { runtimeState: state };

    res
      .status(ready ? 200 : 503)
      .json({
        ...stateObject,
        status:
          ready
            ? 'READY'
            : 'NOT_READY',
        hasConsumerKey,
        hasConsumerSecret
      });

  } catch (error) {
    res
      .status(503)
      .json({
        status: 'NOT_READY',
        hasConsumerKey: false,
        hasConsumerSecret: false,
        stateFile: portalStateFile,
        error: error.message
      });
  }
});
'''

text = text.replace(
    port_anchor,
    port_anchor + route,
    1,
)

path.write_text(
    text,
    encoding="utf-8",
)

print(
    "[portal-status-repair] "
    "Added /portal-status."
)
PY

###############################################################################
# Validate JavaScript before rebuilding.
###############################################################################

if command -v node >/dev/null 2>&1; then
  node --check "$SERVER"
fi

grep -Fq \
  "app.get('/portal-status'" \
  "$SERVER" ||
  fail "/portal-status was not installed."

###############################################################################
# Use the same Compose project as the running APIM container.
###############################################################################

project="$(
  docker inspect wso2-apim-4-7 \
    --format \
    '{{ index .Config.Labels "com.docker.compose.project" }}' \
    2>/dev/null ||
    true
)"

[[ -n "$project" ]] ||
  fail "Could not resolve the running Compose project."

if docker compose version >/dev/null 2>&1; then
  compose=(
    docker compose
    -p "$project"
    -f docker-compose.yml
  )
elif docker-compose version >/dev/null 2>&1; then
  compose=(
    docker-compose
    -p "$project"
    -f docker-compose.yml
  )
else
  fail "Docker Compose is unavailable."
fi

log "Compose project: $project"
log "Building only demo-portal."

"${compose[@]}" build demo-portal

log "Recreating only demo-portal."

"${compose[@]}" up -d \
  --no-deps \
  --force-recreate \
  demo-portal

###############################################################################
# Diagnose with actual HTTP status codes instead of suppressing 404 errors.
###############################################################################

body_file="$(
  mktemp \
    "${TMPDIR:-/tmp}/portal-status.XXXXXX"
)"

trap 'rm -f "$body_file"' EXIT

for attempt in $(seq 1 30); do
  code="$(
    curl -sS \
      --connect-timeout 2 \
      --max-time 5 \
      -o "$body_file" \
      -w '%{http_code}' \
      http://localhost:8080/portal-status \
      2>/dev/null ||
      printf '000'
  )"

  printf \
    '[portal-status-repair] Attempt %d/30: HTTP %s\n' \
    "$attempt" \
    "$code"

  if [[ "$code" == "200" ]] &&
     jq -e \
       '.status == "READY"' \
       "$body_file" \
       >/dev/null 2>&1
  then
    jq . "$body_file"

    log "Portal status is READY."
    break
  fi

  if [[ -s "$body_file" ]]; then
    cat "$body_file"
    echo
  fi

  if [[ "$attempt" == "30" ]]; then
    echo
    "${compose[@]}" ps -a demo-portal || true
    echo
    "${compose[@]}" logs \
      --tail=200 \
      demo-portal || true

    fail "demo-portal did not become READY."
  fi

  sleep 2
done

log "Checking portal root and runtime configuration."

curl -fsS \
  http://localhost:8080/ \
  >/dev/null

curl -fsS \
  http://localhost:8080/config.js

echo

log "Running the base APIM verifier."

bash scripts/verify-apim-bootstrap.sh

cat <<EOF

[portal-status-repair] COMPLETE

Portal:
  http://localhost:8080

Status:
  http://localhost:8080/portal-status

Backup:
  ${backup}

EOF
