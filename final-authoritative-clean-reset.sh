#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

CONTROL="scripts/telco-demo-control.sh"
OAUTH_SETUP="services/apim-bootstrapper/src/oauth-business-controls-setup.js"
OAUTH_RECONCILE="scripts/reconcile-oauth-control-plane.sh"
SHORT_RECONCILE="scripts/reconcile-short-lived-oauth-client.sh"
PERSONA_GENERATOR="scripts/generate-oauth-persona-sequence.sh"
PERSONA_RESOLVER="scripts/resolve-oauth-persona-subjects.py"
OAUTH_POST_START="scripts/complete-oauth-post-start.sh"
OAUTH_VERIFY="scripts/verify-oauth-consent-risk-controls.sh"
PORTAL_SERVER="services/demo-portal/server.js"
BASE_VERIFY="scripts/verify-apim-bootstrap.sh"
INVENTORY_VERIFY="scripts/verify-published-api-inventory.sh"

log() {
  printf '\n[final-clean-reset] %s\n' "$*"
}

fail() {
  printf '\n[final-clean-reset][FAIL] %s\n' "$*" >&2
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
  "$OAUTH_RECONCILE" \
  "$SHORT_RECONCILE" \
  "$PERSONA_GENERATOR" \
  "$PERSONA_RESOLVER" \
  "$OAUTH_POST_START" \
  "$OAUTH_VERIFY" \
  "$PORTAL_SERVER" \
  docker-compose.yml
do
  [[ -f "$file" ]] ||
    fail "Required file is missing: $file"
done

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/authoritative-reset-${timestamp}"

mkdir -p "$backup_dir"

for file in \
  "$CONTROL" \
  "$OAUTH_SETUP" \
  "$OAUTH_RECONCILE" \
  "$SHORT_RECONCILE" \
  "$PERSONA_GENERATOR" \
  "$PERSONA_RESOLVER" \
  "$OAUTH_POST_START" \
  "$OAUTH_VERIFY" \
  "$PORTAL_SERVER" \
  "$BASE_VERIFY"
do
  if [[ -f "$file" ]]; then
    backup_name="$(
      printf '%s' "$file" |
        tr '/' '_'
    )"

    cp "$file" "$backup_dir/$backup_name"
  fi
done

log "Backups written under:"
echo "  $backup_dir"

###############################################################################
# 1. Normalize all active corrections.
###############################################################################

log "Normalizing active OAuth and portal corrections."

python3 - \
  "$OAUTH_SETUP" \
  "$SHORT_RECONCILE" \
  "$OAUTH_VERIFY" <<'PY'
from pathlib import Path
import sys

setup_path = Path(sys.argv[1])
reconciler_path = Path(sys.argv[2])
verify_path = Path(sys.argv[3])

for path in (
    setup_path,
    reconciler_path,
):
    text = path.read_text(
        encoding="utf-8"
    )

    text = text.replace(
        "applicationAccessTokenExpiryTime",
        "application_access_token_expiry_time",
    )

    text = text.replace(
        "userAccessTokenExpiryTime",
        "user_access_token_expiry_time",
    )

    path.write_text(
        text,
        encoding="utf-8",
    )

verify = verify_path.read_text(
    encoding="utf-8"
)

verify = verify.replace(
    "https://127.0.0.1:8243/token",
    "https://127.0.0.1:9443/oauth2/token",
)

verify = verify.replace(
    "https://localhost:8243/token",
    "https://127.0.0.1:9443/oauth2/token",
)

verify_lines = []

for line in verify.splitlines():
    if (
        "--data-urlencode" in line
        and "validity_period=2" in line
    ):
        continue

    verify_lines.append(line)

verify_path.write_text(
    "\n".join(verify_lines) + "\n",
    encoding="utf-8",
)

print(
    "[final-clean-reset] "
    "Normalized expiry property names and token URL."
)
PY

###############################################################################
# 2. Ensure the controller always uses the complete Compose topology.
###############################################################################

log "Installing the authoritative Compose-file order in the lifecycle controller."

python3 - "$CONTROL" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

