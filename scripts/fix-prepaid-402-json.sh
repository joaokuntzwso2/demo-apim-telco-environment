#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="${1:-$(pwd)}"
cd "$ROOT_DIR"

SEQ="services/wso2-mi/synapse-configs/default/sequences/CommercialPrepaidPreAuthorizationSequence.xml"
VERIFY="scripts/verify-prepaid-reconciliation.sh"

fail() {
  printf '[fix-prepaid-402][FAIL] %s\n' "$*" >&2
  exit 1
}

ok() {
  printf '[fix-prepaid-402][OK] %s\n' "$*"
}

[[ -f docker-compose.yml ]] || fail "Run this script from the repository root."
[[ -f "$SEQ" ]] || fail "Missing $SEQ"
[[ -f "$VERIFY" ]] || fail "Missing $VERIFY"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".prepaid-reconciliation-backups/fix-402-$STAMP"

mkdir -p \
  "$BACKUP_DIR/$(dirname "$SEQ")" \
  "$BACKUP_DIR/$(dirname "$VERIFY")"

cp "$SEQ" "$BACKUP_DIR/$SEQ"
cp "$VERIFY" "$BACKUP_DIR/$VERIFY"

ok "Backup created at $BACKUP_DIR"

python3 - "$SEQ" "$VERIFY" <<'PY'
from pathlib import Path
import sys

sequence_path = Path(sys.argv[1])
verify_path = Path(sys.argv[2])

sequence = sequence_path.read_text()

old_formatter = (
    '<property name="messageType" '
    'value="application/problem+json" '
    'scope="axis2" type="STRING"/>'
)

new_formatter = """<property name="messageType"
                              value="application/json"
                              scope="axis2"
                              type="STRING"/>
                    <property name="ContentType"
                              value="application/problem+json"
                              scope="axis2"
                              type="STRING"/>"""

if old_formatter in sequence:
    sequence = sequence.replace(old_formatter, new_formatter, 1)
elif (
    'name="messageType"' in sequence
    and 'value="application/json"' in sequence
    and 'name="ContentType"' in sequence
    and 'value="application/problem+json"' in sequence
):
    pass
else:
    raise SystemExit(
        "Could not locate the prepaid HTTP 402 formatter properties."
    )

sequence_path.write_text(sequence)

verify = verify_path.read_text()

old_trap = """trap 'rm -rf "$WORK_DIR"' EXIT"""

new_trap = """cleanup() {
  local rc=$?

  if [[ $rc -eq 0 ]]; then
    rm -rf "$WORK_DIR"
  else
    printf '[prepaid][DEBUG] Preserving diagnostic files in %s\\n' \
      "$WORK_DIR" >&2
  fi
}

trap cleanup EXIT"""

if old_trap in verify:
    verify = verify.replace(old_trap, new_trap, 1)

if "[prepaid][DEBUG] Raw HTTP 402 response body:" not in verify:
    start = verify.find(
        """jq -e '.code == "PREPAID_CREDIT_EXHAUSTED\""""
    )

    fail_line = "|| fail 'Exhaustion payload is incorrect'"
    fail_position = verify.find(fail_line, start)
    end = verify.find("\n", fail_position)

    if start < 0 or fail_position < 0:
        raise SystemExit(
            "Could not locate the prepaid exhaustion assertion."
        )

    if end < 0:
        end = len(verify)

    replacement = """if ! jq -e '.code == "PREPAID_CREDIT_EXHAUSTED" and .requiredAmount == 0.08 and .availableBalance == 0' \\
    "$WORK_DIR/exhausted.json" >/dev/null 2>&1; then
  printf '[prepaid][DEBUG] Raw HTTP 402 response body:\\n' >&2
  cat "$WORK_DIR/exhausted.json" >&2
  printf '\\n' >&2
  fail 'Exhaustion payload is incorrect or is not valid JSON'
fi"""

    verify = verify[:start] + replacement + verify[end:]

verify_path.write_text(verify)
PY

python3 - "$SEQ" <<'PY'
from xml.etree import ElementTree as ET
import sys

ET.parse(sys.argv[1])
PY

bash -n "$VERIFY"

ok "Prepaid 402 response now uses the JSON formatter."
ok "HTTP Content-Type remains application/problem+json."
ok "Verifier diagnostics improved."

printf '\nRollback commands:\n'
printf '  cp %q %q\n' "$BACKUP_DIR/$SEQ" "$SEQ"
printf '  cp %q %q\n' "$BACKUP_DIR/$VERIFY" "$VERIFY"
