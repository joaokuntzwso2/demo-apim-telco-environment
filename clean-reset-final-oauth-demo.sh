#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

CONTROL="scripts/telco-demo-control.sh"
OAUTH_SETUP="services/apim-bootstrapper/src/oauth-business-controls-setup.js"
SHORT_CLIENT_RECONCILER="scripts/reconcile-short-lived-oauth-client.sh"
OAUTH_RECONCILE="scripts/reconcile-oauth-control-plane.sh"
OAUTH_VERIFY="scripts/verify-oauth-consent-risk-controls.sh"
OAUTH_POST_START="scripts/complete-oauth-post-start.sh"

log() {
  printf '\n[clean-oauth-reset] %s\n' "$*"
}

fail() {
  printf '\n[clean-oauth-reset][FAIL] %s\n' "$*" >&2
  exit 1
}

for command in \
  bash \
  python3 \
  docker \
  curl \
  jq
do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Required command is missing: $command"
done

for file in \
  "$CONTROL" \
  "$OAUTH_SETUP" \
  "$SHORT_CLIENT_RECONCILER" \
  "$OAUTH_RECONCILE" \
  "$OAUTH_VERIFY" \
  "$OAUTH_POST_START" \
  docker-compose.yml
do
  [[ -f "$file" ]] ||
    fail "Required file is missing: $file"
done

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/clean-final-reset-${timestamp}"

mkdir -p "$backup_dir"

active_files=(
  "$OAUTH_SETUP"
  "$SHORT_CLIENT_RECONCILER"
  "$OAUTH_RECONCILE"
  "$OAUTH_VERIFY"
  "$OAUTH_POST_START"
)

template_files=(
  install-short-lived-client-reconciler.sh
  install-final-oauth-runtime-logic.sh
  fix-final-short-lived-token-expiry.sh
)

for file in \
  "${active_files[@]}" \
  "${template_files[@]}"
do
  if [[ -f "$file" ]]; then
    cp \
      "$file" \
      "$backup_dir/$(printf '%s' "$file" | tr '/' '_')"
  fi
done

log "Backups written under:"
echo "  $backup_dir"

###############################################################################
# Correct the actual APIM Key Manager property names.
###############################################################################

log "Correcting OAuth-client expiry property names."

python3 - \
  "$OAUTH_SETUP" \
  "$SHORT_CLIENT_RECONCILER" \
  "${template_files[@]}" <<'PY'
from pathlib import Path
import sys

paths = [
    Path(value)
    for value in sys.argv[1:]
]

replacements = {
    "applicationAccessTokenExpiryTime":
        "application_access_token_expiry_time",

    "userAccessTokenExpiryTime":
        "user_access_token_expiry_time",
}

for path in paths:
    if not path.exists():
        continue

    original = path.read_text(
        encoding="utf-8",
    )

    updated = original

    for old, new in replacements.items():
        updated = updated.replace(
            old,
            new,
        )

    path.write_text(
        updated,
        encoding="utf-8",
    )

    if updated != original:
        print(
            "[clean-oauth-reset] "
            f"Corrected expiry properties in {path}"
        )
    else:
        print(
            "[clean-oauth-reset] "
            f"No camelCase expiry properties remained in {path}"
        )
PY

###############################################################################
# Make the reconciler's persisted-value check safe and explicit.
###############################################################################

python3 - "$SHORT_CLIENT_RECONCILER" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

# Avoid a raw `tonumber` error when APIM has not returned the property.
text = re.sub(
    r'''
    \(
      \s*properties
      \s*\|\s*
      \.application_access_token_expiry_time
      \s*\|\s*
      tonumber
    \s*\)
    \s*==\s*2
    ''',
    '''(
    properties
    | (
        .application_access_token_expiry_time //
        0
      )
    | tonumber
  ) == 2''',
    text,
    flags=re.VERBOSE,
)

# Support a simpler formatting variant.
text = text.replace(
    '''properties
    | .application_access_token_expiry_time
    | tonumber''',
    '''properties
    | (
        .application_access_token_expiry_time //
        0
      )
    | tonumber''',
)

path.write_text(
    text,
    encoding="utf-8",
)

required = (
    "application_access_token_expiry_time",
    "user_access_token_expiry_time",
)

missing = [
    value
    for value in required
    if value not in text
]

if missing:
    raise SystemExit(
        "[clean-oauth-reset][FAIL] "
        "Short-client reconciler is missing: "
        + ", ".join(missing)
    )

print(
    "[clean-oauth-reset] "
    "Short-client persisted-value check normalized."
)
PY

###############################################################################
# Confirm the active OAuth setup creates the client with the correct names.
###############################################################################

python3 - "$OAUTH_SETUP" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

required = (
    "application_access_token_expiry_time",
    "user_access_token_expiry_time",
    "client_credentials",
)

missing = [
    value
    for value in required
    if value not in text
]

if missing:
    raise SystemExit(
        "[clean-oauth-reset][FAIL] "
        "OAuth bootstrap is missing: "
        + ", ".join(missing)
    )