replacement = r'''COMPOSE_FILES=(docker-compose.yml)

for file in \
  docker-compose.kafka.yml \
  docker-compose.opa.yml \
  docker-compose.central-policy.yml \
  docker-compose.mi.yml \
  docker-compose.oauth-business-controls.yml \
  docker-compose.commercial.yml \
  docker-compose.mi.soap.yml \
  docker-compose.observability.yml \
  docker-compose.audit-siem.yml \
  docker-compose.runtime-persistence.yml
do
  [[ -f "$file" ]] &&
    COMPOSE_FILES+=("$file")
done

COMPOSE=("${DC[@]}")'''

pattern = re.compile(
    r'''
    COMPOSE_FILES=
    \(
      docker-compose\.yml
    \)
    .*?
    COMPOSE=
    \(
      "\$\{DC\[@\]\}"
    \)
    ''',
    re.VERBOSE | re.DOTALL,
)

updated, count = pattern.subn(
    replacement,
    text,
    count=1,
)

if count == 0:
    required = (
        "docker-compose.oauth-business-controls.yml",
        "docker-compose.central-policy.yml",
        "docker-compose.audit-siem.yml",
        "docker-compose.runtime-persistence.yml",
    )

    if not all(
        item in text
        for item in required
    ):
        raise SystemExit(
            "[final-clean-reset][FAIL] "
            "Could not normalize the controller's "
            "Compose-file list."
        )

    print(
        "[final-clean-reset] "
        "Controller already contains the complete topology."
    )

else:
    path.write_text(
        updated,
        encoding="utf-8",
    )

    print(
        "[final-clean-reset] "
        "Controller Compose topology normalized."
    )
PY

###############################################################################
# 3. Replace the dangerous base verifier with a truly read-only inventory
#    verifier. It never executes docker compose up/run and therefore cannot
#    recreate APIM.
###############################################################################

log "Installing a read-only Publisher and Developer Portal inventory verifier."

cat > "$INVENTORY_VERIFY" <<'VERIFY'
#!/usr/bin/env bash
set -Eeo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"
cd "$ROOT_DIR"

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"
PORTAL_STATUS_URL="${PORTAL_STATUS_URL:-http://127.0.0.1:8080/portal-status}"

WORK_DIR="$(
  mktemp -d \
    "${TMPDIR:-/tmp}/api-inventory.XXXXXX"
)"

trap 'rm -rf "$WORK_DIR"' EXIT

log() {
  printf '[api-inventory] %s\n' "$*"
}

fail() {
  printf '[api-inventory][FAIL] %s\n' "$*" >&2
  exit 1
}

log "Checking APIM readiness."

curl -kfsS \
  --connect-timeout 3 \
  --max-time 10 \
  "${APIM_URL}/services/Version" \
  >/dev/null ||
  fail "APIM is not ready at ${APIM_URL}."

log "Reading the Telco portal runtime state."

curl -fsS \
  --connect-timeout 3 \
  --max-time 10 \
  "$PORTAL_STATUS_URL" \
  >"$WORK_DIR/portal.json" ||
  fail "Portal status is unavailable at ${PORTAL_STATUS_URL}."

jq -e \
  '.status == "READY"' \
  "$WORK_DIR/portal.json" \
  >/dev/null ||
  {
    jq . "$WORK_DIR/portal.json" >&2
    fail "Portal runtime state is not READY."
  }

publisher_expected=()
devportal_expected=()

while IFS= read -r api_name; do
  [[ -n "$api_name" ]] ||
    continue

  publisher_expected+=("$api_name")
done < <(
  jq -r '
    .apis[]?
    | .name
    | select(type == "string" and length > 0)
  ' "$WORK_DIR/portal.json"
)

while IFS= read -r api_name; do
  [[ -n "$api_name" ]] ||
    continue

  devportal_expected+=("$api_name")
done < <(
  jq -r '
    .apis[]?
    | select(
        (
          .protocol // "REST"
          | ascii_upcase
        ) != "SOAP"
      )
    | select(
        (
          .protocol // "REST"
          | ascii_upcase
        ) != "ASYNC"
      )
    | .name
    | select(type == "string" and length > 0)
  ' "$WORK_DIR/portal.json"
)

publisher_expected+=(
  "TelcoObservabilityAPI"
  "SubscriberAuthorizationControlAPI"
)

