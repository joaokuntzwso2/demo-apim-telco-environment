#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"

cd "$ROOT_DIR"

FILES=(
  "scripts/verify-prepaid-grafana.sh"
  "scripts/fix-prepaid-grafana-scrape-race.sh"
)

fail() {
  printf '[fix-grafana-bash][FAIL] %s\n' "$*" >&2
  exit 1
}

pass() {
  printf '[fix-grafana-bash][PASS] %s\n' "$*"
}

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".prepaid-reconciliation-backups/grafana-bash-$STAMP"

mkdir -p "$BACKUP_DIR/scripts"

for file in "${FILES[@]}"; do
  [[ -f "$file" ]] || fail "Missing $file"
  cp "$file" "$BACKUP_DIR/$file"
done

python3 - "${FILES[@]}" <<'PY'
from pathlib import Path
import re
import sys

pattern = re.compile(
    r'''PROMETHEUS_INSTANCE="\$\{\s*
        PREPAID_PROMETHEUS_INSTANCE:-\s*
        commercial-meter-store-primary:8086\s*
        \}"''',
    re.VERBOSE | re.DOTALL,
)

replacement = (
    'PROMETHEUS_INSTANCE="'
    '${PREPAID_PROMETHEUS_INSTANCE:-'
    'commercial-meter-store-primary:8086}"'
)

for filename in sys.argv[1:]:
    path = Path(filename)
    content = path.read_text(encoding="utf-8")

    updated, count = pattern.subn(replacement, content)

    if count == 0:
        if replacement in content:
            print(f"{filename}: already corrected")
            continue

        raise SystemExit(
            f"Could not locate the malformed substitution in {filename}"
        )

    path.write_text(updated, encoding="utf-8")
    print(f"{filename}: corrected")
PY

for file in "${FILES[@]}"; do
  bash -n "$file" ||
    fail "Bash syntax validation failed for $file"
done

grep -Fq \
  'PROMETHEUS_INSTANCE="${PREPAID_PROMETHEUS_INSTANCE:-commercial-meter-store-primary:8086}"' \
  scripts/verify-prepaid-grafana.sh ||
  fail "Correct PROMETHEUS_INSTANCE assignment was not found."

pass "Bash parameter expansion corrected."
pass "Both scripts pass bash -n validation."

ROLLBACK="$BACKUP_DIR/rollback.sh"

cat > "$ROLLBACK" <<ROLLBACK
#!/usr/bin/env bash
set -Eeuo pipefail

cd "$ROOT_DIR"

cp "$BACKUP_DIR/scripts/verify-prepaid-grafana.sh" \
  scripts/verify-prepaid-grafana.sh

cp "$BACKUP_DIR/scripts/fix-prepaid-grafana-scrape-race.sh" \
  scripts/fix-prepaid-grafana-scrape-race.sh

printf '[rollback][PASS] Restored Grafana scripts from %s\n' \
  "$BACKUP_DIR"
ROLLBACK

chmod +x "$ROLLBACK"

printf '\nBackup:   %s\n' "$BACKUP_DIR"
printf 'Rollback: bash %s\n' "$ROLLBACK"
