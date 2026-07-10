#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="${1:-$(pwd)}"
cd "$ROOT_DIR"

RESET_SCRIPT="scripts/reset-with-telco-ai.sh"
STATIC_VERIFY="scripts/verify-prepaid-reset-wiring.sh"

SERVER_JS="services/commercial-meter-store/src/server.js"
EXT_JS="services/commercial-meter-store/src/prepaid-commercial-extension.js"

COMMERCIAL_API="services/wso2-mi/synapse-configs/default/api/SecureMobileTransactionsCommercialAPI.xml"
PREAUTH_SEQUENCE="services/wso2-mi/synapse-configs/default/sequences/CommercialPrepaidPreAuthorizationSequence.xml"

COMMERCIAL_VERIFY="scripts/verify-commercial-plan-usage.sh"
PREPAID_VERIFY="scripts/verify-prepaid-reconciliation.sh"
PREPAID_DEMO="scripts/demo-prepaid-reconciliation.sh"

fail() {
  printf '[integrate-prepaid-reset][FAIL] %s\n' "$*" >&2
  exit 1
}

ok() {
  printf '[integrate-prepaid-reset][OK] %s\n' "$*"
}

[[ -f docker-compose.yml ]] ||
  fail "Run this script from the repository root."

REQUIRED_FILES=(
  "$RESET_SCRIPT"
  "$SERVER_JS"
  "$EXT_JS"
  "$COMMERCIAL_API"
  "$PREAUTH_SEQUENCE"
  "$COMMERCIAL_VERIFY"
  "$PREPAID_VERIFY"
  "$PREPAID_DEMO"
  "docker-compose.commercial.yml"
  "docker-compose.ai.yml"
)

for file in "${REQUIRED_FILES[@]}"; do
  [[ -s "$file" ]] || fail "Missing or empty file: $file"
done

for command in python3 node jq curl docker; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "$command is required."
done

docker compose version >/dev/null 2>&1 ||
  fail "Docker Compose v2 is required."

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".prepaid-reconciliation-backups/reset-integration-$STAMP"

mkdir -p "$BACKUP_DIR/$(dirname "$RESET_SCRIPT")"
mkdir -p "$BACKUP_DIR/$(dirname "$PREAUTH_SEQUENCE")"

cp "$RESET_SCRIPT" "$BACKUP_DIR/$RESET_SCRIPT"
cp "$PREAUTH_SEQUENCE" "$BACKUP_DIR/$PREAUTH_SEQUENCE"

if [[ -f "$STATIC_VERIFY" ]]; then
  mkdir -p "$BACKUP_DIR/$(dirname "$STATIC_VERIFY")"
  cp "$STATIC_VERIFY" "$BACKUP_DIR/$STATIC_VERIFY"
else
  printf '%s\n' "$STATIC_VERIFY" > "$BACKUP_DIR/created-files.txt"
fi

ok "Backup created at $BACKUP_DIR"

python3 - \
  "$PREAUTH_SEQUENCE" \
  "$RESET_SCRIPT" <<'PY'
from pathlib import Path
import re
import sys

sequence_path = Path(sys.argv[1])
reset_path = Path(sys.argv[2])

# ---------------------------------------------------------------------------
# 1. Guarantee valid JSON serialization for the controlled HTTP 402 response.
# ---------------------------------------------------------------------------

sequence = sequence_path.read_text(encoding="utf-8")

problem_formatter = re.compile(
    r'<property\b'
    r'(?=[^>]*\bname="messageType")'
    r'(?=[^>]*\bvalue="application/problem\+json")'
    r'[^>]*/>',
    re.DOTALL,
)

replacement = """<property name="messageType"
                              value="application/json"
                              scope="axis2"
                              type="STRING"/>
                    <property name="ContentType"
                              value="application/problem+json"
                              scope="axis2"
                              type="STRING"/>"""

sequence, replacements = problem_formatter.subn(
    replacement,
    sequence,
    count=1,
)

already_fixed = (
    'name="messageType"' in sequence
    and 'value="application/json"' in sequence
    and 'name="ContentType"' in sequence
    and 'value="application/problem+json"' in sequence
)

if replacements == 0 and not already_fixed:
    raise SystemExit(
        "Could not find or validate the prepaid HTTP 402 formatter."
    )

sequence_path.write_text(sequence, encoding="utf-8")

# ---------------------------------------------------------------------------
# 2. Integrate static validation and runtime verifications into the reset.
# ---------------------------------------------------------------------------

reset = reset_path.read_text(encoding="utf-8")

preflight_marker = "# BEGIN PREPAID RECONCILIATION RESET PREFLIGHT"

preflight_block = r'''
# BEGIN PREPAID RECONCILIATION RESET PREFLIGHT
echo "[telco-ai-reset] Validating prepaid and reconciliation wiring."
bash scripts/verify-prepaid-reset-wiring.sh
pass "Prepaid and reconciliation reset wiring"
# END PREPAID RECONCILIATION RESET PREFLIGHT

'''