devportal_expected+=(
  "SubscriberAuthorizationControlAPI"
)

if [[ "${#publisher_expected[@]}" -eq 0 ]]; then
  fail "No expected APIs were found in portal state."
fi

log "Registering a temporary read-only management client."

dcr_payload="$(
  jq -nc \
    --arg name \
      "api-inventory-$(date +%s)-$$" '
      {
        callbackUrl:
          "http://localhost:8080/callback",
        clientName: $name,
        owner: "admin",
        grantType:
          "password refresh_token",
        saasApp: true
      }
    '
)"

dcr_response="$(
  curl -ksS \
    -u "${APIM_USER}:${APIM_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d "$dcr_payload" \
    "${APIM_URL}/client-registration/v0.17/register"
)"

client_id="$(
  jq -r \
    '.clientId // empty' \
    <<<"$dcr_response"
)"

client_secret="$(
  jq -r \
    '.clientSecret // empty' \
    <<<"$dcr_response"
)"

if [[ -z "$client_id" ||
      -z "$client_secret" ]]
then
  jq . <<<"$dcr_response" >&2 || true
  fail "Management-client registration failed."
fi

token_response="$(
  curl -ksS \
    -u "${client_id}:${client_secret}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${APIM_USER}" \
    --data-urlencode "password=${APIM_PASSWORD}" \
    --data-urlencode \
      'scope=apim:api_view apim:subscribe' \
    "${APIM_URL}/oauth2/token"
)"

access_token="$(
  jq -r \
    '.access_token // empty' \
    <<<"$token_response"
)"

if [[ -z "$access_token" ]]; then
  jq '
    del(
      .access_token,
      .refresh_token,
      .id_token
    )
  ' <<<"$token_response" >&2 || true

  fail "Management-token acquisition failed."
fi

publisher_visible() {
  local api_name="$1"
  local response

  response="$(
    curl -ksS -G \
      -H "Authorization: Bearer ${access_token}" \
      --data-urlencode "query=name:${api_name}" \
      --data-urlencode 'limit=100' \
      "${APIM_URL}/api/am/publisher/v4/apis"
  )"

  jq -e \
    --arg name "$api_name" '
      any(
        (.list // .data // [])[]?;
        .name == $name and
        (
          .lifeCycleStatus == "PUBLISHED" or
          .lifecycleStatus == "PUBLISHED" or
          .state == "PUBLISHED"
        )
      )
    ' <<<"$response" \
    >/dev/null
}

devportal_visible() {
  local api_name="$1"
  local response

  response="$(
    curl -ksS -G \
      -H "Authorization: Bearer ${access_token}" \
      --data-urlencode "query=name:${api_name}" \
      --data-urlencode 'limit=100' \
      "${APIM_URL}/api/am/devportal/v3/apis"
  )"

  jq -e \
    --arg name "$api_name" '
      any(
        (.list // .data // [])[]?;
        .name == $name
      )
    ' <<<"$response" \
    >/dev/null
}

log "Checking Publisher inventory."

for api_name in "${publisher_expected[@]}"; do
  found=false

  for attempt in $(seq 1 30); do
    if publisher_visible "$api_name"; then
      printf \
        '[api-inventory][PASS] Publisher: %s\n' \
        "$api_name"

      found=true
      break
    fi

    sleep 2
  done

  if [[ "$found" != "true" ]]; then
    fail \
      "API is absent or not PUBLISHED in Publisher: ${api_name}"
  fi
done

log "Checking Developer Portal inventory."

for api_name in "${devportal_expected[@]}"; do
  found=false

  for attempt in $(seq 1 30); do
    if devportal_visible "$api_name"; then
      printf \
        '[api-inventory][PASS] Developer Portal: %s\n' \
        "$api_name"

      found=true
      break
    fi

    sleep 2
  done

  if [[ "$found" != "true" ]]; then
    fail \
      "API is not visible in Developer Portal: ${api_name}"
  fi
done

log "Publisher and Developer Portal inventories are complete."
VERIFY

chmod +x "$INVENTORY_VERIFY"

cat > "$BASE_VERIFY" <<'VERIFY_WRAPPER'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"

