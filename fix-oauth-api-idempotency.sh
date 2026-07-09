#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

GENERATED_JS="services/apim-bootstrapper/src/oauth-business-controls-setup.js"

log() {
  printf '[oauth-api-idempotency-fix] %s\n' "$*"
}

fail() {
  printf '[oauth-api-idempotency-fix][FAIL] %s\n' "$*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 ||
  fail "python3 is required."

[[ -f "$GENERATED_JS" ]] ||
  fail "Missing $GENERATED_JS"

targets=("$GENERATED_JS")

for installer in \
  install-oauth-consent-risk-controls-v2.sh \
  install-oauth-consent-risk-controls.sh
do
  if [[ -f "$installer" ]]; then
    targets+=("$installer")
  fi
done

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/oauth-api-idempotency-${timestamp}"
mkdir -p "$backup_dir"

for target in "${targets[@]}"; do
  backup_name="$(
    printf '%s' "$target" |
      tr '/' '_'
  )"

  cp "$target" "${backup_dir}/${backup_name}"
done

log "Backups written under $backup_dir"

python3 - "${targets[@]}" <<'PY'
from pathlib import Path
import sys


finder_replacement = r'''/* oauth-api-idempotency-v2 */
async function listAndFindApi(token) {
  function normalizeContext(value) {
    const normalized = String(value || '').trim();

    if (normalized.length > 1) {
      return normalized.replace(/\/+$/, '');
    }

    return normalized;
  }

  function isTarget(candidate) {
    return (
      candidate &&
      candidate.name === API_NAME &&
      String(candidate.version || '') === API_VERSION
    );
  }

  async function readFullApi(id) {
    if (!id) return null;

    try {
      const response = await request(
        `${APIM_URL}/api/am/publisher/v4/apis/${encodeURIComponent(id)}`,
        {
          headers: bearer(token)
        }
      );

      return response.data || null;
    } catch (error) {
      log(
        `Could not read Publisher API ${id}; continuing discovery: ` +
        `${error.message || error}`
      );

      return null;
    }
  }

  /*
   * First reuse the API ID written by an earlier successful OAuth bootstrap.
   * This avoids relying on Publisher search indexing during repeated starts.
   */
  if (fs.existsSync(STATE_FILE)) {
    try {
      const state = JSON.parse(
        fs.readFileSync(STATE_FILE, 'utf8')
      );

      const storedId =
        state?.api?.id ||
        state?.apiId ||
        null;

      if (storedId) {
        const storedApi = await readFullApi(storedId);

        if (isTarget(storedApi)) {
          log(
            `Resolved existing ${API_NAME}:${API_VERSION} ` +
            `from bootstrap state: ${storedApi.id}`
          );

          return storedApi;
        }
      }
    } catch (error) {
      log(
        `Bootstrap state could not be reused; ` +
        `falling back to Publisher discovery: ${error.message || error}`
      );
    }
  }

  /*
   * WSO2 Publisher search can temporarily omit an existing API or interpret
   * query expressions differently across API-M releases. Try targeted
   * searches first, followed by an authoritative unfiltered traversal.
   */
  const searches = [
    `name:${API_NAME}`,
    API_NAME,
    `context:${API_CONTEXT}`,
    API_CONTEXT,
    ''
  ];

  const seenIds = new Set();
  let nameVersionFallback = null;

  for (const search of searches) {
    let offset = 0;

    for (let page = 0; page < 50; page += 1) {
      const queryPart = search
        ? `&query=${encodeURIComponent(search)}`
        : '';

      let response;

      try {
        response = await request(
          `${APIM_URL}/api/am/publisher/v4/apis` +
            `?limit=100&offset=${offset}${queryPart}`,
          {
            headers: bearer(token)
          }
        );
      } catch (error) {
        log(
          `Publisher lookup '${search || '<unfiltered>'}' failed ` +
          `non-fatally: ${error.message || error}`
        );

        break;
      }

      const summaries =
        response.data?.list ||
        response.data?.data ||
        response.data ||
        [];

      if (!Array.isArray(summaries)) {
        break;
      }

      for (const summary of summaries) {
        if (!summary?.id || seenIds.has(summary.id)) {
          continue;
        }

        seenIds.add(summary.id);

        const candidate =
          (await readFullApi(summary.id)) ||
          summary;

        if (!isTarget(candidate)) {
          continue;
        }

        if (
          normalizeContext(candidate.context) ===
          normalizeContext(API_CONTEXT)
        ) {
          log(
            `Resolved existing ${API_NAME}:${API_VERSION} ` +
            `by Publisher discovery: ${candidate.id}`
          );

          return candidate;
        }

        /*
         * APIM uniqueness is primarily based on API identity. Preserve a
         * same-name/version result as a fallback instead of attempting a POST
         * that will necessarily return 409.
         */
        nameVersionFallback ||= candidate;
      }

      if (summaries.length < 100) {
        break;
      }

      offset += summaries.length;
    }
  }

  if (nameVersionFallback) {
    log(
      `Resolved ${API_NAME}:${API_VERSION} by name/version with context ` +
      `'${nameVersionFallback.context || '<empty>'}'. ` +
      `The existing API will be reconciled instead of recreated.`
    );

    return nameVersionFallback;
  }

  return null;
}'''


