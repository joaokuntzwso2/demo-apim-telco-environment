#!/usr/bin/env bash
set -Eeuo pipefail

cd "${1:-$PWD}"

TARGET="scripts/reconcile-oauth-control-plane.sh"

[[ -f "$TARGET" ]] || {
  echo "[oauth-history-fix][FAIL] Missing $TARGET" >&2
  exit 1
}

backup="${TARGET}.before-history-substitution-fix.$(date +%Y%m%d-%H%M%S)"
cp "$TARGET" "$backup"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

pattern = re.compile(
    r'''backup_file="\$\{\s*
        history_dir
        \s*\}/oauth-business-controls\.
        \$\(date\s+\+%Y%m%d-%H%M%S\)
        \.json"
    ''',
    re.VERBOSE | re.MULTILINE,
)

replacement = (
    'backup_file="${history_dir}/'
    'oauth-business-controls.$(date +%Y%m%d-%H%M%S).json"'
)

updated, count = pattern.subn(replacement, text, count=1)

if count != 1:
    # Allow the script to be rerun after it has already been repaired.
    if replacement in text:
        print("[oauth-history-fix] Assignment is already correct.")
        updated = text
    else:
        print(
            "[oauth-history-fix][FAIL] "
            "Could not locate the malformed backup_file assignment.",
            file=sys.stderr,
        )

        for number, line in enumerate(text.splitlines(), start=1):
            if "backup_file" in line or "history_dir" in line:
                print(f"{number}: {line}", file=sys.stderr)

        raise SystemExit(1)

# Detect any other parameter expansion that starts with `${` and then moves
# the variable name onto another line.
remaining = list(re.finditer(r'\$\{\s*\n', updated))

if remaining:
    print(
        "[oauth-history-fix][FAIL] "
        "Other malformed multiline parameter expansions remain:",
        file=sys.stderr,
    )

    lines = updated.splitlines()

    for match in remaining:
        line_number = updated.count("\n", 0, match.start()) + 1
        start = max(0, line_number - 2)
        end = min(len(lines), line_number + 3)

        for index in range(start, end):
            print(f"{index + 1}: {lines[index]}", file=sys.stderr)

        print("---", file=sys.stderr)

    raise SystemExit(1)

path.write_text(updated, encoding="utf-8")
print(f"[oauth-history-fix] Patched {path}")
PY

bash -n "$TARGET"

echo
echo "[oauth-history-fix] Corrected state backup assignment:"
grep -n -A 2 -B 2 'backup_file=' "$TARGET"

echo
echo "[oauth-history-fix] Backup: $backup"
