#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

VERIFY="scripts/verify-apim-bootstrap.sh"

log() {
  printf '[base-compose-repair] %s\n' "$*"
}

fail() {
  printf '[base-compose-repair][FAIL] %s\n' "$*" >&2
  exit 1
}

for command in bash python3 docker curl; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Required command is missing: $command"
done

[[ -f "$VERIFY" ]] ||
  fail "Missing $VERIFY"

[[ -f docker-compose.yml ]] ||
  fail "Missing docker-compose.yml"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/base-compose-model-${timestamp}"

mkdir -p "$backup_dir"
cp "$VERIFY" "$backup_dir/verify-apim-bootstrap.sh"

log "Backup written to $backup_dir"

python3 - "$VERIFY" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

start_marker = (
    'echo "Resolving the running stack\'s '
    'complete Compose topology."'
)

end_marker = (
    'echo "Waiting for WSO2 API Manager to become ready."'
)

start = text.find(start_marker)
end = text.find(end_marker, start)

if start < 0:
    raise SystemExit(
        "[base-compose-repair][FAIL] "
        "Could not locate the full-topology preflight."
    )

if end < 0:
    raise SystemExit(
        "[base-compose-repair][FAIL] "
        "Could not locate the APIM readiness section."
    )

base_compose_block = r'''echo "Resolving the base Compose project for read-only verification."

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"

COMPOSE_PROJECT="$(
  docker inspect \
    wso2-apim-4-7 \
    --format \
    '{{ index .Config.Labels "com.docker.compose.project" }}' \
    2>/dev/null ||
    true
)"

if [[ -z "${COMPOSE_PROJECT}" ]]; then
  echo "ERROR: Could not resolve the running APIM Compose project."
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  BASE_COMPOSE=(
    docker compose
    -p "${COMPOSE_PROJECT}"
    -f "${ROOT_DIR}/docker-compose.yml"
  )
elif docker-compose version >/dev/null 2>&1; then
  BASE_COMPOSE=(
    docker-compose
    -p "${COMPOSE_PROJECT}"
    -f "${ROOT_DIR}/docker-compose.yml"
  )
else
  echo "ERROR: Docker Compose is unavailable."
  exit 1
fi

if ! "${BASE_COMPOSE[@]}" config --services |
    grep -Fxq 'apim-bootstrapper'
then
  echo "ERROR: apim-bootstrapper is absent from docker-compose.yml."
  exit 1
fi

echo "Using Compose project: ${COMPOSE_PROJECT}"
echo "Using Compose file: ${ROOT_DIR}/docker-compose.yml"

'''

text = (
    text[:start]
    + base_compose_block
    + text[end:]
)

pattern = re.compile(
    r'''
    "\$\{OAUTH_COMPOSE\[@\]\}"
    \s+run
    \s+--rm
    \s+--no-deps
    \s+apim-bootstrapper
    ''',
    re.VERBOSE,
)

text, replacements = pattern.subn(
    '"${BASE_COMPOSE[@]}" run '
    '--rm --no-deps apim-bootstrapper',
    text,
)

if replacements == 0:
    if (
        '"${BASE_COMPOSE[@]}" run '
        '--rm --no-deps apim-bootstrapper'
        not in text
    ):
        raise SystemExit(
            "[base-compose-repair][FAIL] "
            "Could not locate the bootstrapper Compose command."
        )

path.write_text(
    text,
    encoding="utf-8",
)

print(
    "[base-compose-repair] "
    f"Replaced {replacements} full-topology run command(s)."
)
PY

chmod +x "$VERIFY"

if ! bash -n "$VERIFY"; then
  cp "$backup_dir/verify-apim-bootstrap.sh" "$VERIFY"
  fail "Verifier syntax failed; original restored."
fi

grep -Fq \
  'BASE_COMPOSE=(' \
  "$VERIFY" ||
  fail "Base Compose array was not installed."

grep -Fq \
  '"${BASE_COMPOSE[@]}" run --rm --no-deps apim-bootstrapper' \
  "$VERIFY" ||
  fail "Safe bootstrapper execution was not installed."

if grep -Fq \
  '"${OAUTH_COMPOSE[@]}" run' \
  "$VERIFY"
then
  fail "The invalid full-topology execution remains."
fi

log "Static validation passed."

project="$(
  docker inspect \
    wso2-apim-4-7 \
    --format \
    '{{ index .Config.Labels "com.docker.compose.project" }}'
)"

log "Validating the base Compose model."

COMPOSE_IGNORE_ORPHANS=1 \
docker compose \
  -p "$project" \
  -f docker-compose.yml \
  config \
  --services |
grep -Fxq apim-bootstrapper ||
  fail "Base Compose model does not contain apim-bootstrapper."

log "Confirming APIM is ready without restarting it."

curl -kfsS \
  --connect-timeout 2 \
  --max-time 10 \
  https://127.0.0.1:9443/services/Version \
  >/dev/null ||
  fail "APIM is not currently ready."

log "Running the repaired base verifier."

COMPOSE_IGNORE_ORPHANS=1 \
bash "$VERIFY"

cat <<EOF

[base-compose-repair] COMPLETE

The base verifier now uses:

  project: ${project}
  file:    docker-compose.yml
  command: docker compose run --rm --no-deps apim-bootstrapper

It no longer loads the incomplete MI override model and cannot restart APIM.

Backup:
  ${backup_dir}

EOF
