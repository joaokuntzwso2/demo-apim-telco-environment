#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

CONTROL="scripts/telco-demo-control.sh"
VERIFY_OAUTH="scripts/verify-oauth-consent-risk-controls.sh"

fail() {
  printf '[safe-full-restart][FAIL] %s\n' "$*" >&2
  exit 1
}

log() {
  printf '\n[safe-full-restart] %s\n' "$*"
}

for command in bash python3 docker curl jq; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Required command is missing: $command"
done

for file in \
  "$CONTROL" \
  "$VERIFY_OAUTH" \
  scripts/complete-oauth-post-start.sh \
  scripts/verify-apim-bootstrap.sh \
  docker-compose.yml
do
  [[ -f "$file" ]] ||
    fail "Required file is missing: $file"
done

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/safe-full-restart-${timestamp}"

mkdir -p "$backup_dir"

cp "$VERIFY_OAUTH" \
  "$backup_dir/verify-oauth-consent-risk-controls.sh"

log "Correcting the local OAuth token endpoint."

python3 - "$VERIFY_OAUTH" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

replacements = {
    "https://127.0.0.1:8243/token":
        "https://127.0.0.1:9443/oauth2/token",
    "https://localhost:8243/token":
        "https://127.0.0.1:9443/oauth2/token",
}

for old, new in replacements.items():
    text = text.replace(old, new)

path.write_text(text, encoding="utf-8")

expected = (
    'short_token_url="${OAUTH_SHORT_TOKEN_URL:-'
    'https://127.0.0.1:9443/oauth2/token}"'
)

if expected not in text:
    raise SystemExit(
        "[safe-full-restart][FAIL] "
        "Could not establish the correct short-token endpoint."
    )

print(
    "[safe-full-restart] "
    "Short-token endpoint: "
    "https://127.0.0.1:9443/oauth2/token"
)
PY

log "Validating lifecycle scripts before stopping anything."

bash -n "$CONTROL"
bash -n "$VERIFY_OAUTH"
bash -n scripts/complete-oauth-post-start.sh
bash -n scripts/verify-apim-bootstrap.sh

if [[ -f scripts/verify-developer-experience.sh ]]; then
  bash -n scripts/verify-developer-experience.sh
fi

if [[ -f scripts/oauth-compose-context.sh ]]; then
  bash -n scripts/oauth-compose-context.sh
fi

log "Running the complete lifecycle restart."

COMPOSE_IGNORE_ORPHANS=1 \
  bash "$CONTROL" restart

log "Ensuring the OAuth extension is reconciled and verified."

COMPOSE_IGNORE_ORPHANS=1 \
OAUTH_RECONCILE_ATTEMPTS=1 \
OAUTH_VERIFY_ATTEMPTS=1 \
  bash scripts/complete-oauth-post-start.sh

log "Verifying the complete base API catalogue."

bash scripts/verify-apim-bootstrap.sh

if [[ -f scripts/verify-developer-experience.sh ]]; then
  log "Verifying Developer Portal publication and documentation."

  bash scripts/verify-developer-experience.sh
fi

log "Running the final OAuth business-control verification."

bash "$VERIFY_OAUTH"

log "Checking APIM and portal availability."

curl -kfsS \
  https://localhost:9443/services/Version \
  >/dev/null

curl -fsS \
  http://localhost:8080/portal-status \
  | jq .

cat <<EOF

[safe-full-restart] COMPLETE

Publisher:
  https://localhost:9443/publisher

Developer Portal:
  https://localhost:9443/devportal

Admin Portal:
  https://localhost:9443/admin

Backups:
  ${backup_dir}

EOF
