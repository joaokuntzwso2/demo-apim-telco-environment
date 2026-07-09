#!/usr/bin/env bash
set -Eeuo pipefail

cd "${1:-$PWD}"

VERIFY="scripts/verify-oauth-consent-risk-controls.sh"
PATCHER="fix-oauth-expiry-test-boundary-safe.sh"

fail() {
  printf '[expiry-verifier-repair][FAIL] %s\n' "$*" >&2
  exit 1
}

[[ -f "$VERIFY" ]] ||
  fail "Missing $VERIFY"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/expiry-verifier-repair-${timestamp}"

mkdir -p "$backup_dir"
cp "$VERIFY" "$backup_dir/verify-oauth-consent-risk-controls.sh"

if [[ -f "$PATCHER" ]]; then
  cp "$PATCHER" "$backup_dir/fix-oauth-expiry-test-boundary-safe.sh"
fi

python3 - "$VERIFY" "$PATCHER" <<'PY'
from pathlib import Path
import re
import sys

verify_path = Path(sys.argv[1])
patcher_path = Path(sys.argv[2])

verify = verify_path.read_text(encoding="utf-8")

# Fix the multiline parameter expansion inserted by the previous patch.
bad_default = re.compile(
    r'''
    short_token_url="
    \$\{
    \s*OAUTH_SHORT_TOKEN_URL
    :-
    \s*https://127\.0\.0\.1:8243/token
    \s*
    \}"
    ''',
    re.VERBOSE,
)

verify, count = bad_default.subn(
    'short_token_url="${OAUTH_SHORT_TOKEN_URL:-https://127.0.0.1:8243/token}"',
    verify,
)

if count:
    print(
        "[expiry-verifier-repair] "
        "Corrected malformed OAUTH_SHORT_TOKEN_URL default."
    )
elif (
    'short_token_url="${OAUTH_SHORT_TOKEN_URL:-'
    'https://127.0.0.1:8243/token}"'
    in verify
):
    print(
        "[expiry-verifier-repair] "
        "OAUTH_SHORT_TOKEN_URL default is already correct."
    )
else:
    raise SystemExit(
        "[expiry-verifier-repair][FAIL] "
        "Could not locate the short_token_url assignment."
    )

required_markers = (
    "validity_period=2",
    "Extracting the short-lived OAuth credentials from bootstrap state.",
    "Direct two-second OAuth token issued",
)

missing = [
    marker
    for marker in required_markers
    if marker not in verify
]

if missing:
    raise SystemExit(
        "[expiry-verifier-repair][FAIL] "
        "The expiry section is incomplete; missing: "
        + ", ".join(missing)
    )

verify_path.write_text(
    verify,
    encoding="utf-8",
)

# Correct the patcher's false-negative validation so rerunning it is safe.
if patcher_path.exists():
    patcher = patcher_path.read_text(encoding="utf-8")

    patcher = patcher.replace(
        '"extracting the short-lived OAuth credentials"',
        '"Extracting the short-lived OAuth credentials"',
    )

    patcher_path.write_text(
        patcher,
        encoding="utf-8",
    )

    print(
        "[expiry-verifier-repair] "
        "Corrected the patcher's case-sensitive validation."
    )
PY

bash -n "$VERIFY" ||
  {
    cp \
      "$backup_dir/verify-oauth-consent-risk-controls.sh" \
      "$VERIFY"

    fail "Verifier syntax is invalid; backup restored."
  }

if [[ -f "$PATCHER" ]]; then
  bash -n "$PATCHER" ||
    fail "The expiry patcher has invalid syntax."
fi

grep -Fq \
  'validity_period=2' \
  "$VERIFY" ||
  fail "validity_period=2 is absent."

grep -Fq \
  'Extracting the short-lived OAuth credentials from bootstrap state.' \
  "$VERIFY" ||
  fail "State credential discovery is absent."

grep -Fq \
  'short_token_url="${OAUTH_SHORT_TOKEN_URL:-https://127.0.0.1:8243/token}"' \
  "$VERIFY" ||
  fail "The token endpoint default remains malformed."

echo
echo "[expiry-verifier-repair] Installed token request:"
grep -n \
  -A 9 \
  -B 5 \
  'validity_period=2' \
  "$VERIFY"

echo
echo "[expiry-verifier-repair] Backup:"
echo "  $backup_dir"
echo
echo "[expiry-verifier-repair] Running verifier directly."

bash "$VERIFY"
