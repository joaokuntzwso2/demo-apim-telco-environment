#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

OAUTH_JS="services/apim-bootstrapper/src/oauth-business-controls-setup.js"
DX_JS="services/apim-bootstrapper/src/developer-experience-setup.js"
VERIFY="scripts/verify-oauth-consent-risk-controls.sh"
HELPER="scripts/complete-oauth-post-start.sh"
RECONCILE="scripts/reconcile-oauth-control-plane.sh"

log() {
  printf '[oauth-convergence-repair] %s\n' "$*"
}

fail() {
  printf '[oauth-convergence-repair][FAIL] %s\n' "$*" >&2
  exit 1
}

for command in bash python3 docker jq curl; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Required command is missing: $command"
done

for file in \
  "$OAUTH_JS" \
  "$DX_JS" \
  "$VERIFY" \
  "$HELPER" \
  docker-compose.yml
do
  [[ -f "$file" ]] || fail "Required file is missing: $file"
done

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/oauth-convergence-${timestamp}"
mkdir -p "$backup_dir"

for file in "$OAUTH_JS" "$DX_JS" "$VERIFY" "$HELPER"; do
  cp "$file" \
    "$backup_dir/$(printf '%s' "$file" | tr '/' '_')"
done

log "Backups written under $backup_dir"

python3 - "$OAUTH_JS" "$DX_JS" "$VERIFY" "$HELPER" <<'PY'
from pathlib import Path
import re
import sys

oauth_path = Path(sys.argv[1])
dx_path = Path(sys.argv[2])
verify_path = Path(sys.argv[3])
helper_path = Path(sys.argv[4])

oauth = oauth_path.read_text(encoding="utf-8")
dx = dx_path.read_text(encoding="utf-8")
verify = verify_path.read_text(encoding="utf-8")
helper = helper_path.read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# 1. API deployment repair
#
# The generated OAuth bootstrap originally guarded its entire deployment
# check with `if (changed)`. That means an existing API with correct metadata
# but no deployed revision can never self-heal.
# ---------------------------------------------------------------------------

api_marker = "OAUTH API DEPLOYMENT CONVERGENCE"

if api_marker not in oauth:
    definition_log = "log('Updated managed OpenAPI definition');"
    definition_index = oauth.find(definition_log)

    if definition_index < 0:
        raise SystemExit(
            "[oauth-convergence-repair][FAIL] "
            "Could not locate the managed OpenAPI update in OAuth bootstrap."
        )

    function_end = oauth.find(
        "\nasync function upsertDocument(",
        definition_index,
    )

    if function_end < 0:
        raise SystemExit(
            "[oauth-convergence-repair][FAIL] "
            "Could not locate the end of upsertApi()."
        )

    segment = oauth[definition_index:function_end]

    conditional = re.search(
        r"\n\s*if\s*\(\s*changed\s*\)\s*\{",
        segment,
    )

    if conditional:
        absolute_start = definition_index + conditional.start()
        absolute_end = definition_index + conditional.end()

        replacement = (
            "\n\n"
            "  /* OAUTH API DEPLOYMENT CONVERGENCE\n"
            "   * Always inspect deployment state. Existing API metadata does\n"
            "   * not prove that a gateway revision is deployed.\n"
            "   */\n"
            "  {"
        )

        oauth = (
            oauth[:absolute_start]
            + replacement
            + oauth[absolute_end:]
        )

        print(
            "[oauth-convergence-repair] "
            "Removed changed-only guard from OAuth API deployment."
        )
    elif "/deployments" in segment:
        marker_position = definition_index + len(definition_log)
        oauth = (
            oauth[:marker_position]
            + "\n\n  /* OAUTH API DEPLOYMENT CONVERGENCE */"
            + oauth[marker_position:]
        )

        print(
            "[oauth-convergence-repair] "
            "OAuth deployment check was already unconditional."
        )
    else:
        raise SystemExit(
            "[oauth-convergence-repair][FAIL] "
            "Could not locate OAuth API deployment logic."
        )


# ---------------------------------------------------------------------------
# 2. API Product deployment repair
#
# A PUBLISHED lifecycle state is insufficient. Only return early when the
# Product is both PUBLISHED and currently deployed.
# ---------------------------------------------------------------------------

product_marker = "OAUTH PRODUCT DEPLOYMENT CONVERGENCE"

