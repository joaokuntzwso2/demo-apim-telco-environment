#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

python3 <<'PY'
from pathlib import Path
import re

targets = [
    Path("scripts/complete-oauth-post-start.sh"),
    Path("install-complete-oauth-restart-v2.sh"),
]

replacements = [
    (
        re.compile(
            r'APIM_HEALTH_URL="\$\{\s*'
            r'APIM_HEALTH_URL:-\s*'
            r'https://localhost:9443/services/Version\s*'
            r'\}"',
            re.MULTILINE,
        ),
        'APIM_HEALTH_URL="${APIM_HEALTH_URL:-https://localhost:9443/services/Version}"',
    ),
    (
        re.compile(
            r'OAUTH_MI_HEALTH_URL="\$\{\s*'
            r'OAUTH_MI_HEALTH_URL:-\s*'
            r'http://localhost:8290/subscriber-authorization/v1/health\s*'
            r'\}"',
            re.MULTILINE,
        ),
        'OAUTH_MI_HEALTH_URL="${OAUTH_MI_HEALTH_URL:-http://localhost:8290/subscriber-authorization/v1/health}"',
    ),
]

patched = []

for path in targets:
    if not path.exists():
        continue

    original = path.read_text(encoding="utf-8")
    updated = original

    for pattern, replacement in replacements:
        updated = pattern.sub(replacement, updated)

    if updated != original:
        backup = path.with_suffix(path.suffix + ".before-substitution-fix")
        backup.write_text(original, encoding="utf-8")
        path.write_text(updated, encoding="utf-8")
        patched.append(str(path))
        print(f"[oauth-substitution-fix] Patched {path}")
    else:
        print(f"[oauth-substitution-fix] No change required: {path}")

helper = Path("scripts/complete-oauth-post-start.sh")

if not helper.exists():
    raise SystemExit(
        "[oauth-substitution-fix][FAIL] "
        "scripts/complete-oauth-post-start.sh does not exist."
    )

helper_text = helper.read_text(encoding="utf-8")

required = [
    'APIM_HEALTH_URL="${APIM_HEALTH_URL:-https://localhost:9443/services/Version}"',
    'OAUTH_MI_HEALTH_URL="${OAUTH_MI_HEALTH_URL:-http://localhost:8290/subscriber-authorization/v1/health}"',
]

missing = [value for value in required if value not in helper_text]

if missing:
    raise SystemExit(
        "[oauth-substitution-fix][FAIL] "
        f"Correct assignments were not found: {missing}"
    )

print("[oauth-substitution-fix] Environment defaults are valid.")
PY

chmod +x scripts/complete-oauth-post-start.sh

bash -n scripts/complete-oauth-post-start.sh

if [[ -f install-complete-oauth-restart-v2.sh ]]; then
  bash -n install-complete-oauth-restart-v2.sh
fi

echo
echo "[oauth-substitution-fix] Corrected assignments:"
grep -nE \
  '^(APIM_HEALTH_URL|OAUTH_MI_HEALTH_URL)=' \
  scripts/complete-oauth-post-start.sh

echo
echo "[oauth-substitution-fix] Fix completed."