upsert_replacement = r'''async function upsertApi(token) {
  let api = await listAndFindApi(token);
  let changed = false;
  let createdNow = false;

  if (!api) {
    try {
      const created = await request(
        `${APIM_URL}/api/am/publisher/v4/apis`,
        {
          method: 'POST',
          headers: bearer(
            token,
            {
              'content-type': 'application/json'
            }
          ),
          body: JSON.stringify(apiPayload())
        }
      );

      api = created.data;
      changed = true;
      createdNow = true;

      log(`Created API ${api.id}`);
    } catch (error) {
      const message = String(
        error?.message ||
        error ||
        ''
      );

      const duplicate =
        message.includes('HTTP 409') ||
        message.includes('"code":900300') ||
        message.includes('The API already exists');

      if (!duplicate) {
        throw error;
      }

      log(
        `${API_NAME}:${API_VERSION} already exists in APIM; ` +
        `recovering the existing API instead of failing.`
      );

      for (
        let attempt = 1;
        attempt <= 20 && !api;
        attempt += 1
      ) {
        await sleep(500);
        api = await listAndFindApi(token);
      }

      if (!api?.id) {
        throw new Error(
          `APIM reported that ${API_NAME}:${API_VERSION} already exists, ` +
          `but it could not be resolved by stored ID, name, context, or ` +
          `unfiltered Publisher pagination. Original error: ${message}`
        );
      }

      log(
        `Recovered existing API ${api.id} after create returned HTTP 409.`
      );
    }
  }

  const currentMarker =
    (api?.additionalProperties || [])
      .find(
        item =>
          item.name === 'SecurityControlModel'
      )
      ?.value;

  const currentScopeKeys = new Set(
    (api?.scopes || [])
      .map(scope => scope.key)
      .filter(Boolean)
  );

  const completeScopes = SCOPES.every(
    scope =>
      currentScopeKeys.has(scope.key)
  );

  const currentPolicies = new Set(
    Array.isArray(api?.policies)
      ? api.policies
      : []
  );

  const completePolicies = [
    'TelcoConsentRiskPartner',
    'TelcoConsentRiskOperations',
    'Unlimited'
  ].every(
    policy =>
      currentPolicies.has(policy)
  );

  const normalizedCurrentContext =
    String(api?.context || '')
      .replace(/\/+$/, '');

  const normalizedDesiredContext =
    String(API_CONTEXT)
      .replace(/\/+$/, '');

  const needsReconciliation =
    !createdNow &&
    (
      currentMarker !== MARKER ||
      !completeScopes ||
      !completePolicies ||
      normalizedCurrentContext !== normalizedDesiredContext ||
      String(api?.visibility || '').toUpperCase() !== 'PUBLIC'
    );

  if (needsReconciliation) {
    const updated = await request(
      `${APIM_URL}/api/am/publisher/v4/apis/${encodeURIComponent(api.id)}`,
      {
        method: 'PUT',
        headers: bearer(
          token,
          {
            'content-type': 'application/json'
          }
        ),
        body: JSON.stringify(apiPayload(api))
      }
    );

    api = updated.data || api;
    changed = true;

    log(
      `Reconciled existing API ${api.id} with the desired ` +
      `OAuth business-control configuration.`
    );
  } else if (!createdNow) {
    log(
      `API ${api.id} already carries ${MARKER}; ` +
      `the existing API will be reused.`
    );
  }

  const definition = fs.readFileSync(
    CONTRACT,
    'utf8'
  );

  const form = new FormData();
  form.set('apiDefinition', definition);

  await request(
    `${APIM_URL}/api/am/publisher/v4/apis/${encodeURIComponent(api.id)}/swagger`,
    {
      method: 'PUT',
      headers: bearer(token),
      body: form
    },
    [200]
  );

  log('Updated managed OpenAPI definition');

  /*
   * Do not create a revision merely because bootstrap ran again.
   * Create and deploy one only when the API has no current deployment.
   */
  const deploymentsResult = await request(
    `${APIM_URL}/api/am/publisher/v4/apis/${encodeURIComponent(api.id)}/deployments`,
    {
      headers: bearer(token)
    }
  );

  const deployments =
    deploymentsResult.data?.list ||
    deploymentsResult.data ||
    [];

  if (
    !Array.isArray(deployments) ||
    deployments.length === 0
  ) {
    const revision = await request(
      `${APIM_URL}/api/am/publisher/v4/apis/${encodeURIComponent(api.id)}/revisions`,
      {
        method: 'POST',
        headers: bearer(
          token,
          {
            'content-type': 'application/json'
          }
        ),
        body: JSON.stringify({
          description:
            'OAuth scopes, roles, consent and risk-based authorization'
        })
      }
    );

    await request(
      `${APIM_URL}/api/am/publisher/v4/apis/${encodeURIComponent(api.id)}` +
        `/deploy-revision?revisionId=${encodeURIComponent(revision.data.id)}`,
      {
        method: 'POST',
        headers: bearer(
          token,
          {
            'content-type': 'application/json'
          }
        ),
        body: JSON.stringify([
          {
            name: 'Default',
            vhost: 'localhost',
            displayOnDevportal: true
          }
        ])
      }
    );

    log(`Deployed revision ${revision.data.id}`);
  } else {
    log(
      `API already has ${deployments.length} deployment(s); ` +
      `preserving the currently deployed revision.`
    );
  }

  const refreshed = await request(
    `${APIM_URL}/api/am/publisher/v4/apis/${encodeURIComponent(api.id)}`,
    {
      headers: bearer(token)
    }
  );

  api = refreshed.data || api;

  if (
    String(
      api?.lifeCycleStatus ||
      ''
    ).toUpperCase() !== 'PUBLISHED'
  ) {
    await request(
      `${APIM_URL}/api/am/publisher/v4/apis/change-lifecycle` +
        `?action=Publish&apiId=${encodeURIComponent(api.id)}`,
      {
        method: 'POST',
        headers: bearer(token)
      },
      [200, 201]
    );

    log('Published API');
  } else {
    log('API is already PUBLISHED');
  }

  return api;
}'''