exec \
  bash \
  "${ROOT_DIR}/scripts/verify-published-api-inventory.sh"
VERIFY_WRAPPER

chmod +x "$BASE_VERIFY"

###############################################################################
# 4. Validate every active correction before deleting anything.
###############################################################################

log "Running static preflight validation."

bash -n "$CONTROL"
bash -n "$OAUTH_RECONCILE"
bash -n "$SHORT_RECONCILE"
bash -n "$PERSONA_GENERATOR"
bash -n "$OAUTH_POST_START"
bash -n "$OAUTH_VERIFY"
bash -n "$INVENTORY_VERIFY"
bash -n "$BASE_VERIFY"

python3 -m py_compile \
  "$PERSONA_RESOLVER"

if command -v node >/dev/null 2>&1; then
  node --check "$OAUTH_SETUP"
  node --check "$PORTAL_SERVER"
fi

grep -Fq \
  'application_access_token_expiry_time' \
  "$OAUTH_SETUP" ||
  fail \
    "OAuth setup lacks application_access_token_expiry_time."

grep -Fq \
  'application_access_token_expiry_time' \
  "$SHORT_RECONCILE" ||
  fail \
    "Short-client reconciler lacks the correct expiry property."

if grep -Fq \
  'applicationAccessTokenExpiryTime' \
  "$OAUTH_SETUP"
then
  fail \
    "Obsolete camelCase expiry property remains in OAuth setup."
fi

if grep -Fq \
  'applicationAccessTokenExpiryTime' \
  "$SHORT_RECONCILE"
then
  fail \
    "Obsolete camelCase expiry property remains in short-client reconciliation."
fi

grep -Fq \
  'reconcile-short-lived-oauth-client.sh' \
  "$OAUTH_RECONCILE" ||
  fail \
    "OAuth reconciliation does not call the key-lifetime reconciler."

grep -Fq \
  'generate-oauth-persona-sequence.sh' \
  "$OAUTH_RECONCILE" ||
  fail \
    "OAuth reconciliation does not generate the MI persona registry."

grep -Fq \
  'resolve-oauth-persona-subjects.py' \
  "$PERSONA_GENERATOR" ||
  fail \
    "Persona generation is not using token-derived APIM subjects."

if grep -Fq \
  '/scim2/Users' \
  "$PERSONA_GENERATOR"
then
  fail \
    "Obsolete SCIM lookup remains in persona generation."
fi

grep -Fq \
  'https://127.0.0.1:9443/oauth2/token' \
  "$OAUTH_VERIFY" ||
  fail \
    "OAuth verifier is not using the correct token endpoint."

if grep -Fq \
  'validity_period=2' \
  "$OAUTH_VERIFY"
then
  fail \
    "OAuth verifier still contains the ignored validity_period hint."
fi

grep -Fq \
  "app.get('/portal-status'" \
  "$PORTAL_SERVER" ||
  fail \
    "demo-portal does not expose /portal-status."

for compose_file in \
  docker-compose.yml \
  docker-compose.mi.yml \
  docker-compose.oauth-business-controls.yml \
  docker-compose.runtime-persistence.yml
do
  [[ -f "$compose_file" ]] ||
    fail "Required Compose file is missing: $compose_file"
done

log "Active correction preflight passed."

###############################################################################
# 5. Build the exact full Compose model and validate it before reset.
###############################################################################

cat > docker-compose.runtime-persistence.yml <<'YAML'
services:
  wso2-apim:
    volumes:
      - apim-runtime-database:/home/wso2carbon/wso2am-4.7.0/repository/database

volumes:
  apim-runtime-database:
YAML

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif docker-compose version >/dev/null 2>&1; then
  DC=(docker-compose)
else
  fail "Docker Compose is unavailable."
fi

project="$(
  docker inspect \
    wso2-apim-4-7 \
    --format \
    '{{ index .Config.Labels "com.docker.compose.project" }}' \
    2>/dev/null ||
    true
)"

if [[ -z "$project" ]]; then
  project="$(
    basename "$ROOT" |
      tr '[:upper:]' '[:lower:]' |
      tr -c 'a-z0-9_-' '-'
  )"

  project="${project%-}"
fi

COMPOSE_FILES=(docker-compose.yml)

