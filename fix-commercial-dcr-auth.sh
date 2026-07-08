#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

info() {
  printf '[commercial-dcr-fix] %s\n' "$*"
}

for command in python3 node bash docker; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done

python3 <<'PY'
from pathlib import Path

def patch_js(path_text: str) -> None:
    path = Path(path_text)
    if not path.is_file():
        raise SystemExit(f"Missing required file: {path}")

    text = path.read_text()
    authenticated = (
        "headers: { "
        "authorization: `Basic ${Buffer.from(`${USER}:${PASSWORD}`).toString('base64')}`, "
        "'content-type': 'application/json' },"
    )
    unauthenticated = "headers: { 'content-type': 'application/json' },"

    if authenticated in text:
        print(f"[commercial-dcr-fix] already patched: {path}")
        return

    marker = "client-registration/v0.17/register"
    marker_index = text.find(marker)
    if marker_index < 0:
        raise SystemExit(f"DCR endpoint not found in {path}")

    header_index = text.find(unauthenticated, marker_index)
    if header_index < 0:
        raise SystemExit(f"Unauthenticated DCR header not found after endpoint in {path}")

    text = (
        text[:header_index]
        + authenticated
        + text[header_index + len(unauthenticated):]
    )
    path.write_text(text)
    print(f"[commercial-dcr-fix] patched Basic authentication: {path}")

patch_js("services/apim-bootstrapper/src/commercial-api-setup.js")
patch_js("services/apim-bootstrapper/src/commercial-experience-setup.js")

verifier = Path("scripts/verify-commercial-plan-usage.sh")
if not verifier.is_file():
    raise SystemExit(f"Missing required file: {verifier}")

text = verifier.read_text()
patched = 'DCR="$(curl -ksS -u "$APIM_USER:$APIM_PASS" -X POST'
unpatched = 'DCR="$(curl -ksS -X POST'

if patched in text:
    print(f"[commercial-dcr-fix] already patched: {verifier}")
elif unpatched in text:
    verifier.write_text(text.replace(unpatched, patched, 1))
    print(f"[commercial-dcr-fix] patched Basic authentication: {verifier}")
else:
    raise SystemExit(f"Verifier DCR command not found in {verifier}")

# Also patch the full installer kept in the repository, if present, so a later
# reinstall does not restore the defect.
for installer_name in (
    "install-secure-mobile-commercial-flow.sh",
    "install-secure-mobile-commercial-flow-v2.sh",
):
    installer = Path(installer_name)
    if not installer.is_file():
        continue

    text = installer.read_text()
    unauthenticated_header = "headers: { 'content-type': 'application/json' },"
    authenticated_header = (
        "headers: { "
        "authorization: `Basic ${Buffer.from(`${USER}:${PASSWORD}`).toString('base64')}`, "
        "'content-type': 'application/json' },"
    )
    text = text.replace(unauthenticated_header, authenticated_header)
    text = text.replace(
        'DCR="$(curl -ksS -X POST -H \'Content-Type: application/json\'',
        'DCR="$(curl -ksS -u "$APIM_USER:$APIM_PASS" -X POST -H \'Content-Type: application/json\'',
    )
    installer.write_text(text)
    installer.chmod(0o755)
    print(f"[commercial-dcr-fix] reconciled installer: {installer}")
PY

node --check services/apim-bootstrapper/src/commercial-api-setup.js
node --check services/apim-bootstrapper/src/commercial-experience-setup.js
bash -n scripts/verify-commercial-plan-usage.sh

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif docker-compose version >/dev/null 2>&1; then
  DC=(docker-compose)
else
  fail "Docker Compose is required"
fi

COMPOSE_FILES=(docker-compose.yml)
for file in \
  docker-compose.kafka.yml \
  docker-compose.opa.yml \
  docker-compose.mi.yml \
  docker-compose.commercial.yml \
  docker-compose.mi.soap.yml \
  docker-compose.observability.yml \
  docker-compose.runtime-persistence.yml; do
  [[ -f "$file" ]] && COMPOSE_FILES+=("$file")
done

COMPOSE=("${DC[@]}")
for file in "${COMPOSE_FILES[@]}"; do
  COMPOSE+=(-f "$file")
done

"${COMPOSE[@]}" config >/dev/null

info "Rebuilding the APIM bootstrapper image"
"${COMPOSE[@]}" build apim-bootstrapper

info "Running the idempotent APIM bootstrapper again"
"${COMPOSE[@]}" run --rm apim-bootstrapper

info "DCR authentication fix applied and bootstrap completed"
info "Next command: bash scripts/verify-commercial-plan-usage.sh"
