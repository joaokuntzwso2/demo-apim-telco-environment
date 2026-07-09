#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

log() {
  printf '[revision-rotation-fix] %s\n' "$*"
}

fail() {
  printf '[revision-rotation-fix][FAIL] %s\n' "$*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 ||
  fail "python3 is required."

targets=(
  scripts/telco-demo-control.sh
  scripts/publish-observability-api.sh
)

for target in "${targets[@]}"; do
  [[ -f "$target" ]] ||
    fail "Required file is missing: $target"
done

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/revision-rotation-${timestamp}"
mkdir -p "$backup_dir"

for target in "${targets[@]}"; do
  cp "$target" "$backup_dir/$(basename "$target")"
done

log "Backups written under $backup_dir"

python3 - "${targets[@]}" <<'PY'
from pathlib import Path
import re
import sys

paths = [Path(value) for value in sys.argv[1:]]

# Match an APICtl API import through its local TLS flag. This works with both
# formatted scripts and this repository's compact/minified controller.
pattern = re.compile(
    r"(?P<head>"
    r"apictl\s+import\s+api\b"
    r"(?:(?!apictl\s+import\s+api).)*?"
    r")"
    r"(?P<tls>\s+-k\b)",
    re.DOTALL,
)

total_commands = 0
total_patched = 0

for path in paths:
    original = path.read_text(encoding="utf-8")
    file_commands = 0
    file_patched = 0

    def replace(match: re.Match[str]) -> str:
        nonlocal_file_state[0] += 1

        head = match.group("head")
        tls = match.group("tls")

        if "--rotate-revision" in head:
            return match.group(0)

        nonlocal_file_state[1] += 1
        return head.rstrip() + " --rotate-revision" + tls

    # Mutable counters are used because this callback executes inside re.sub.
    nonlocal_file_state = [0, 0]
    updated = pattern.sub(replace, original)

    file_commands, file_patched = nonlocal_file_state
    total_commands += file_commands
    total_patched += file_patched

    if file_commands == 0:
        print(
            f"[revision-rotation-fix] "
            f"No APICtl API import command found in {path}"
        )
        continue

    # Every matched API import must now rotate revisions.
    remaining_without_rotation = 0

    for match in pattern.finditer(updated):
        if "--rotate-revision" not in match.group("head"):
            remaining_without_rotation += 1

    if remaining_without_rotation:
        raise SystemExit(
            f"[revision-rotation-fix][FAIL] "
            f"{remaining_without_rotation} import command(s) in {path} "
            f"still lack --rotate-revision."
        )

    path.write_text(updated, encoding="utf-8")

    print(
        f"[revision-rotation-fix] {path}: "
        f"commands={file_commands}, newly-patched={file_patched}"
    )

if total_commands == 0:
    raise SystemExit(
        "[revision-rotation-fix][FAIL] "
        "No 'apictl import api' command was found in the target scripts."
    )

print(
    "[revision-rotation-fix] "
    f"Total imports={total_commands}, newly-patched={total_patched}"
)
PY

log "Validating Bash syntax"

for target in "${targets[@]}"; do
  if ! bash -n "$target"; then
    log "Syntax validation failed; restoring backups."

    for restore_target in "${targets[@]}"; do
      cp \
        "$backup_dir/$(basename "$restore_target")" \
        "$restore_target"
    done

    fail "Invalid Bash syntax was produced. Original files were restored."
  fi
done

log "Confirming revision rotation"

python3 - "${targets[@]}" <<'PY'
from pathlib import Path
import re
import sys

failed = False

for name in sys.argv[1:]:
    path = Path(name)
    text = path.read_text(encoding="utf-8")

    imports = [
        line.strip()
        for line in text.splitlines()
        if "apictl import api" in line
    ]

    # The controller can be minified into one long line, so also verify through
    # the complete file content.
    has_import = bool(re.search(r"apictl\s+import\s+api\b", text))
    has_rotation = bool(
        re.search(
            r"apictl\s+import\s+api\b.*?--rotate-revision",
            text,
            re.DOTALL,
        )
    )

    if has_import and not has_rotation:
        print(
            f"[revision-rotation-fix][FAIL] "
            f"{path} still has an unprotected import.",
            file=sys.stderr,
        )
        failed = True
    elif has_import:
        print(
            f"[revision-rotation-fix][PASS] "
            f"{path} uses --rotate-revision."
        )

if failed:
    raise SystemExit(1)
PY

cat <<EOF

[revision-rotation-fix] Installation completed.

The import now behaves as:

  apictl import api ... --update=true --rotate-revision -k

At the five-revision limit, APICtl will remove the oldest revision and deploy
the newly generated revision.

Backups:

  ${backup_dir}

EOF