for filename in sys.argv[1:]:
    path = Path(filename)
    source = path.read_text(encoding="utf-8")

    finder_start = source.find(
        "async function listAndFindApi(token) {"
    )

    finder_end = source.find(
        "\nfunction apiPayload(",
        finder_start,
    )

    if finder_start < 0 or finder_end < 0:
        raise SystemExit(
            "[oauth-api-idempotency-fix][FAIL] "
            f"Could not locate listAndFindApi() in {path}"
        )

    source = (
        source[:finder_start]
        + finder_replacement
        + "\n\n"
        + source[finder_end + 1:]
    )

    upsert_start = source.find(
        "async function upsertApi(token) {"
    )

    upsert_end = source.find(
        "\nasync function upsertDocument(",
        upsert_start,
    )

    if upsert_start < 0 or upsert_end < 0:
        raise SystemExit(
            "[oauth-api-idempotency-fix][FAIL] "
            f"Could not locate upsertApi() in {path}"
        )

    source = (
        source[:upsert_start]
        + upsert_replacement
        + "\n\n"
        + source[upsert_end + 1:]
    )

    required = [
        "oauth-api-idempotency-v2",
        "recovering the existing API instead of failing",
        "unfiltered Publisher pagination",
        "preserving the currently deployed revision",
    ]

    missing = [
        item
        for item in required
        if item not in source
    ]

    if missing:
        raise SystemExit(
            "[oauth-api-idempotency-fix][FAIL] "
            f"{path} is missing generated markers: {missing}"
        )

    path.write_text(
        source,
        encoding="utf-8",
    )

    print(
        "[oauth-api-idempotency-fix] "
        f"Patched {path}"
    )
PY

if command -v node >/dev/null 2>&1; then
  log "Checking JavaScript syntax"

  if ! node --check "$GENERATED_JS"; then
    log "JavaScript validation failed; restoring backups."

    for target in "${targets[@]}"; do
      backup_name="$(
        printf '%s' "$target" |
          tr '/' '_'
      )"

      cp \
        "${backup_dir}/${backup_name}" \
        "$target"
    done

    fail "Invalid JavaScript was generated. Original files were restored."
  fi
else
  log "Node is unavailable locally; JavaScript will be checked during image build."
fi

for target in "${targets[@]}"; do
  case "$target" in
    *.sh)
      if ! bash -n "$target"; then
        log "Shell validation failed for $target; restoring backups."

        for restore_target in "${targets[@]}"; do
          backup_name="$(
            printf '%s' "$restore_target" |
              tr '/' '_'
          )"

          cp \
            "${backup_dir}/${backup_name}" \
            "$restore_target"
        done

        fail "Invalid shell syntax was generated. Original files were restored."
      fi
      ;;
  esac
done

grep -q \
  'oauth-api-idempotency-v2' \
  "$GENERATED_JS" ||
  fail "The generated OAuth bootstrap was not patched."

grep -q \
  'recovering the existing API instead of failing' \
  "$GENERATED_JS" ||
  fail "HTTP 409 recovery was not installed."

cat <<EOF

[oauth-api-idempotency-fix] Patch installed successfully.

The bootstrap will now:

  1. Try the API ID from oauth-business-controls.json.
  2. Search Publisher by name and context.
  3. Traverse the complete Publisher API inventory.
  4. Recover the existing API when POST returns HTTP 409.
  5. Preserve an existing deployed revision.
  6. Reconcile scopes, plans, visibility and OAuth metadata.

Backups:

  ${backup_dir}

The bootstrapper image must now be rebuilt.

EOF
