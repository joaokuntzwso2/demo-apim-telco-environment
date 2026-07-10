#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"

cd "$ROOT_DIR"

VERIFY_FILE="scripts/verify-prepaid-reset-wiring.sh"
INSTALLER_FILE="scripts/integrate-prepaid-into-ai-reset.sh"

fail() {
  printf '[fix-prepaid-reset-compose][FAIL] %s\n' "$*" >&2
  exit 1
}

pass() {
  printf '[fix-prepaid-reset-compose][PASS] %s\n' "$*"
}

[[ -f "$VERIFY_FILE" ]] ||
  fail "Missing $VERIFY_FILE"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".prepaid-reconciliation-backups/compose-validation-$STAMP"

mkdir -p "$BACKUP_DIR/scripts"

cp "$VERIFY_FILE" "$BACKUP_DIR/$VERIFY_FILE"

if [[ -f "$INSTALLER_FILE" ]]; then
  cp "$INSTALLER_FILE" "$BACKUP_DIR/$INSTALLER_FILE"
fi

python3 - "$VERIFY_FILE" "$INSTALLER_FILE" <<'PY'
from pathlib import Path
import re
import sys

verify_file = Path(sys.argv[1])
installer_file = Path(sys.argv[2])

targets = [verify_file]

if installer_file.exists():
    targets.append(installer_file)

old_pattern = re.compile(
    r'''docker compose\s*\\
\s*-f docker-compose\.yml\s*\\
\s*-f docker-compose\.commercial\.yml\s*\\
\s*config --quiet''',
    re.MULTILINE,
)

new_block = r'''ENV_FILE="${TELCO_AI_ENV_FILE:-.env.ai.local}"

COMPOSE_VALIDATION=(
  docker compose
)

if [[ -f "$ENV_FILE" ]]; then
  COMPOSE_VALIDATION+=(
    --env-file "$ENV_FILE"
  )
fi

COMPOSE_VALIDATION+=(
  -f docker-compose.yml
  -f docker-compose.mi.yml
  -f docker-compose.commercial.yml
  config
  --quiet
)

"${COMPOSE_VALIDATION[@]}"'''

for path in targets:
    content = path.read_text(encoding="utf-8")

    if (
        "-f docker-compose.mi.yml" in content
        and 'COMPOSE_VALIDATION=(' in content
    ):
        print(f"{path}: already corrected")
        continue

    updated, count = old_pattern.subn(
        lambda _: new_block,
        content,
    )

    if count == 0:
        raise SystemExit(
            f"Could not find the invalid Compose validation block in {path}"
        )

    path.write_text(updated, encoding="utf-8")
    print(f"{path}: corrected")
PY

bash -n "$VERIFY_FILE"

if [[ -f "$INSTALLER_FILE" ]]; then
  bash -n "$INSTALLER_FILE"
fi

grep -Fq -- "-f docker-compose.mi.yml" "$VERIFY_FILE" ||
  fail "docker-compose.mi.yml was not added to the verifier."

pass "Compose validation now includes the MI service definition."

TELCO_AI_ENV_FILE="${TELCO_AI_ENV_FILE:-.env.ai.local}" \
  bash "$VERIFY_FILE"

pass "Prepaid reset wiring validation succeeds."

printf '\nBackup directory:\n  %s\n' "$BACKUP_DIR"

printf '\nRollback:\n'
printf '  cp %q %q\n' \
  "$BACKUP_DIR/$VERIFY_FILE" \
  "$VERIFY_FILE"

if [[ -f "$BACKUP_DIR/$INSTALLER_FILE" ]]; then
  printf '  cp %q %q\n' \
    "$BACKUP_DIR/$INSTALLER_FILE" \
    "$INSTALLER_FILE"
fi