for file in \
  docker-compose.kafka.yml \
  docker-compose.opa.yml \
  docker-compose.central-policy.yml \
  docker-compose.mi.yml \
  docker-compose.oauth-business-controls.yml \
  docker-compose.commercial.yml \
  docker-compose.mi.soap.yml \
  docker-compose.observability.yml \
  docker-compose.audit-siem.yml \
  docker-compose.runtime-persistence.yml
do
  if [[ -f "$file" ]]; then
    COMPOSE_FILES+=("$file")
  fi
done

FULL_COMPOSE=(
  "${DC[@]}"
  -p "$project"
)

for file in "${COMPOSE_FILES[@]}"; do
  FULL_COMPOSE+=(
    -f "$file"
  )
done

log "Validating the complete Compose topology."

"${FULL_COMPOSE[@]}" config \
  >"$backup_dir/full-compose.yml"

services="$(
  "${FULL_COMPOSE[@]}" config --services
)"

for required_service in \
  wso2-apim \
  apim-bootstrapper \
  telco-backend \
  wso2-mi \
  demo-portal
do
  grep -Fxq \
    "$required_service" \
    <<<"$services" ||
    fail \
      "Complete Compose topology lacks service: ${required_service}"
done

echo "Compose project: $project"
echo "Compose files:"

for file in "${COMPOSE_FILES[@]}"; do
  echo "  $file"
done

###############################################################################
# 6. Clear host-side generated state, then remove the full stack and volumes.
###############################################################################

log "Removing stale host-side generated state."

rm -f \
  .runtime/oauth-business-controls.json \
  .runtime/developer-experience.json

mkdir -p .runtime

cat <<'WARNING'

[final-clean-reset] DESTRUCTIVE RESET

The following demo state will be removed:

  - APIM embedded runtime database;
  - APIs, API Products, applications and subscriptions;
  - OAuth keys and generated state;
  - demo portal runtime state;
  - observability demo volumes.

Repository source files and backups are preserved.

WARNING

log "Removing the complete stack and all named volumes."

COMPOSE_IGNORE_ORPHANS=true \
"${FULL_COMPOSE[@]}" down \
  --remove-orphans \
  --volumes \
  --timeout 30

###############################################################################
# 7. Run the canonical base lifecycle. It will build the complete topology,
#    bootstrap base APIs, create Regional Portal state and verify publication.
###############################################################################

log "Running the canonical base demo lifecycle."

COMPOSE_IGNORE_ORPHANS=true \
SKIP_BOOTSTRAP=false \
bash "$CONTROL" start

###############################################################################
# 8. Add the OAuth extension exactly once after the base bootstrap succeeds.
###############################################################################

log "Running OAuth business-control initialization exactly once."

COMPOSE_IGNORE_ORPHANS=true \
OAUTH_RECONCILE_ATTEMPTS=1 \
OAUTH_VERIFY_ATTEMPTS=1 \
bash "$OAUTH_POST_START"

###############################################################################
# 9. Final read-only verification. These commands never use Compose up/run.
###############################################################################

log "Running final OAuth runtime verification."

bash "$OAUTH_VERIFY"

log "Running final Publisher and Developer Portal inventory verification."

bash "$INVENTORY_VERIFY"

log "Checking final portal state."

curl -fsS \
  --connect-timeout 3 \
  --max-time 10 \
  http://127.0.0.1:8080/portal-status |
jq '{
  status,
  updatedAt,
  application: {
    name: .application.name,
    applicationId: .application.applicationId,
    hasConsumerKey,
    hasConsumerSecret
  },
  apiCount: (.apis | length)
}'

cat <<EOF

[final-clean-reset] COMPLETE

The environment was rebuilt from empty Docker volumes using the complete
Compose topology.

Publisher:
  https://localhost:9443/publisher

Developer Portal:
  https://localhost:9443/devportal

Admin Portal:
  https://localhost:9443/admin

Telco Portal:
  http://localhost:8080

Safe read-only base verification:
  bash scripts/verify-apim-bootstrap.sh

OAuth verification:
  bash scripts/verify-oauth-consent-risk-controls.sh

Backups:
  ${backup_dir}

EOF