for obsolete in (
    "applicationAccessTokenExpiryTime",
    "userAccessTokenExpiryTime",
):
    if obsolete in text:
        raise SystemExit(
            "[clean-oauth-reset][FAIL] "
            f"Obsolete property remains: {obsolete}"
        )

print(
    "[clean-oauth-reset] "
    "OAuth bootstrap expiry configuration is correct."
)
PY

###############################################################################
# Ensure the verification uses the real APIM token endpoint and tests the
# configured client lifetime rather than the ignored validity_period hint.
###############################################################################

python3 - "$OAUTH_VERIFY" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

text = text.replace(
    "https://127.0.0.1:8243/token",
    "https://127.0.0.1:9443/oauth2/token",
)

text = text.replace(
    "https://localhost:8243/token",
    "https://127.0.0.1:9443/oauth2/token",
)

lines = []

for line in text.splitlines():
    if (
        "--data-urlencode" in line
        and "validity_period=2" in line
    ):
        continue

    lines.append(line)

path.write_text(
    "\n".join(lines) + "\n",
    encoding="utf-8",
)

print(
    "[clean-oauth-reset] "
    "Verifier uses the configured OAuth-client lifetime."
)
PY

###############################################################################
# Validate all active files before deleting any Docker state.
###############################################################################

log "Running static validation before destructive reset."

bash -n "$CONTROL"
bash -n "$SHORT_CLIENT_RECONCILER"
bash -n "$OAUTH_RECONCILE"
bash -n "$OAUTH_VERIFY"
bash -n "$OAUTH_POST_START"

if command -v node >/dev/null 2>&1; then
  node --check "$OAUTH_SETUP"
fi

grep -Fq \
  'application_access_token_expiry_time' \
  "$OAUTH_SETUP" ||
  fail \
    "Correct application expiry property is absent from OAuth bootstrap."

grep -Fq \
  'application_access_token_expiry_time' \
  "$SHORT_CLIENT_RECONCILER" ||
  fail \
    "Correct application expiry property is absent from reconciler."

if grep -Fq \
  'applicationAccessTokenExpiryTime' \
  "$OAUTH_SETUP"
then
  fail \
    "CamelCase application expiry property remains in OAuth bootstrap."
fi

if grep -Fq \
  'applicationAccessTokenExpiryTime' \
  "$SHORT_CLIENT_RECONCILER"
then
  fail \
    "CamelCase application expiry property remains in reconciler."
fi

grep -Fq \
  'reconcile-short-lived-oauth-client.sh' \
  "$OAUTH_RECONCILE" ||
  fail \
    "Short-lived client reconciliation hook is absent."

if grep -Fq \
  'validity_period=2' \
  "$OAUTH_VERIFY"
then
  fail \
    "Verifier still contains the ignored validity_period hint."
fi

log "Static validation passed."

###############################################################################
# Clear host-side generated state. Named-volume state will be deleted by reset.
###############################################################################

log "Removing stale host-side generated OAuth state."

rm -f \
  .runtime/oauth-business-controls.json \
  .runtime/developer-experience.json

mkdir -p .runtime

###############################################################################
# Destructive clean reset.
#
# SKIP_OAUTH_POST_START prevents a locally integrated OAuth hook from running
# during the base reset. We run exactly one authoritative OAuth cycle afterward.
###############################################################################

cat <<'WARNING'

[clean-oauth-reset] DESTRUCTIVE RESET STARTING

This removes the demo's Docker containers and named volumes, including:
  - the embedded APIM runtime database;
  - APIM APIs, Products, applications and subscriptions;
  - generated OAuth state;
  - persisted demo observability data.

The repository source files and backups are preserved.

WARNING

SKIP_OAUTH_POST_START=true \
COMPOSE_IGNORE_ORPHANS=1 \
bash "$CONTROL" reset

###############################################################################
# Run the OAuth extension exactly once against the clean APIM database.
###############################################################################

log "Running the OAuth consent and risk-control initialization."

COMPOSE_IGNORE_ORPHANS=1 \
OAUTH_RECONCILE_ATTEMPTS=1 \
OAUTH_VERIFY_ATTEMPTS=1 \
bash "$OAUTH_POST_START"

###############################################################################
# Final verification.
###############################################################################

log "Running final OAuth verification."

bash "$OAUTH_VERIFY"

if [[ -x scripts/verify-apim-bootstrap.sh ]]; then
  log "Running final base APIM verification."

  bash scripts/verify-apim-bootstrap.sh
fi

log "Checking APIM availability."

curl -kfsS \
  https://127.0.0.1:9443/services/Version \
  >/dev/null

cat <<EOF

[clean-oauth-reset] COMPLETE

The environment was recreated from empty named volumes.

Publisher:
  https://localhost:9443/publisher

Developer Portal:
  https://localhost:9443/devportal

Admin Portal:
  https://localhost:9443/admin

Backups:
  ${backup_dir}

EOF
