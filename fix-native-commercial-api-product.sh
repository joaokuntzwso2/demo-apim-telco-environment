#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

info() {
  printf '[commercial-product-fix] %s\n' "$*"
}

for command in python3 node docker jq; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done

python3 <<'PATCHPY'
from pathlib import Path
import json
import re

setup_path = Path('services/apim-bootstrapper/src/api-product-bundles-setup.js')
if not setup_path.is_file():
    raise SystemExit(f'Missing required file: {setup_path}')

text = setup_path.read_text()
match = re.search(r"const NATIVE_PRODUCT_BUNDLE_IDS = new Set\(\[(.*?)\]\);", text, re.S)
if not match:
    raise SystemExit('Could not locate NATIVE_PRODUCT_BUNDLE_IDS in api-product-bundles-setup.js')

bundle_id = 'secure-mobile-transactions'
items = match.group(1)
if f"'{bundle_id}'" in items or f'"{bundle_id}"' in items:
    print(f'[commercial-product-fix] native API Product allowlist already contains {bundle_id}')
else:
    updated = items.rstrip()
    if updated and not updated.endswith(','):
        updated += ','
    updated += f" '{bundle_id}' "
    text = text[:match.start(1)] + updated + text[match.end(1):]
    setup_path.write_text(text)
    print(f'[commercial-product-fix] added {bundle_id} to NATIVE_PRODUCT_BUNDLE_IDS')

bundle_path = Path('artifacts/apim-admin/api-product-bundles.json')
if not bundle_path.is_file():
    raise SystemExit(f'Missing required file: {bundle_path}')

bundles = json.loads(bundle_path.read_text())
bundle = next((item for item in bundles if item.get('id') == bundle_id), None)
if not bundle:
    raise SystemExit(f'Bundle {bundle_id} is absent from {bundle_path}')
if bundle.get('apim', {}).get('apiProductName') != 'SecureMobileTransactionsProduct':
    raise SystemExit('Secure Mobile Transactions bundle has an unexpected apiProductName')
if 'SecureMobileTransactionsCommercialAPI' not in bundle.get('apis', []):
    raise SystemExit('Secure Mobile Transactions bundle does not reference SecureMobileTransactionsCommercialAPI')
print('[commercial-product-fix] commercial bundle metadata is present and valid')

for installer_name in (
    'install-secure-mobile-commercial-flow.sh',
    'install-secure-mobile-commercial-flow-v2.sh',
    'install-secure-mobile-commercial-flow-v3.sh',
):
    installer = Path(installer_name)
    if not installer.is_file():
        continue
    installer_text = installer.read_text()
    if "product_setup_path = Path('services/apim-bootstrapper/src/api-product-bundles-setup.js')" in installer_text:
        print(f'[commercial-product-fix] installer already reconciles native product allowlist: {installer}')
        continue
    needle = "from pathlib import Path\nimport json\n\npackage_path = Path('services/apim-bootstrapper/package.json')"
    if needle not in installer_text:
        print(f'[commercial-product-fix] skipped installer with unknown structure: {installer}')
        continue
    insertion = '''from pathlib import Path
import json
import re

product_setup_path = Path('services/apim-bootstrapper/src/api-product-bundles-setup.js')
product_setup = product_setup_path.read_text()
match = re.search(r"const NATIVE_PRODUCT_BUNDLE_IDS = new Set\\(\\[(.*?)\\]\\);", product_setup, re.S)
if not match:
    raise SystemExit('Could not locate NATIVE_PRODUCT_BUNDLE_IDS in api-product-bundles-setup.js')
if "'secure-mobile-transactions'" not in match.group(1) and '"secure-mobile-transactions"' not in match.group(1):
    updated_items = match.group(1).rstrip()
    if updated_items and not updated_items.rstrip().endswith(','):
        updated_items += ','
    updated_items += " 'secure-mobile-transactions' "
    product_setup = product_setup[:match.start(1)] + updated_items + product_setup[match.end(1):]
    product_setup_path.write_text(product_setup)

package_path = Path('services/apim-bootstrapper/package.json')'''
    installer.write_text(installer_text.replace(needle, insertion, 1))
    installer.chmod(0o755)
    print(f'[commercial-product-fix] reconciled installer: {installer}')
PATCHPY

node --check services/apim-bootstrapper/src/api-product-bundles-setup.js
node --check services/apim-bootstrapper/src/commercial-experience-setup.js
jq -e 'any(.[]; .id == "secure-mobile-transactions" and .apim.apiProductName == "SecureMobileTransactionsProduct")' \
  artifacts/apim-admin/api-product-bundles.json >/dev/null

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

info 'Creating or updating the native Secure Mobile Transactions API Product'
"${COMPOSE[@]}" run --rm --entrypoint node apim-bootstrapper src/api-product-bundles-setup.js

info 'Completing documents, Service Catalog, subscription and runtime seeding'
"${COMPOSE[@]}" run --rm --entrypoint node apim-bootstrapper src/commercial-experience-setup.js

info 'Native API Product creation and commercial experience completed'
info 'Next command: bash scripts/verify-commercial-plan-usage.sh'