if product_marker not in dx:
    early_return = re.compile(
        r"""
        \s*if\s*\(\s*currentState\s*===\s*['"]PUBLISHED['"]\s*\)\s*\{
        \s*log\([^;]*already\s+PUBLISHED[^;]*\);
        \s*return\s+['"]PUBLISHED['"];
        \s*\}
        """,
        re.VERBOSE | re.DOTALL,
    )

    replacement = r'''
  /* OAUTH PRODUCT DEPLOYMENT CONVERGENCE
   * PUBLISHED does not imply that a Product revision is deployed.
   */
  let currentProductDeployments = [];

  try {
    const deploymentResponse = await request(
      `${APIM_URL}/api/am/publisher/v4/api-products/${product.id}/deployments`,
      { bearer: token }
    );

    currentProductDeployments =
      deploymentResponse?.list ||
      deploymentResponse?.data ||
      deploymentResponse ||
      [];

    if (!Array.isArray(currentProductDeployments)) {
      currentProductDeployments = [];
    }
  } catch (error) {
    log(
      `Could not inspect current API Product deployments for ` +
      `${product.name}: ${error.message}`
    );
  }

  if (
    currentState === 'PUBLISHED' &&
    currentProductDeployments.length > 0
  ) {
    log(
      `${product.name} is already PUBLISHED and has ` +
      `${currentProductDeployments.length} deployed revision(s).`
    );

    return 'PUBLISHED';
  }

  if (currentState === 'PUBLISHED') {
    log(
      `${product.name} is PUBLISHED but has no deployed revision; ` +
      `creating or reusing a revision for Developer Portal visibility.`
    );
  }
'''

    dx, count = early_return.subn(
        replacement,
        dx,
        count=1,
    )

    if count != 1:
        raise SystemExit(
            "[oauth-convergence-repair][FAIL] "
            "Could not patch ensureProductPublished()."
        )

    print(
        "[oauth-convergence-repair] "
        "Patched API Product publication to require a deployment."
    )


# ---------------------------------------------------------------------------
# 3. Replace the verifier's Developer Portal section.
#
# The current output has a blank Product name, showing that the diagnostic and
# lookup depend on an empty variable. Use the authoritative exact object name.
# ---------------------------------------------------------------------------

portal_start_marker = (
    'echo "[oauth-controls-verify] Checking Developer Portal visibility '
    'and application subscriptions."'
)

portal_start = verify.find(portal_start_marker)
portal_end = verify.find(
    "partner_application_id=",
    portal_start,
)

if portal_start < 0 or portal_end < 0:
    raise SystemExit(
        "[oauth-convergence-repair][FAIL] "
        "Could not locate the verifier Developer Portal section."
    )

portal_replacement = r'''echo "[oauth-controls-verify] Checking Developer Portal visibility and application subscriptions."

oauth_api_name="SubscriberAuthorizationControlAPI"
oauth_product_name="SubscriberAuthorizationBusinessControlsProduct"

devportal_apis=""
for attempt in $(seq 1 60); do
  devportal_apis="$(
    curl -ksS \
      -H "Authorization: Bearer ${devportal_token}" \
      "${APIM_URL}/api/am/devportal/v3/apis?limit=1000"
  )"

  if jq -e \
    --arg name "${oauth_api_name}" \
    'any((.list // .data // [])[]?;
      .name == $name and (.version // "1.0.0") == "1.0.0"
    )' \
    <<<"${devportal_apis}" >/dev/null 2>&1
  then
    break
  fi

  echo "[oauth-controls-verify] Waiting for API ${oauth_api_name} Developer Portal indexing (${attempt}/60)."
  sleep 2
done

if jq -e \
  --arg name "${oauth_api_name}" \
  'any((.list // .data // [])[]?;
    .name == $name and (.version // "1.0.0") == "1.0.0"
  )' \
  <<<"${devportal_apis}" >/dev/null 2>&1
then
  pass "Managed API is visible in the Developer Portal."
else
  fail "Managed API is not visible in the Developer Portal."
  jq -c \
    '[((.list // .data // [])[]) | {name,version,id}]' \
    <<<"${devportal_apis}" >&2 ||
    printf '%s\n' "${devportal_apis}" >&2
fi

devportal_products=""
for attempt in $(seq 1 60); do
  devportal_products="$(
    curl -ksS \
      -H "Authorization: Bearer ${devportal_token}" \
      "${APIM_URL}/api/am/devportal/v3/api-products?limit=1000"
  )"

  if jq -e \
    --arg name "${oauth_product_name}" \
    'any((.list // .data // [])[]?;
      .name == $name and (.version // "1.0.0") == "1.0.0"
    )' \
    <<<"${devportal_products}" >/dev/null 2>&1
  then
    break
  fi

  echo "[oauth-controls-verify] Waiting for API Product ${oauth_product_name} Developer Portal indexing (${attempt}/60)."
  sleep 2
done

if jq -e \
  --arg name "${oauth_product_name}" \
  'any((.list // .data // [])[]?;
    .name == $name and (.version // "1.0.0") == "1.0.0"
  )' \
  <<<"${devportal_products}" >/dev/null 2>&1
then
  pass "Native API Product is visible and subscribable in the Developer Portal."
else
  fail "Native API Product is not visible in the Developer Portal."
  jq -c \
    '[((.list // .data // [])[]) | {name,version,id}]' \
    <<<"${devportal_products}" >&2 ||
    printf '%s\n' "${devportal_products}" >&2
fi

'''

verify = (
    verify[:portal_start]
    + portal_replacement
    + verify[portal_end:]
)

print(
    "[oauth-convergence-repair] "
    "Replaced blank API Product Developer Portal lookup."
)


# ---------------------------------------------------------------------------
# 4. Run control-plane reconciliation automatically in the restart helper.
# ---------------------------------------------------------------------------

