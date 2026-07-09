#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

INSTALLER="fix-final-oauth-runtime-convergence.sh"
CONTEXT_XML="services/wso2-mi/synapse-configs/default/sequences/SubscriberAuthorizationContextSequence.xml"

fail() {
  printf '[oauth-final-validation-fix][FAIL] %s\n' "$*" >&2
  exit 1
}

[[ -f "$INSTALLER" ]] ||
  fail "Missing $INSTALLER"

[[ -f "$CONTEXT_XML" ]] ||
  fail "Missing $CONTEXT_XML"

backup="${INSTALLER}.before-validation-check-fix.$(date +%Y%m%d-%H%M%S)"
cp "$INSTALLER" "$backup"

python3 - "$INSTALLER" "$CONTEXT_XML" <<'PY'
from pathlib import Path
import re
import sys

installer_path = Path(sys.argv[1])
context_path = Path(sys.argv[2])

installer = installer_path.read_text(encoding="utf-8")
context = context_path.read_text(encoding="utf-8")

claim_uri = "http://wso2.org/claims/enduser"

if claim_uri not in context:
    raise SystemExit(
        "[oauth-final-validation-fix][FAIL] "
        "The end-user claim URI is genuinely absent from the MI sequence."
    )

# Confirm that enduser is evaluated before the fallback subject claim.
enduser_position = context.find(claim_uri)
subject_position = context.find("claims.sub")

if subject_position < 0:
    raise SystemExit(
        "[oauth-final-validation-fix][FAIL] "
        "Could not find the claims.sub fallback."
    )

if enduser_position > subject_position:
    raise SystemExit(
        "[oauth-final-validation-fix][FAIL] "
        "The end-user claim appears after claims.sub; preference is incorrect."
    )

old_assertion = re.compile(
    r'''grep\s+-Fq\s*\\?\s*
        "claims\['http://wso2\.org/claims/enduser'\]"\s*\\?\s*
        "\$CONTEXT_XML"\s*\|\|\s*
        fail\s*\\?\s*
        "End-user claim preference was not installed\."
    ''',
    re.VERBOSE | re.MULTILINE,
)

new_assertion = r'''python3 - "$CONTEXT_XML" <<'CLAIM_CHECK'
from pathlib import Path
import sys

context = Path(sys.argv[1]).read_text(encoding="utf-8")

claim_uri = "http://wso2.org/claims/enduser"

if claim_uri not in context:
    raise SystemExit(
        "[oauth-final-runtime-fix][FAIL] "
        "End-user claim preference was not installed."
    )

if context.find(claim_uri) > context.find("claims.sub"):
    raise SystemExit(
        "[oauth-final-runtime-fix][FAIL] "
        "End-user claim is not preferred over claims.sub."
    )

print(
    "[oauth-final-runtime-fix] "
    "End-user claim preference validated."
)
CLAIM_CHECK'''

updated, count = old_assertion.subn(
    new_assertion,
    installer,
    count=1,
)

if count == 0:
    # Support rerunning this repair.
    if "End-user claim preference validated." in installer:
        updated = installer
        print(
            "[oauth-final-validation-fix] "
            "Semantic validation is already installed."
        )
    else:
        print(
            "[oauth-final-validation-fix][FAIL] "
            "Could not locate the defective exact-string assertion.",
            file=sys.stderr,
        )

        for number, line in enumerate(
            installer.splitlines(),
            start=1,
        ):
            if (
                "enduser" in line
                or "End-user claim preference" in line
            ):
                print(
                    f"{number}: {line}",
                    file=sys.stderr,
                )

        raise SystemExit(1)

installer_path.write_text(updated, encoding="utf-8")

print(
    "[oauth-final-validation-fix] "
    "Replaced exact formatting check with semantic claim-order validation."
)
PY

bash -n "$INSTALLER"

echo
echo "[oauth-final-validation-fix] Current MI claim references:"

grep -n \
  -E 'enduser|preferred_username|claims\.sub' \
  "$CONTEXT_XML"

echo
echo "[oauth-final-validation-fix] Backup:"
echo "  $backup"
echo
echo "[oauth-final-validation-fix] Validation patch completed."
