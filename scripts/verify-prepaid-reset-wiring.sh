#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"

cd "$ROOT_DIR"

pass() {
  printf '[prepaid-reset-wiring][PASS] %s\n' "$*"
}

fail() {
  printf '[prepaid-reset-wiring][FAIL] %s\n' "$*" >&2
  exit 1
}

require_file() {
  local file="$1"

  [[ -s "$file" ]] ||
    fail "Missing or empty file: $file"
}

require_text() {
  local file="$1"
  local text="$2"

  grep -Fq -- "$text" "$file" ||
    fail "$file does not contain: $text"
}

RESET_SCRIPT="scripts/reset-with-telco-ai.sh"
SERVER_JS="services/commercial-meter-store/src/server.js"
EXT_JS="services/commercial-meter-store/src/prepaid-commercial-extension.js"

COMMERCIAL_API="services/wso2-mi/synapse-configs/default/api/SecureMobileTransactionsCommercialAPI.xml"

PREAUTH_SEQUENCE="services/wso2-mi/synapse-configs/default/sequences/CommercialPrepaidPreAuthorizationSequence.xml"

COMMERCIAL_VERIFY="scripts/verify-commercial-plan-usage.sh"
PREPAID_VERIFY="scripts/verify-prepaid-reconciliation.sh"
PREPAID_DEMO="scripts/demo-prepaid-reconciliation.sh"
PREPAID_GRAFANA_VERIFY="scripts/verify-prepaid-grafana.sh"
PREPAID_GRAFANA_DASHBOARD="observability/grafana/dashboards/prepaid-wallet-reconciliation.json"

for file in \
  "$RESET_SCRIPT" \
  "$SERVER_JS" \
  "$EXT_JS" \
  "$COMMERCIAL_API" \
  "$PREAUTH_SEQUENCE" \
  "$COMMERCIAL_VERIFY" \
  "$PREPAID_VERIFY" \
  "$PREPAID_DEMO" \
  "$PREPAID_GRAFANA_VERIFY" \
  "$PREPAID_GRAFANA_DASHBOARD" \
  docker-compose.commercial.yml
do
  require_file "$file"
done

require_text \
  "$SERVER_JS" \
  "prepaid-commercial-extension"

require_text \
  "$PREAUTH_SEQUENCE" \
  'value="application/json"'

require_text \
  "$PREAUTH_SEQUENCE" \
  'name="ContentType"'

require_text \
  "$PREAUTH_SEQUENCE" \
  'value="application/problem+json"'

HOOK_COUNT="$(
  grep -Fc \
    'CommercialPrepaidPreAuthorizationSequence' \
    "$COMMERCIAL_API"
)"

[[ "$HOOK_COUNT" -eq 3 ]] ||
  fail \
    "Expected three prepaid preauthorization hooks; found $HOOK_COUNT."

require_text \
  "$RESET_SCRIPT" \
  "docker-compose.commercial.yml"

require_text \
  "$RESET_SCRIPT" \
  "verify-commercial-plan-usage.sh"

require_text \
  "$RESET_SCRIPT" \
  "verify-prepaid-reconciliation.sh"

require_text \
  "$RESET_SCRIPT" \
  "http://127.0.0.1:18086/health"

require_text \
  "$RESET_SCRIPT" \
  "http://127.0.0.1:18087/health"

require_text \
  "$RESET_SCRIPT" \
  "secure-mobile-transactions/v1/health"

require_text \
  "$RESET_SCRIPT" \
  "verify-prepaid-grafana.sh"

require_text \
  "$EXT_JS" \
  "telco_prepaid_wallet_balance"

require_text \
  "observability/prometheus/prometheus.yml" \
  "commercial-meter-store-primary:8086"

node --check "$SERVER_JS"
node --check "$EXT_JS"

bash -n \
  "$RESET_SCRIPT" \
  "$COMMERCIAL_VERIFY" \
  "$PREPAID_VERIFY" \
  "$PREPAID_DEMO"

python3 - \
  "$COMMERCIAL_API" \
  "$PREAUTH_SEQUENCE" <<'PY'
from pathlib import Path
from xml.etree import ElementTree as ET
import sys

for filename in sys.argv[1:]:
    ET.parse(Path(filename))

print(
    "[prepaid-reset-wiring][PASS] "
    "Commercial API and prepaid sequence XML are well formed"
)
PY

ENV_FILE="${TELCO_AI_ENV_FILE:-.env.ai.local}"

COMPOSE_VALIDATION=(
  docker compose
)

if [[ -f "$ENV_FILE" ]]; then
  COMPOSE_VALIDATION+=(
    --env-file "$ENV_FILE"
  )
fi

COMPOSE_VALIDATION+=(
  -f docker-compose.yml
  -f docker-compose.mi.yml
  -f docker-compose.commercial.yml
  config
  --quiet
)

"${COMPOSE_VALIDATION[@]}"

pass "Commercial Compose overlay is valid"
pass "Prepaid reset integration is complete"
