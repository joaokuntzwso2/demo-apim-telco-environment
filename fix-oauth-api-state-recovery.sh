#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

RECONCILE="scripts/reconcile-oauth-control-plane.sh"
SEED_JS="services/apim-bootstrapper/src/seed-oauth-api-state.js"

fail() {
  printf '[oauth-state-recovery][FAIL] %s\n' "$*" >&2
  exit 1
}

[[ -f "$RECONCILE" ]] ||
  fail "Missing $RECONCILE"

[[ -d services/apim-bootstrapper/src ]] ||
  fail "Missing services/apim-bootstrapper/src"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup="${RECONCILE}.before-api-state-recovery.${timestamp}"
cp "$RECONCILE" "$backup"

cat > "$SEED_JS" <<'NODE'
const fs = require("fs");
const path = require("path");

const stateFile =
  process.env.OAUTH_BUSINESS_CONTROLS_STATE_FILE ||
  "/workspace/state/oauth-business-controls.json";

const historyDir =
  path.join(path.dirname(stateFile), "oauth-history");

const apiName = "SubscriberAuthorizationControlAPI";
const apiVersion = "1.0.0";
const apiContext = "/subscriber-authorization/v1";

function log(message) {
  console.log(`[oauth-state-seed] ${message}`);
}

function fail(message) {
  console.error(`[oauth-state-seed][FAIL] ${message}`);
  process.exit(1);
}

function readJson(filename) {
  try {
    return JSON.parse(fs.readFileSync(filename, "utf8"));
  } catch {
    return null;
  }
}

function findApiObject(value, visited = new Set()) {
  if (!value || typeof value !== "object") {
    return null;
  }

  if (visited.has(value)) {
    return null;
  }

  visited.add(value);

  if (
    typeof value.id === "string" &&
    value.id.length > 0 &&
    value.name === apiName &&
    String(value.version || "") === apiVersion
  ) {
    return value;
  }

  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findApiObject(item, visited);

      if (found) {
        return found;
      }
    }

    return null;
  }

  for (const child of Object.values(value)) {
    const found = findApiObject(child, visited);

    if (found) {
      return found;
    }
  }

  return null;
}

function extractApiIdentity(state) {
  if (!state || typeof state !== "object") {
    return null;
  }

  const directApi =
    state.api &&
    typeof state.api === "object" &&
    state.api.id
      ? state.api
      : null;

  const recursiveApi =
    directApi || findApiObject(state);

  const apiId =
    recursiveApi?.id ||
    state.apiId ||
    state.managedApiId ||
    null;

  if (!apiId) {
    return null;
  }

  return {
    ...(recursiveApi || {}),
    id: apiId,
    name: apiName,
    version: apiVersion,
    context:
      recursiveApi?.context ||
      state.apiContext ||
      apiContext
  };
}

function listHistoryFiles() {
  if (!fs.existsSync(historyDir)) {
    return [];
  }

  return fs
    .readdirSync(historyDir)
    .map(name => path.join(historyDir, name))
    .filter(filename => {
      try {
        return fs.statSync(filename).isFile();
      } catch {
        return false;
      }
    })
    .sort((left, right) => {
      return (
        fs.statSync(right).mtimeMs -
        fs.statSync(left).mtimeMs
      );
    });
}

fs.mkdirSync(path.dirname(stateFile), {
  recursive: true
});

const currentState = readJson(stateFile);
const currentApi = extractApiIdentity(currentState);

if (currentApi) {
  log(
    `Keeping current API identity ${currentApi.id} ` +
    `from ${stateFile}`
  );

  process.exit(0);
}

for (const historyFile of listHistoryFiles()) {
  const historicalState = readJson(historyFile);
  const historicalApi = extractApiIdentity(historicalState);

  if (!historicalApi) {
    continue;
  }

  /*
   * Keep only the stable API identity. Application IDs, client secrets,
   * subscriptions and key mappings are deliberately omitted so the OAuth
   * bootstrap can regenerate them against the current APIM database.
   */
  const seedState = {
    api: historicalApi,
    apiId: historicalApi.id,
    recoveredFrom: historyFile,
    recoveredAt: new Date().toISOString()
  };

  fs.writeFileSync(
    stateFile,
    `${JSON.stringify(seedState, null, 2)}\n`,
    {
      mode: 0o600
    }
  );

  log(
    `Recovered API identity ${historicalApi.id} ` +
    `from ${historyFile}`
  );

  log(
    "Application IDs and credentials were intentionally removed " +
    "from the seed state."
  );

  process.exit(0);
}

fail(
  `No stored identity for ${apiName}:${apiVersion} ` +
  `was found in ${stateFile} or ${historyDir}`
);
NODE

python3 - "$RECONCILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

old_log = (
    'log "Archiving stale state and regenerating OAuth applications and keys."'
)

new_log = (
    'log "Archiving OAuth state while preserving the managed API identity."'
)

text = text.replace(old_log, new_log)

start_marker = '''    find "${state_dir}" \\
      -maxdepth 3 \\
      -type f \\
      -name "oauth-business-controls.json" \\
      -delete \\
      2>/dev/null ||
      true

    node src/oauth-business-controls-setup.js'''

replacement = '''    #
    # Never delete the only stored API UUID. When the canonical state is
    # absent, recover only the API identity from the newest history file.
    # OAuth applications, subscriptions and client credentials are then
    # regenerated by the normal setup module.
    #
    node src/seed-oauth-api-state.js

    [[ -s "${canonical_state}" ]] || {
      echo \
        "[oauth-reconcile][FAIL] API identity seed was not created." \
        >&2
      exit 1
    }

    node src/oauth-business-controls-setup.js'''

if start_marker in text:
    text = text.replace(
        start_marker,
        replacement,
        1,
    )
elif "node src/seed-oauth-api-state.js" in text:
    print(
        "[oauth-state-recovery] "
        "Reconciliation script is already patched."
    )
else:
    print(
        "[oauth-state-recovery][FAIL] "
        "Could not locate the destructive state-deletion block.",
        file=sys.stderr,
    )

    for number, line in enumerate(
        text.splitlines(),
        start=1,
    ):
        if (
            "oauth-business-controls.json" in line
            or "find " in line
            or "-delete" in line
            or "oauth-business-controls-setup.js" in line
        ):
            print(f"{number}: {line}", file=sys.stderr)

    raise SystemExit(1)

path.write_text(text, encoding="utf-8")

print(
    "[oauth-state-recovery] "
    "Removed destructive OAuth-state deletion."
)
PY

chmod +x "$RECONCILE"

bash -n "$RECONCILE"

grep -q \
  'node src/seed-oauth-api-state.js' \
  "$RECONCILE" ||
  fail "API identity recovery was not installed."

if grep -A 8 -B 8 \
  'node src/oauth-business-controls-setup.js' \
  "$RECONCILE" |
  grep -q -- '-delete'
then
  cp "$backup" "$RECONCILE"
  fail "A destructive deletion remains near the OAuth bootstrap."
fi

echo
echo "[oauth-state-recovery] Fix installed."
echo "[oauth-state-recovery] Backup:"
echo "  $backup"
echo
echo "Resume with:"
echo "  COMPOSE_IGNORE_ORPHANS=1 OAUTH_RECONCILE_ATTEMPTS=1 OAUTH_VERIFY_ATTEMPTS=1 bash scripts/complete-oauth-post-start.sh"
