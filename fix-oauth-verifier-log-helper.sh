#!/usr/bin/env bash
set -Eeuo pipefail

cd "${1:-$PWD}"

VERIFY="scripts/verify-oauth-consent-risk-controls.sh"

fail() {
  printf '[verifier-log-fix][FAIL] %s\n' "$*" >&2
  exit 1
}

[[ -f "$VERIFY" ]] ||
  fail "Missing $VERIFY"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup="${VERIFY}.before-log-helper.${timestamp}"

cp "$VERIFY" "$backup"

python3 - "$VERIFY" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

if re.search(r"(?m)^log\(\)[ \t]*\{", text):
    print(
        "[verifier-log-fix] "
        "Verifier-local log() helper already exists."
    )
    raise SystemExit(0)

helper = r'''
log() {
  printf '[oauth-controls-verify] %s\n' "$*"
}
'''

lines = text.splitlines(keepends=True)

insert_index = None

for index, line in enumerate(lines):
    if re.match(
        r"^[ \t]*set[ \t]+-[A-Za-z]*e[A-Za-z]*",
        line,
    ):
        insert_index = index + 1
        break

if insert_index is None:
    if lines and lines[0].startswith("#!"):
        insert_index = 1
    else:
        insert_index = 0

lines.insert(
    insert_index,
    "\n" + helper.strip("\n") + "\n\n",
)

path.write_text(
    "".join(lines),
    encoding="utf-8",
)

print(
    "[verifier-log-fix] "
    "Installed verifier-local log() helper."
)
PY

if ! bash -n "$VERIFY"; then
  cp "$backup" "$VERIFY"
  fail "Verifier syntax failed; original restored."
fi

grep -q '^log()' "$VERIFY" ||
  fail "log() helper was not installed."

echo
echo "[verifier-log-fix] Installed helper:"
grep -n -A 3 '^log()' "$VERIFY"

echo
echo "[verifier-log-fix] Backup:"
echo "  $backup"

echo
echo "[verifier-log-fix] Running verifier directly."

bash "$VERIFY"
