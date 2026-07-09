#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

TARGET="services/apim-bootstrapper/src/bootstrap.js"

log() {
  printf '[devportal-bootstrap-fix] %s\n' "$*"
}

fail() {
  printf '[devportal-bootstrap-fix][FAIL] %s\n' "$*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 ||
  fail "python3 is required."

[[ -f "$TARGET" ]] ||
  fail "Missing $TARGET"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/devportal-bootstrap-${timestamp}"
backup="${backup_dir}/bootstrap.js"

mkdir -p "$backup_dir"
cp "$TARGET" "$backup"

log "Backup written to $backup"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")


def replace_region(
    source: str,
    start_marker: str,
    end_marker: str,
    replacement: str,
) -> str:
    start = source.find(start_marker)

    if start < 0:
        raise SystemExit(
            "[devportal-bootstrap-fix][FAIL] "
            f"Could not locate: {start_marker}"
        )

    end = source.find(end_marker, start)

    if end < 0:
        raise SystemExit(
            "[devportal-bootstrap-fix][FAIL] "
            f"Could not locate region end: {end_marker}"
        )

    return (
        source[:start]
        + replacement.rstrip()
        + "\n\n"
        + source[end:]
    )


# ---------------------------------------------------------------------------
# Fix the recursively broken lifecycle helper.
# ---------------------------------------------------------------------------

safe_publish = r'''
async function safePublishLifecycleChange(
  apimUrl,
  token,
  apiId,
  logger = log
) {
  try {
    await publisherRestRequest(
      'POST',
      `${apimUrl}/api/am/publisher/v4/apis/change-lifecycle` +
        `?apiId=${encodeURIComponent(apiId)}` +
        `&action=${encodeURIComponent('Publish')}`,
      token,
      null,
      [200, 201, 202]
    );

    return {
      published: true,
      skipped: false
    };
  } catch (error) {
    if (isAlreadyPublishedLifecycleError(error)) {
      logger(
        `Publish lifecycle action is not available for API ${apiId}; ` +
        `the API is already published.`
      );

      return {
        published: false,
        skipped: true,
        reason: 'PUBLISH_ACTION_NOT_AVAILABLE'
      };
    }

    throw error;
  }
}
'''

text = replace_region(
    text,
    "async function safePublishLifecycleChange(",
    "async function publisherRestRequest(",
    safe_publish,
)


# ---------------------------------------------------------------------------
# Replace the Publisher publication function with an idempotent implementation.
#
# It now:
# - checks the full Publisher API object, not only the search summary;
# - repairs public visibility and subscription availability;
# - ensures at least one subscription policy;
# - validates the final lifecycle state;
# - provides a controlled lifecycle re-index operation for an API that remains
#   missing from the Developer Portal.
# ---------------------------------------------------------------------------

publisher_publish = r'''
// BEGIN DEVPORTAL SELF-HEAL PATCH

function normalizeApiForDevportal(apiObject) {
  const currentPolicies = Array.isArray(apiObject.policies)
    ? apiObject.policies.filter(Boolean)
    : [];

  apiObject.visibility = 'PUBLIC';
  apiObject.visibleRoles = [];
  apiObject.visibleTenants = [];
  apiObject.visibleOrganizations = [];

  apiObject.subscriptionAvailability = 'CURRENT_TENANT';
  apiObject.subscriptionAvailableTenants = [];

  apiObject.policies = Array.from(
    new Set([...currentPolicies, 'Unlimited'])
  );

  apiObject.apiThrottlingPolicy =
    apiObject.apiThrottlingPolicy || 'Unlimited';

  if (
    !Array.isArray(apiObject.transport) ||
    apiObject.transport.length === 0
  ) {
    apiObject.transport = ['https'];
  }

  if (
    apiObject.advertiseInfo &&
    typeof apiObject.advertiseInfo === 'object'
  ) {
    apiObject.advertiseInfo.advertised = false;
  }

  /*
   * The Publisher PUT representation uses additionalProperties. The generated
   * additionalPropertiesMap can contain a response-only or incompatible
   * representation, so keep the same sanitation already used elsewhere in
   * this bootstrap.
   */
  delete apiObject.additionalPropertiesMap;

  return apiObject;
}


async function ensurePublisherDevportalConfiguration(
  api,
  publisherApi,
  token
) {
  const fullApi = await publisherRestRequest(
    'GET',
    `${APIM_URL}/api/am/publisher/v4/apis/${publisherApi.id}`,
    token
  );

  normalizeApiForDevportal(fullApi);

  await publisherRestRequest(
    'PUT',
    `${APIM_URL}/api/am/publisher/v4/apis/${publisherApi.id}`,
    token,
    fullApi,
    [200, 201, 202]
  );

  const verified = await publisherRestRequest(
    'GET',
    `${APIM_URL}/api/am/publisher/v4/apis/${publisherApi.id}`,
    token
  );

  log(
    `DevPortal state normalized for ${api.name}: ` +
    JSON.stringify({
      id: publisherApi.id,
      lifecycle:
        verified.lifeCycleStatus ||
        verified.lifeCycleStatusName ||
        verified.status ||
        null,
      visibility: verified.visibility || null,
      subscriptionAvailability:
        verified.subscriptionAvailability || null,
      policies: verified.policies || [],
      transport: verified.transport || []
    })
  );

  return verified;
}


async function waitForPublishedLifecycle(
  api,
  apiId,
  token
) {
  for (let attempt = 1; attempt <= 20; attempt += 1) {
    const current = await publisherRestRequest(
      'GET',
      `${APIM_URL}/api/am/publisher/v4/apis/${apiId}`,
      token
    );

    const status =
      current.lifeCycleStatus ||
      current.lifeCycleStatusName ||
      current.status;

    if (status === 'PUBLISHED') {
      return current;
    }

    log(
      `Waiting for ${api.name} lifecycle PUBLISHED ` +
      `(${attempt}/20); current=${status || 'UNKNOWN'}`
    );

    await sleep(1000);
  }

  throw new Error(
    `${api.name} did not reach lifecycle state PUBLISHED.`
  );
}


async function forceDevportalReindex(api, token) {
  const publisherApi = await findPublisherApiForBootstrap(api, token);

  await ensureMinimalPublisherCustomPropertiesBeforePublish(
    api,
    publisherApi,
    token
  );

  const fullApi = await ensurePublisherDevportalConfiguration(
    api,
    publisherApi,
    token
  );

  const currentStatus =
    fullApi.lifeCycleStatus ||
    fullApi.lifeCycleStatusName ||
    fullApi.status;

  if (currentStatus !== 'PUBLISHED') {
    log(
      `${api.name} is ${currentStatus || 'UNKNOWN'}; ` +
      `publishing it before retrying DevPortal discovery.`
    );

    await publisherRestRequest(
      'POST',
      `${APIM_URL}/api/am/publisher/v4/apis/change-lifecycle` +
        `?apiId=${encodeURIComponent(publisherApi.id)}` +
        `&action=${encodeURIComponent('Publish')}`,
      token,
      null,
      [200, 201, 202]
    );

    await waitForPublishedLifecycle(
      api,
      publisherApi.id,
      token
    );

    return;
  }

  /*
   * A no-op Publisher update above usually emits enough state for DevPortal
   * reconciliation. When the API is still missing, demote and publish it once
   * to generate a fresh lifecycle event without deleting the API, revisions,
   * subscriptions, or product associations.
   */
  log(
    `${api.name} is PUBLISHED but absent from DevPortal; ` +
    `forcing one lifecycle re-index.`
  );

  let demoted = false;

  try {
    await publisherRestRequest(
      'POST',
      `${APIM_URL}/api/am/publisher/v4/apis/change-lifecycle` +
        `?apiId=${encodeURIComponent(publisherApi.id)}` +
        `&action=${encodeURIComponent('Demote to Created')}`,
      token,
      null,
      [200, 201, 202]
    );

    demoted = true;
    log(`${api.name} temporarily demoted to CREATED.`);
  } catch (error) {
    log(
      `Lifecycle demotion was not available for ${api.name}: ` +
      `${error.message}`
    );
  }

  if (demoted) {
    await publisherRestRequest(
      'POST',
      `${APIM_URL}/api/am/publisher/v4/apis/change-lifecycle` +
        `?apiId=${encodeURIComponent(publisherApi.id)}` +
        `&action=${encodeURIComponent('Publish')}`,
      token,
      null,
      [200, 201, 202]
    );

    await waitForPublishedLifecycle(
      api,
      publisherApi.id,
      token
    );

    log(`${api.name} was republished for DevPortal re-indexing.`);
  }
}


async function publishApiWithPublisherRest(api) {
  const token = await getAdminToken();
  const publisherApi = await findPublisherApiForBootstrap(
    api,
    token
  );

  /*
   * Do this even when the search result already says PUBLISHED. Previously,
   * the early return prevented stale API metadata from being repaired.
   */
  await ensureMinimalPublisherCustomPropertiesBeforePublish(
    api,
    publisherApi,
    token
  );

  let fullApi = await ensurePublisherDevportalConfiguration(
    api,
    publisherApi,
    token
  );

  const currentStatus =
    fullApi.lifeCycleStatus ||
    fullApi.lifeCycleStatusName ||
    fullApi.status;

  if (currentStatus !== 'PUBLISHED') {
    log(
      `Publishing ${publisherApi.name}:` +
      `${publisherApi.version || api.version} through Publisher REST API.`
    );

    await publisherRestRequest(
      'POST',
      `${APIM_URL}/api/am/publisher/v4/apis/change-lifecycle` +
        `?apiId=${encodeURIComponent(publisherApi.id)}` +
        `&action=${encodeURIComponent('Publish')}`,
      token,
      null,
      [200, 201, 202]
    );

    fullApi = await waitForPublishedLifecycle(
      api,
      publisherApi.id,
      token
    );

    log(
      `${publisherApi.name} published successfully through Publisher REST API.`
    );
  } else {
    log(
      `${publisherApi.name} is already PUBLISHED; ` +
      `its DevPortal metadata was revalidated.`
    );
  }

  return {
    ...publisherApi,
    ...fullApi
  };
}

// END DEVPORTAL SELF-HEAL PATCH
'''

text = replace_region(
    text,
    "async function publishApiWithPublisherRest(api)",
    "async function importAndPublishStreamingApi(api)",
    publisher_publish,
)


# ---------------------------------------------------------------------------
# Replace the short fixed poll with:
# - 90 attempts by default (three minutes);
# - one state-repair/re-index pass after the original 30-attempt window;
# - Publisher diagnostics if discovery ultimately fails.
# ---------------------------------------------------------------------------

devportal_find = r'''
async function findDevportalApiId(api, token) {
  const apiName = api.name;
  const expectedVersion = api.version;

  const configuredAttempts = Number.parseInt(
    process.env.DEVPORTAL_INDEX_ATTEMPTS || '90',
    10
  );

  const configuredDelay = Number.parseInt(
    process.env.DEVPORTAL_INDEX_DELAY_MS || '2000',
    10
  );

  const maxAttempts = Number.isFinite(configuredAttempts)
    ? Math.max(30, configuredAttempts)
    : 90;

  const delayMs = Number.isFinite(configuredDelay)
    ? Math.max(500, configuredDelay)
    : 2000;

  const repairAttempt = Math.min(30, maxAttempts);
  let recoveryExecuted = false;

  async function searchDevportal(query) {
    const encoded = encodeURIComponent(query);

    const res = await apiRequest(
      'GET',
      `${APIM_URL}/api/am/devportal/v3/apis` +
        `?query=${encoded}&limit=100`,
      token
    );

    return res.data?.list || res.data?.data || [];
  }

  async function listDevportalPage(offset = 0) {
    const res = await apiRequest(
      'GET',
      `${APIM_URL}/api/am/devportal/v3/apis` +
        `?limit=100&offset=${offset}`,
      token
    );

    return res.data?.list || res.data?.data || [];
  }

  function matchApi(list) {
    return list.find(
      item =>
        item.name === apiName &&
        (!item.version || item.version === expectedVersion)
    );
  }

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    const candidates = [
      ...(await searchDevportal(apiName)),
      ...(await searchDevportal(`name:${apiName}`)),
      ...(await listDevportalPage(0))
    ];

    const match = matchApi(candidates);

    if (match?.id) {
      log(`DevPortal API found: ${apiName} (${match.id})`);
      return match.id;
    }

    if (
      !recoveryExecuted &&
      attempt === repairAttempt
    ) {
      recoveryExecuted = true;

      log(
        `${apiName} is still absent after ${attempt} checks; ` +
        `repairing Publisher visibility and forcing DevPortal reconciliation.`
      );

      await forceDevportalReindex(api, token);
    }

    log(
      `Waiting for ${apiName} to appear in DevPortal ` +
      `(${attempt}/${maxAttempts})`
    );

    await sleep(delayMs);
  }

  const all = await listDevportalPage(0);

  log(
    `Published APIs currently visible in DevPortal: ` +
    (
      all
        .map(
          item =>
            `${item.name}:${item.version || '-'}`
        )
        .join(', ') ||
      '(none)'
    )
  );

  try {
    const publisherApi = await findPublisherApiForBootstrap(
      api,
      token
    );

    const fullApi = await publisherRestRequest(
      'GET',
      `${APIM_URL}/api/am/publisher/v4/apis/${publisherApi.id}`,
      token
    );

    log(
      `Publisher diagnostic for ${apiName}: ` +
      JSON.stringify({
        id: publisherApi.id,
        name: fullApi.name,
        version: fullApi.version,
        context: fullApi.context,
        lifecycle:
          fullApi.lifeCycleStatus ||
          fullApi.lifeCycleStatusName ||
          fullApi.status ||
          null,
        visibility: fullApi.visibility || null,
        subscriptionAvailability:
          fullApi.subscriptionAvailability || null,
        policies: fullApi.policies || [],
        transport: fullApi.transport || []
      })
    );
  } catch (diagnosticError) {
    log(
      `Could not retrieve final Publisher diagnostic for ${apiName}: ` +
      diagnosticError.message
    );
  }

  throw new Error(
    `Could not find published API in DevPortal: ${apiName}`
  );
}
'''

text = replace_region(
    text,
    "async function findDevportalApiId(api, token)",
    "async function getOrCreateApplication(token)",
    devportal_find,
)


required_tokens = [
    "BEGIN DEVPORTAL SELF-HEAL PATCH",
    "DEVPORTAL_INDEX_ATTEMPTS",
    "forceDevportalReindex",
    "subscriptionAvailability = 'CURRENT_TENANT'",
]

for token in required_tokens:
    if token not in text:
        raise SystemExit(
            "[devportal-bootstrap-fix][FAIL] "
            f"Generated file is missing required token: {token}"
        )

path.write_text(text, encoding="utf-8")

print(
    "[devportal-bootstrap-fix] "
    "Patched bootstrap publication and DevPortal reconciliation."
)
PY

if command -v node >/dev/null 2>&1; then
  log "Checking JavaScript syntax"

  if ! node --check "$TARGET"; then
    cp "$backup" "$TARGET"
    fail "JavaScript syntax check failed; original file was restored."
  fi
else
  log "Node is not installed locally; syntax will be checked during image build."
fi

grep -q 'BEGIN DEVPORTAL SELF-HEAL PATCH' "$TARGET" ||
  fail "Self-healing patch marker was not found."

grep -q 'DEVPORTAL_INDEX_ATTEMPTS' "$TARGET" ||
  fail "Extended indexing retry was not installed."

grep -q 'forceDevportalReindex' "$TARGET" ||
  fail "DevPortal re-index function was not installed."

cat <<EOF

[devportal-bootstrap-fix] Patch installed successfully.

Backup:
  ${backup}

IMPORTANT:
The apim-bootstrapper image must be rebuilt. Do not use SKIP_BUILD=true for
the first restart after this patch.

Run:

  unset SKIP_BUILD
  bash scripts/telco-demo-control.sh restart

EOF
