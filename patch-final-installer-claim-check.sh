#!/usr/bin/env bash
set -Eeuo pipefail

cd "${1:-$PWD}"

INSTALLER="fix-final-oauth-runtime-convergence.sh"

[[ -f "$INSTALLER" ]] || {
  echo "[claim-check-patch][FAIL] Missing $INSTALLER" >&2
  exit 1
}

backup="${INSTALLER}.before-claim-check-patch.$(date +%Y%m%d-%H%M%S)"
cp "$INSTALLER" "$backup"

python3 - "$INSTALLER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()

needle = """claims['http://wso2.org/claims/enduser']"""

needle_index = next(
    (
        index
        for index, line in enumerate(lines)
        if needle in line
    ),
    None,
)

if needle_index is None:
    # Allow safe reruns.
    if any(
        "'http://wso2.org/claims/enduser'" in line
        and "grep -Fq" not in line
        for line in lines
    ):
        print(
            "[claim-check-patch] "
            "The formatting-independent check may already be installed."
        )
        raise SystemExit(0)

    raise SystemExit(
        "[claim-check-patch][FAIL] "
        "Could not find the obsolete exact-string assertion."
    )

start = needle_index

while start >= 0 and "grep -Fq" not in lines[start]:
    start -= 1

if start < 0:
    raise SystemExit(
        "[claim-check-patch][FAIL] "
        "Could not find the start of the grep assertion."
    )

end = needle_index

while (
    end < len(lines)
    and "End-user claim preference was not installed." not in lines[end]
):
    end += 1

if end >= len(lines):
    raise SystemExit(
        "[claim-check-patch][FAIL] "
        "Could not find the end of the assertion."
    )

replacement = [
    "grep -Fq \\",
    "  'http://wso2.org/claims/enduser' \\",
    '  "$CONTEXT_XML" ||',
    "  fail \\",
    '    "End-user claim preference was not installed."',
]

updated = (
    lines[:start]
    + replacement
    + lines[end + 1:]
)

path.write_text(
    "\n".join(updated) + "\n",
    encoding="utf-8",
)

print(
    "[claim-check-patch] "
    f"Replaced installer lines {start + 1}-{end + 1}."
)
PY

bash -n "$INSTALLER"

echo
echo "[claim-check-patch] New validation block:"

grep -n -A 5 -B 2 \
  "'http://wso2.org/claims/enduser'" \
  "$INSTALLER" |
  tail -n 10

echo
echo "[claim-check-patch] Backup:"
echo "  $backup"
echo
echo "[claim-check-patch] Patch completed successfully."