reconcile_call = (
    'bash scripts/reconcile-oauth-control-plane.sh'
)

if reconcile_call not in helper:
    catalog_anchor = (
        'if [[ "${SKIP_OAUTH_CATALOG_REGISTRATION:-false}" != "true" ]]; then'
    )

    anchor_index = helper.find(catalog_anchor)

    if anchor_index < 0:
        raise SystemExit(
            "[oauth-convergence-repair][FAIL] "
            "Could not locate OAuth catalog registration in the helper."
        )

    helper_block = r'''
if [[ "${SKIP_OAUTH_RECONCILE:-false}" != "true" ]]; then
  run_with_retries \
    "Reconciling OAuth API deployment, applications, credentials and API Product" \
    "${OAUTH_RECONCILE_ATTEMPTS:-3}" \
    "${OAUTH_RECONCILE_RETRY_DELAY_SECONDS:-15}" \
    bash scripts/reconcile-oauth-control-plane.sh
else
  log "OAuth control-plane reconciliation was skipped"
fi

'''

    helper = (
        helper[:anchor_index]
        + helper_block
        + helper[anchor_index:]
    )

    print(
        "[oauth-convergence-repair] "
        "Added automatic OAuth reconciliation to restart helper."
    )


oauth_path.write_text(oauth, encoding="utf-8")
dx_path.write_text(dx, encoding="utf-8")
verify_path.write_text(verify, encoding="utf-8")
helper_path.write_text(helper, encoding="utf-8")
PY

cat > "$RECONCILE" <<'BASH_RECONCILE'
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
  compose=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  compose=(docker-compose)
else
  fail "Docker Compose is unavailable."
fi

PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$ROOT_DIR")}"

compose_command=(
  "${compose[@]}"
  -p "$PROJECT"
)

compose_files=(
  docker-compose.yml
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

for file in "${compose_files[@]}"; do
  [[ -f "$file" ]] &&
    compose_command+=(-f "$file")
done

"${compose_command[@]}" config --services |
  grep -qx 'apim-bootstrapper' ||
  fail "apim-bootstrapper is absent from the merged Compose topology."

log "Running the dedicated OAuth bootstrap module."

"${compose_command[@]}" run \
  --rm \
  --no-deps \
  --entrypoint /bin/bash \
  apim-bootstrapper \
  -lc '
    set -Eeuo pipefail
    node src/oauth-business-controls-setup.js
  '

log "Reconciling API Product deployment and Developer Portal publication."

"${compose_command[@]}" run \
  --rm \
  --no-deps \
  --entrypoint /bin/bash \
  apim-bootstrapper \
  -lc '
    set -Eeuo pipefail
    node src/developer-experience-setup.js
  '

log "OAuth API, applications, keys, state and API Product reconciled."
BASH_RECONCILE

chmod +x \
  "$RECONCILE" \
  "$VERIFY" \
  "$HELPER"

log "Validating generated shell and JavaScript"

bash -n "$RECONCILE"
bash -n "$VERIFY"
bash -n "$HELPER"

if command -v node >/dev/null 2>&1; then
  node --check "$OAUTH_JS"
  node --check "$DX_JS"
fi

grep -q \
  'OAUTH API DEPLOYMENT CONVERGENCE' \
  "$OAUTH_JS" ||
  fail "OAuth API deployment patch is absent."

grep -q \
  'OAUTH PRODUCT DEPLOYMENT CONVERGENCE' \
  "$DX_JS" ||
  fail "OAuth Product deployment patch is absent."

grep -q \
  'SubscriberAuthorizationBusinessControlsProduct' \
  "$VERIFY" ||
  fail "Verifier does not contain the exact API Product name."

grep -q \
  'reconcile-oauth-control-plane.sh' \
  "$HELPER" ||
  fail "Restart helper does not call reconciliation."

if docker compose version >/dev/null 2>&1; then
  compose=(docker compose)
else
  compose=(docker-compose)
fi

PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$ROOT")}"

compose_command=(
  "${compose[@]}"
  -p "$PROJECT"
)

compose_files=(
  docker-compose.yml
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

for file in "${compose_files[@]}"; do
  [[ -f "$file" ]] &&
    compose_command+=(-f "$file")
done

log "Validating merged Docker Compose topology"
"${compose_command[@]}" config >/dev/null

log "Rebuilding only apim-bootstrapper with the repaired JavaScript"
"${compose_command[@]}" build apim-bootstrapper

log "Executing complete OAuth reconciliation and verification"
bash scripts/complete-oauth-post-start.sh

cat <<EOF

[oauth-convergence-repair] Repair completed successfully.

The normal restart path now automatically performs:

  OAuth API deployment reconciliation
  → OAuth persona reconciliation
  → recreation of all three demo applications
  → creation of fresh subscriptions
  → generation of fresh production keys
  → rewrite of oauth-business-controls.json
  → API Product deployment reconciliation
  → Developer Portal indexing
  → Service Catalog registration
  → complete runtime verification

Normal restart:

  bash scripts/telco-demo-control.sh restart

Backups:

  ${backup_dir}

EOF
