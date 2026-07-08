#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

info() {
  printf '[commercial-product-v4] %s\n' "$*"
}

for command in python3 node docker jq; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done

python3 <<'PY'
from pathlib import Path
import json
import re

experience_path = Path('services/apim-bootstrapper/src/commercial-experience-setup.js')
product_setup_path = Path('services/apim-bootstrapper/src/api-product-bundles-setup.js')
package_path = Path('services/apim-bootstrapper/package.json')
bundle_path = Path('artifacts/apim-admin/api-product-bundles.json')

for path in (experience_path, product_setup_path, package_path, bundle_path):
    if not path.is_file():
        raise SystemExit(f'Missing required file: {path}')

# API and API Product collection endpoints do not have identical query behavior.
# Enumerate the collection with pagination and perform the exact match locally.
experience = experience_path.read_text()
old_find = '''async function findExact(basePath, name, accessToken) {
  const result = await request(`${APIM_URL}${basePath}?limit=100&offset=0&query=${encodeURIComponent(`name:${name}`)}`, { headers: auth(accessToken) });
  return (result.data?.list || []).find((item) => item.name === name && item.version === VERSION) || null;
}'''
new_find = '''async function findExact(basePath, name, accessToken) {
  const pageSize = 100;
  for (let offset = 0; offset < 2000; offset += pageSize) {
    const result = await request(`${APIM_URL}${basePath}?limit=${pageSize}&offset=${offset}`, { headers: auth(accessToken) });
    const list = Array.isArray(result.data) ? result.data : (result.data?.list || result.data?.data || []);
    const exact = list.find((item) => item.name === name && String(item.version || '') === VERSION);
    if (exact) return exact;
    const total = Number(result.data?.pagination?.total || result.data?.count || 0);
    if (list.length < pageSize || (total > 0 && offset + list.length >= total)) break;
  }
  return null;
}'''
if old_find in experience:
    experience = experience.replace(old_find, new_find, 1)
    experience_path.write_text(experience)
    print('[commercial-product-v4] patched exact API Product discovery')
elif 'const pageSize = 100;' in experience and 'offset < 2000' in experience:
    print('[commercial-product-v4] exact API Product discovery already patched')
else:
    raise SystemExit('Could not safely locate findExact in commercial-experience-setup.js')

product_setup = product_setup_path.read_text()
match = re.search(r"const NATIVE_PRODUCT_BUNDLE_IDS = new Set\(\[(.*?)\]\);", product_setup, re.S)
if not match:
    raise SystemExit('Could not locate NATIVE_PRODUCT_BUNDLE_IDS')
if "'secure-mobile-transactions'" not in match.group(1) and '"secure-mobile-transactions"' not in match.group(1):
    items = match.group(1).rstrip()
    if items and not items.endswith(','):
        items += ','
    items += " 'secure-mobile-transactions' "
    product_setup = product_setup[:match.start(1)] + items + product_setup[match.end(1):]
    print('[commercial-product-v4] added commercial bundle to native product allowlist')
else:
    print('[commercial-product-v4] commercial bundle already in native product allowlist')

# Match the operations persisted by APIM rather than relying only on static bundle paths.
old_operations = 'const operations = bundleOperations.map(operationFromBundle).filter(Boolean);'
new_operations = 'const operations = operationsFromApi(detail, bundleOperations);'
if old_operations in product_setup:
    product_setup = product_setup.replace(old_operations, new_operations, 1)
    print('[commercial-product-v4] switched API Product members to APIM-derived operations')
elif new_operations in product_setup:
    print('[commercial-product-v4] APIM-derived operations already enabled')
else:
    raise SystemExit('Could not locate API Product operation selection')

# Expose the actual commercial subscription policies on the native API Product.
policy_anchor = "apiThrottlingPolicy: 'Unlimited', transport: ['http', 'https'],"
policy_replacement = "apiThrottlingPolicy: 'Unlimited', policies: Array.from(new Set([...(bundle.apim?.subscriptionPolicies || []), ...(bundle.plans || []), 'Unlimited'])), tags: Array.from(new Set(bundle.apim?.tags || [])), transport: ['http', 'https'],"
if policy_anchor in product_setup:
    product_setup = product_setup.replace(policy_anchor, policy_replacement, 1)
    print('[commercial-product-v4] added native product policies and tags')
elif "policies: Array.from(new Set([...(bundle.apim?.subscriptionPolicies || [])" in product_setup:
    print('[commercial-product-v4] native product policies and tags already patched')
else:
    raise SystemExit('Could not locate API Product payload policy anchor')

product_setup_path.write_text(product_setup)

# commercial-experience must run after developer-experience, because that step
# publishes and deploys newly created native API Products.
package = json.loads(package_path.read_text())
start = package.setdefault('scripts', {}).get('start', '')
steps = [step.strip() for step in start.split('&&') if step.strip()]
commercial_api = 'node src/commercial-api-setup.js'
product_step = 'node src/api-product-bundles-setup.js'
developer_step = 'node src/developer-experience-setup.js'
commercial_experience = 'node src/commercial-experience-setup.js'

steps = [step for step in steps if step not in (commercial_api, commercial_experience)]
if product_step not in steps:
    raise SystemExit('api-product-bundles-setup.js is absent from bootstrap start order')