if preflight_marker not in reset:
    anchor = 'echo "[telco-ai-reset] Validating complete Compose topology."'

    if anchor not in reset:
        raise SystemExit(
            "Could not locate the Compose-validation anchor in "
            "reset-with-telco-ai.sh"
        )

    reset = reset.replace(
        anchor,
        preflight_block + anchor,
        1,
    )

readiness_marker = "# BEGIN PREPAID RECONCILIATION RUNTIME READINESS"

readiness_block = r'''
# BEGIN PREPAID RECONCILIATION RUNTIME READINESS
wait_for_url \
  "Primary commercial meter store" \
  "http://127.0.0.1:18086/health" \
  120 \
  3

wait_for_url \
  "Secondary commercial meter store" \
  "http://127.0.0.1:18087/health" \
  120 \
  3

wait_for_url \
  "MI commercial API" \
  "http://127.0.0.1:8290/secure-mobile-transactions/v1/health" \
  120 \
  3
# END PREPAID RECONCILIATION RUNTIME READINESS

'''

if readiness_marker not in reset:
    anchor = (
        'echo "[telco-ai-reset] Running the complete APIM bootstrap chain."'
    )

    if anchor not in reset:
        raise SystemExit(
            "Could not locate the APIM-bootstrap anchor in "
            "reset-with-telco-ai.sh"
        )

    reset = reset.replace(
        anchor,
        readiness_block + anchor,
        1,
    )

verification_marker = "# BEGIN COMMERCIAL AND PREPAID VERIFICATION"

verification_block = r'''
# BEGIN COMMERCIAL AND PREPAID VERIFICATION
echo "[telco-ai-reset] Verifying the existing commercial implementation."
bash scripts/verify-commercial-plan-usage.sh
pass "Existing commercial plans and usage metering"

echo "[telco-ai-reset] Verifying prepaid exhaustion and reconciliation."
bash scripts/verify-prepaid-reconciliation.sh
pass "Prepaid credit exhaustion and commercial reconciliation"
# END COMMERCIAL AND PREPAID VERIFICATION

'''

if verification_marker not in reset:
    anchor = 'echo "[telco-ai-reset] Running complete AI verification."'

    if anchor not in reset:
        raise SystemExit(
            "Could not locate the AI-verification anchor in "
            "reset-with-telco-ai.sh"
        )

    reset = reset.replace(
        anchor,
        verification_block + anchor,
        1,
    )

reset_path.write_text(reset, encoding="utf-8")
PY

cat > "$STATIC_VERIFY" <<'VERIFY'
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

for file in \
  "$RESET_SCRIPT" \
  "$SERVER_JS" \
  "$EXT_JS" \
  "$COMMERCIAL_API" \
  "$PREAUTH_SEQUENCE" \
  "$COMMERCIAL_VERIFY" \
  "$PREPAID_VERIFY" \
  "$PREPAID_DEMO" \
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
VERIFY

chmod +x \
  "$STATIC_VERIFY" \
  "$RESET_SCRIPT"

node --check "$SERVER_JS"
node --check "$EXT_JS"

bash -n \
  "$RESET_SCRIPT" \
  "$STATIC_VERIFY" \
  "$COMMERCIAL_VERIFY" \
  "$PREPAID_VERIFY"

python3 - \
  "$COMMERCIAL_API" \
  "$PREAUTH_SEQUENCE" <<'PY'
from xml.etree import ElementTree as ET
import sys

for filename in sys.argv[1:]:
    ET.parse(filename)
PY

bash "$STATIC_VERIFY"

ROLLBACK_SCRIPT="$BACKUP_DIR/rollback.sh"

cat > "$ROLLBACK_SCRIPT" <<ROLLBACK
#!/usr/bin/env bash
set -Eeuo pipefail

cd "$ROOT_DIR"

cp "$BACKUP_DIR/$RESET_SCRIPT" "$RESET_SCRIPT"
cp "$BACKUP_DIR/$PREAUTH_SEQUENCE" "$PREAUTH_SEQUENCE"

if [[ -f "$BACKUP_DIR/$STATIC_VERIFY" ]]; then
  cp "$BACKUP_DIR/$STATIC_VERIFY" "$STATIC_VERIFY"
else
  rm -f "$STATIC_VERIFY"
fi

printf '[rollback][PASS] Restored reset integration from %s\n' \
  "$BACKUP_DIR"
ROLLBACK

chmod +x "$ROLLBACK_SCRIPT"

ok "The complete AI reset now includes commercial and prepaid checks."
printf '\nBackup:  %s\n' "$BACKUP_DIR"
printf 'Rollback: bash %s\n' "$ROLLBACK_SCRIPT"
