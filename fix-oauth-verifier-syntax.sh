#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

VERIFY_SCRIPT="scripts/verify-oauth-consent-risk-controls.sh"
CATALOG_SCRIPT="scripts/register-oauth-business-control-service-catalog.sh"

fail() {
  printf '[oauth-verifier-fix][FAIL] %s\n' "$*" >&2
  exit 1
}

[[ -f "$VERIFY_SCRIPT" ]] || fail "Missing $VERIFY_SCRIPT"
[[ -f "$CATALOG_SCRIPT" ]] || fail "Missing $CATALOG_SCRIPT"

for command in python3 jq bash; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Missing required command: $command"
done

BACKUP="${VERIFY_SCRIPT}.before-scope-role-fix.$(date +%Y%m%d-%H%M%S)"
cp "$VERIFY_SCRIPT" "$BACKUP"

echo "[oauth-verifier-fix] Backup written to $BACKUP"

python3 - "$VERIFY_SCRIPT" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

# Replace the entire scope-verification section rather than attempting to
# repair only one malformed quote.
#
# The replacement supports both possible APIM response shapes:
#
# Flat:
#   {
#     "key": "number-verification:read",
#     "roles": ["telco_partner"]
#   }
#
# Nested APIScope:
#   {
#     "scope": {
#       "name": "number-verification:read",
#       "bindings": ["telco_partner"]
#     }
#   }
#
# Role comparisons normalize an optional Internal/ prefix because WSO2 may
# expose user-store-qualified role names in some responses and local role
# names in others.

pattern = re.compile(
    r"(?ms)^  for scope in \\\n.*?^  deployments="
)

replacement = r'''  for scope in \
    number-verification:read \
    sim-swap:read \
    device-location:verify \
    qod:request \
    commercial-usage:read
  do
    if jq -e --arg scope "${scope}" '
      def scope_name:
        (.key // .name // .scope.name // .scope.key // "");

      any(
        .scopes[]?;
        scope_name == $scope
      )
    ' <<<"${api}" >/dev/null; then
      pass "Scope exists: ${scope}"
    else
      fail "Scope missing: ${scope}"
    fi
  done

  for scope_role in \
    'number-verification:read|telco_partner' \
    'number-verification:read|telco_operations' \
    'number-verification:read|telco_platform_admin' \
    'sim-swap:read|telco_partner' \
    'sim-swap:read|telco_operations' \
    'device-location:verify|telco_partner' \
    'device-location:verify|telco_operations' \
    'qod:request|telco_partner' \
    'qod:request|telco_operations' \
    'commercial-usage:read|telco_partner' \
    'commercial-usage:read|telco_operations' \
    'commercial-usage:read|telco_product_manager' \
    'commercial-usage:read|telco_platform_admin'
  do
    scope_key="${scope_role%%|*}"
    expected_role="${scope_role#*|}"

    if jq -e \
      --arg scope "${scope_key}" \
      --arg role "${expected_role}" '
        def scope_name:
          (.key // .name // .scope.name // .scope.key // "");

        def normalized_bindings:
          (
            .roles //
            .bindings //
            .scope.bindings //
            .scope.roles //
            []
          )
          | if type == "string" then split(",") else . end
          | map(
              tostring
              | gsub("^\\s+|\\s+$"; "")
              | sub("^Internal/"; "")
            );

        any(
          .scopes[]?;
          scope_name == $scope and
          ((normalized_bindings | index($role)) != null)
        )
      ' <<<"${api}" >/dev/null; then
      pass "Scope role binding exists: ${scope_key} -> ${expected_role}."
    else
      fail "Scope role binding missing: ${scope_key} -> ${expected_role}."
    fi
  done

  deployments='''

updated, count = pattern.subn(
    lambda _match: replacement,
    text,
    count=1,
)

if count != 1:
    print(
        "[oauth-verifier-fix][FAIL] "
        "Could not locate the scope-verification section.",
        file=sys.stderr,
    )

    print(
        "[oauth-verifier-fix] Relevant lines in the current file:",
        file=sys.stderr,
    )

    for number, line in enumerate(text.splitlines(), start=1):
        if (
            "Internal/" in line
            or "for scope" in line
            or "deployments=" in line
        ):
            print(f"{number}: {line}", file=sys.stderr)

    raise SystemExit(1)

path.write_text(updated, encoding="utf-8")

print(
    "[oauth-verifier-fix] "
    f"Replaced the malformed scope-verification section in {path}"
)
PY

echo "[oauth-verifier-fix] Running static shell validation."

bash -n "$VERIFY_SCRIPT"
bash -n "$CATALOG_SCRIPT"

echo "[oauth-verifier-fix] Shell syntax validation passed."

echo
echo "[oauth-verifier-fix] Patched section:"
grep -n -A 80 -B 5 \
  'for scope in' \
  "$VERIFY_SCRIPT" |
  head -n 100

if [[ "${PATCH_ONLY:-0}" == "1" ]]; then
  echo
  echo "[oauth-verifier-fix] PATCH_ONLY=1; runtime execution skipped."
  exit 0
fi

echo
echo "[oauth-verifier-fix] Registering the MI authorization service."
bash "$CATALOG_SCRIPT"

echo
echo "[oauth-verifier-fix] Running complete OAuth verification."
bash "$VERIFY_SCRIPT"