if developer_step not in steps:
    raise SystemExit('developer-experience-setup.js is absent from bootstrap start order')
steps.insert(steps.index(product_step), commercial_api)
steps.insert(steps.index(developer_step) + 1, commercial_experience)
package['scripts']['start'] = ' && '.join(steps)
package_path.write_text(json.dumps(package, indent=2) + '\n')
print('[commercial-product-v4] reordered commercial experience after product publication/deployment')

bundles = json.loads(bundle_path.read_text())
bundle = next((item for item in bundles if item.get('id') == 'secure-mobile-transactions'), None)
if not bundle:
    raise SystemExit('secure-mobile-transactions bundle is absent')
if bundle.get('apim', {}).get('apiProductName') != 'SecureMobileTransactionsProduct':
    raise SystemExit('Unexpected commercial API Product name')
if bundle.get('apim', {}).get('subscriptionPolicies') != [
    'SecureMobileSandbox', 'SecureMobileBusiness', 'SecureMobileEnterprise'
]:
    raise SystemExit('Commercial API Product subscription policies are incomplete')
print('[commercial-product-v4] commercial bundle definition validated')

# Reconcile complete installers retained in the repository when possible.
for installer_name in (
    'install-secure-mobile-commercial-flow.sh',
    'install-secure-mobile-commercial-flow-v2.sh',
    'install-secure-mobile-commercial-flow-v3.sh',
    'install-secure-mobile-commercial-flow-v4.sh',
):
    installer = Path(installer_name)
    if not installer.is_file():
        continue
    text = installer.read_text()
    if old_find in text:
        text = text.replace(old_find, new_find, 1)
    text = text.replace(old_operations, new_operations)
    text = text.replace(policy_anchor, policy_replacement)
    installer.write_text(text)
    installer.chmod(0o755)
    print(f'[commercial-product-v4] reconciled retained installer: {installer}')
PY

node --check services/apim-bootstrapper/src/api-product-bundles-setup.js
node --check services/apim-bootstrapper/src/commercial-experience-setup.js
jq -e '.scripts.start | contains("node src/developer-experience-setup.js && node src/commercial-experience-setup.js")' \
  services/apim-bootstrapper/package.json >/dev/null

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif docker-compose version >/dev/null 2>&1; then
  DC=(docker-compose)
else
  fail 'Docker Compose is required'
fi

COMPOSE_FILES=(docker-compose.yml)
for file in \
  docker-compose.kafka.yml \
  docker-compose.opa.yml \
  docker-compose.mi.yml \
  docker-compose.commercial.yml \
  docker-compose.mi.soap.yml \
  docker-compose.observability.yml \
  docker-compose.runtime-persistence.yml; do
  [[ -f "$file" ]] && COMPOSE_FILES+=("$file")
done

COMPOSE=("${DC[@]}")
for file in "${COMPOSE_FILES[@]}"; do
  COMPOSE+=(-f "$file")
done

"${COMPOSE[@]}" config >/dev/null

info 'Rebuilding the APIM bootstrapper image'
"${COMPOSE[@]}" build apim-bootstrapper

PRODUCT_LOG=/tmp/secure-mobile-api-product-bootstrap.log
info 'Reconciling the native Secure Mobile Transactions API Product'
set +e
"${COMPOSE[@]}" run --rm --entrypoint node apim-bootstrapper src/api-product-bundles-setup.js 2>&1 | tee "$PRODUCT_LOG"
product_rc=${PIPESTATUS[0]}
set -e
[[ $product_rc -eq 0 ]] || fail "API Product reconciler exited with $product_rc; inspect $PRODUCT_LOG"

STATE_JSON="$("${COMPOSE[@]}" run --rm --entrypoint sh apim-bootstrapper -c 'cat /workspace/state/api-product-bundles.json' 2>/dev/null)"
if ! jq -e '.products[]? | select(.id == "secure-mobile-transactions") | (.nativeApiProduct == true and (.status == "CREATED" or .status == "UPDATED"))' <<<"$STATE_JSON" >/dev/null; then
  printf '%s\n' "$STATE_JSON" | jq '.products[]? | select(.id == "secure-mobile-transactions")' >&2 || true
  printf '\nLast API Product reconciler messages:\n' >&2
  tail -80 "$PRODUCT_LOG" >&2 || true
  fail 'SecureMobileTransactionsProduct was not created. The state above now contains the actual APIM failure.'
fi

PRODUCT_ID="$(jq -r '.products[]? | select(.id == "secure-mobile-transactions") | .apiProductId // empty' <<<"$STATE_JSON")"
[[ -n "$PRODUCT_ID" ]] || fail 'Commercial API Product state did not contain an apiProductId'
info "Native API Product exists: $PRODUCT_ID"

info 'Publishing, deploying and enriching the API Product through the repository Developer Experience reconciler'
"${COMPOSE[@]}" run --rm --entrypoint node apim-bootstrapper src/developer-experience-setup.js

info 'Completing Service Catalog registration, partner subscription and operational usage seeding'
"${COMPOSE[@]}" run --rm --entrypoint node apim-bootstrapper src/commercial-experience-setup.js

info 'Commercial API Product bootstrap completed'
info 'Next command: bash scripts/verify-commercial-plan-usage.sh'
