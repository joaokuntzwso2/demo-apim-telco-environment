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
