#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

RECONCILE="scripts/reconcile-oauth-control-plane.sh"
VERIFY="scripts/verify-oauth-consent-risk-controls.sh"
LIFETIME_SCRIPT="scripts/reconcile-short-lived-oauth-client.sh"

log() {
  printf '[short-client-installer] %s\n' "$*"
}

fail() {
  printf '[short-client-installer][FAIL] %s\n' "$*" >&2
  exit 1
}

for command in bash python3 curl jq docker; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Required command is missing: $command"
done

for file in \
  "$RECONCILE" \
  "$VERIFY" \
  scripts/read-oauth-business-state.sh \
  scripts/complete-oauth-post-start.sh
do
  [[ -f "$file" ]] ||
    fail "Required file is missing: $file"
done

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/short-client-reconciler-${timestamp}"

mkdir -p "$backup_dir"

cp "$RECONCILE" \
  "$backup_dir/reconcile-oauth-control-plane.sh"

cp "$VERIFY" \
  "$backup_dir/verify-oauth-consent-risk-controls.sh"

log "Backups written under $backup_dir"

cat > "$LIFETIME_SCRIPT" <<'RECONCILER'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"
cd "$ROOT_DIR"

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
TOKEN_URL="${WSO2_APIM_TOKEN_URL:-${APIM_URL}/oauth2/token}"

APIM_USERNAME="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"

WORK_DIR="$(
  mktemp -d \
    "${TMPDIR:-/tmp}/short-oauth-client.XXXXXX"
)"

trap 'rm -rf "$WORK_DIR"' EXIT

chmod 700 "$WORK_DIR"

log() {
  printf '[short-client-reconcile] %s\n' "$*"
}

fail() {
  printf '[short-client-reconcile][FAIL] %s\n' "$*" >&2
  exit 1
}

redact_token_response() {
  jq '
    del(
      .access_token,
      .accessToken,
      .refresh_token,
      .refreshToken,
      .id_token,
      .idToken
    )
  ' 2>/dev/null ||
    cat
}

###############################################################################
# Read the generated OAuth state.
###############################################################################

log "Reading current OAuth bootstrap state."

bash scripts/read-oauth-business-state.sh \
  >"$WORK_DIR/state.raw"

python3 - \
  "$WORK_DIR/state.raw" \
  "$WORK_DIR/short-client.json" <<'PY'
from pathlib import Path
import json
import re
import sys

raw_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])

raw = raw_path.read_text(
    encoding="utf-8",
    errors="replace",
)

decoder = json.JSONDecoder()
documents = []

for index, character in enumerate(raw):
    if character != "{":
        continue

    try:
        value, consumed = decoder.raw_decode(
            raw[index:]
        )
    except json.JSONDecodeError:
        continue

    if isinstance(value, dict):
        documents.append(
            (
                consumed,
                value,
            )
        )

if not documents:
    raise SystemExit(
        "[short-client-reconcile][FAIL] "
        "Could not parse OAuth state JSON."
    )

documents.sort(
    key=lambda item: item[0],
    reverse=True,
)

state = documents[0][1]


def normalized_key(value):
    return re.sub(
        r"[^a-z0-9]",
        "",
        str(value).lower(),
    )


def walk(value):
    if isinstance(value, dict):
        yield value

        for child in value.values():
            yield from walk(child)

    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


target = None

application_section = state.get("application")

if isinstance(application_section, dict):
    exact_target = application_section.get(
        "expiredTokenClient"
    )

    if isinstance(exact_target, dict):
        target = exact_target

if target is None:
    candidates = []

    for obj in walk(state):
        text = json.dumps(
            obj,
            separators=(",", ":"),
        ).lower()

        score = 0

        for marker, weight in (
            ("expiredtokenclient", 100),
            ("two-second", 90),
            ("two second", 90),
            ("short-lived", 80),
            ("shortlived", 80),
            ("expiry", 60),
            ("expired", 60),
        ):
            if marker in text:
                score += weight

        if score:
            candidates.append(
                (
                    score,
                    obj,
                )
            )

    if candidates:
        candidates.sort(
            key=lambda item: item[0],
            reverse=True,
        )

        target = candidates[0][1]

if not isinstance(target, dict):
    raise SystemExit(
        "[short-client-reconcile][FAIL] "
        "Could not locate application.expiredTokenClient."
    )


def find_value(aliases):
    normalized_aliases = {
        normalized_key(alias)
        for alias in aliases
    }

    for obj in walk(target):
        for key, value in obj.items():
            if (
                normalized_key(key)
                in normalized_aliases
                and isinstance(value, str)
                and value
            ):
                return value

    return ""


application_id = find_value(
    (
        "applicationId",
        "applicationUuid",
        "applicationUUID",
        "appId",
        "appUuid",
    )
)

consumer_key = find_value(
    (
        "consumerKey",
        "consumer_key",
        "clientId",
        "client_id",
    )
)

consumer_secret = find_value(
    (
        "consumerSecret",
        "consumer_secret",
        "clientSecret",
        "client_secret",
    )
)

key_mapping_id = find_value(
    (
        "keyMappingId",
        "key_mapping_id",
        "mappingId",
        "mappingUuid",
    )
)

if not consumer_key or not consumer_secret:
    raise SystemExit(
        "[short-client-reconcile][FAIL] "
        "Short-lived consumer credentials are absent."
    )

output_path.write_text(
    json.dumps(
        {
            "applicationId": application_id,
            "keyMappingId": key_mapping_id,
            "consumerKey": consumer_key,
            "consumerSecret": consumer_secret,
        },
        separators=(",", ":"),
    ),
    encoding="utf-8",
)

output_path.chmod(0o600)
PY

application_id="$(
  jq -r \
    '.applicationId // empty' \
    "$WORK_DIR/short-client.json"
)"

consumer_key="$(
  jq -r \
    '.consumerKey // empty' \
    "$WORK_DIR/short-client.json"
)"

consumer_secret="$(
  jq -r \
    '.consumerSecret // empty' \
    "$WORK_DIR/short-client.json"
)"

[[ -n "$consumer_key" &&
   -n "$consumer_secret" ]] ||
  fail "Short-lived OAuth credentials were not resolved."

###############################################################################
# Obtain a Developer Portal management token.
###############################################################################

log "Obtaining Developer Portal management token."

dcr_payload="$(
  jq -nc \
    --arg name \
      "short-client-reconciler-$(date +%s)-$$" '
      {
        callbackUrl:
          "http://localhost:8080/callback",
        clientName: $name,
        owner: "admin",
        grantType:
          "password refresh_token client_credentials",
        saasApp: true
      }
    '
)"

dcr_response="$(
  curl -ksS \
    -u "${APIM_USERNAME}:${APIM_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d "${dcr_payload}" \
    "${APIM_URL}/client-registration/v0.17/register"
)"

management_client_id="$(
  jq -r \
    '.clientId // empty' \
    <<<"${dcr_response}"
)"

management_client_secret="$(
  jq -r \
    '.clientSecret // empty' \
    <<<"${dcr_response}"
)"

if [[ -z "$management_client_id" ||
      -z "$management_client_secret" ]]
then
  printf '%s\n' "$dcr_response" >&2
  fail "Dynamic client registration failed."
fi

management_token_response="$(
  curl -ksS \
    -u \
      "${management_client_id}:${management_client_secret}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode \
      "username=${APIM_USERNAME}" \
    --data-urlencode \
      "password=${APIM_PASSWORD}" \
    --data-urlencode \
      'scope=apim:subscribe apim:app_manage' \
    "${TOKEN_URL}"
)"

management_token="$(
  jq -r \
    '.access_token // empty' \
    <<<"${management_token_response}"
)"

if [[ -z "$management_token" ]]; then
  printf '%s\n' \
    "$management_token_response" |
    redact_token_response >&2

  fail "Developer Portal token acquisition failed."
fi

###############################################################################
# Resolve the application and key mapping using the actual consumer key.
###############################################################################

find_mapping_in_application() {
  local candidate_application_id="$1"
  local keys

  keys="$(
    curl -ksS \
      -H "Authorization: Bearer ${management_token}" \
      "${APIM_URL}/api/am/devportal/v3/applications/${candidate_application_id}/oauth-keys"
  )"

  jq -c \
    --arg consumer_key "$consumer_key" '
      first(
        (.list // .data // [])[]?
        | select(
            .consumerKey == $consumer_key
          )
      ) // empty
    ' <<<"$keys"
}

mapping_json=""

if [[ -n "$application_id" ]]; then
  mapping_json="$(
    find_mapping_in_application \
      "$application_id"
  )"
fi

if [[ -z "$mapping_json" ]]; then
  log \
    "Stored application ID was unavailable or stale; searching Developer Portal applications."

  applications="$(
    curl -ksS \
      -H "Authorization: Bearer ${management_token}" \
      "${APIM_URL}/api/am/devportal/v3/applications?limit=1000"
  )"

  while IFS= read -r candidate_application_id; do
    [[ -n "$candidate_application_id" ]] ||
      continue

    candidate_mapping="$(
      find_mapping_in_application \
        "$candidate_application_id"
    )"

    if [[ -n "$candidate_mapping" ]]; then
      application_id="$candidate_application_id"
      mapping_json="$candidate_mapping"
      break
    fi
  done < <(
    jq -r '
      (.list // .data // [])[]?
      | .applicationId // .id // empty
    ' <<<"$applications"
  )
fi

[[ -n "$application_id" &&
   -n "$mapping_json" ]] ||
  fail \
    "Could not resolve the short-lived application key mapping."

key_mapping_id="$(
  jq -r \
    '.keyMappingId // empty' \
    <<<"$mapping_json"
)"

[[ -n "$key_mapping_id" ]] ||
  fail "The short-lived key mapping has no keyMappingId."

log \
  "Resolved application ${application_id} and key mapping ${key_mapping_id}."

###############################################################################
# Revoke any reusable 3600-second client-credentials token.
###############################################################################

old_token_response="$(
  curl -ksS \
    -u "${consumer_key}:${consumer_secret}" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode \
      'grant_type=client_credentials' \
    --data-urlencode \
      'scope=default' \
    "${TOKEN_URL}"
)"

old_token="$(
  jq -r \
    '.access_token // empty' \
    <<<"${old_token_response}"
)"

if [[ -n "$old_token" ]]; then
  curl -ksS \
    -u "${consumer_key}:${consumer_secret}" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode \
      "token=${old_token}" \
    --data-urlencode \
      'token_type_hint=access_token' \
    "${APIM_URL}/oauth2/revoke" \
    >/dev/null

  log "Revoked the previously issued application token."
fi

###############################################################################
# Retrieve and update the OAuth key mapping.
###############################################################################

current_key="$(
  curl -ksS \
    -H "Authorization: Bearer ${management_token}" \
    "${APIM_URL}/api/am/devportal/v3/applications/${application_id}/oauth-keys/${key_mapping_id}"
)"

if ! jq -e \
  '.keyMappingId and .keyManager and .keyType' \
  <<<"$current_key" \
  >/dev/null
then
  printf '%s\n' "$current_key" |
    jq 'del(.consumerSecret, .consumerSecrets, .token)' \
    >&2 ||
    true

  fail "Could not retrieve current key-mapping details."
fi

update_payload="$(
  jq -nc \
    --argjson current "$current_key" '
      def existing_properties:
        if (
          $current.additionalProperties
          | type
        ) == "object"
        then
          $current.additionalProperties

        elif (
          $current.additionalProperties
          | type
        ) == "string"
        then
          (
            try (
              $current.additionalProperties
              | fromjson
            )
            catch {}
          )

        else
          {}
        end;

      {
        keyMappingId:
          $current.keyMappingId,

        keyManager:
          (
            $current.keyManager //
            "Resident Key Manager"
          ),

        keyType:
          (
            $current.keyType //
            "PRODUCTION"
          ),

        supportedGrantTypes:
          (
            (
              $current.supportedGrantTypes //
              []
            )
            + [
                "client_credentials"
              ]
            | unique
          ),

        callbackUrl:
          (
            $current.callbackUrl //
            "http://localhost/callback"
          ),

        groupId:
          $current.groupId,

        additionalProperties:
          (
            existing_properties
            + {
                applicationAccessTokenExpiryTime:
                  "2",

                userAccessTokenExpiryTime:
                  "2"
              }
          )
      }
      | with_entries(
          select(.value != null)
        )
    '
)"

update_status="$(
  curl -ksS \
    -o "$WORK_DIR/update-response.json" \
    -w '%{http_code}' \
    -X PUT \
    -H \
      "Authorization: Bearer ${management_token}" \
    -H \
      'Content-Type: application/json' \
    -d "$update_payload" \
    "${APIM_URL}/api/am/devportal/v3/applications/${application_id}/oauth-keys/${key_mapping_id}"
)"

case "$update_status" in
  200)
    ;;
  *)
    jq '
      del(
        .consumerSecret,
        .consumerSecrets,
        .token
      )
    ' "$WORK_DIR/update-response.json" >&2 ||
      cat \
        "$WORK_DIR/update-response.json" >&2

    fail \
      "OAuth key-mapping update failed with HTTP ${update_status}."
    ;;
esac

log \
  "Applied applicationAccessTokenExpiryTime=2 through the APIM key-mapping API."

###############################################################################
# Read the mapping back and validate the persisted OAuth-client property.
###############################################################################

updated_key="$(
  curl -ksS \
    -H "Authorization: Bearer ${management_token}" \
    "${APIM_URL}/api/am/devportal/v3/applications/${application_id}/oauth-keys/${key_mapping_id}"
)"

if ! jq -e '
  def properties:
    if (
      .additionalProperties
      | type
    ) == "object"
    then
      .additionalProperties

    elif (
      .additionalProperties
      | type
    ) == "string"
    then
      (
        try (
          .additionalProperties
          | fromjson
        )
        catch {}
      )

    else
      {}
    end;

  (
    properties
    | .applicationAccessTokenExpiryTime
    | tonumber
  ) == 2
' <<<"$updated_key" >/dev/null
then
  jq '
    del(
      .consumerSecret,
      .consumerSecrets,
      .token
    )
  ' <<<"$updated_key" >&2 ||
    true

  fail \
    "APIM did not persist applicationAccessTokenExpiryTime=2."
fi

log \
  "APIM reports applicationAccessTokenExpiryTime=2 for the OAuth client."

###############################################################################
# Request a new token without a per-request validity override.
###############################################################################

token_response="$(
  curl -ksS \
    -u "${consumer_key}:${consumer_secret}" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode \
      'grant_type=client_credentials' \
    --data-urlencode \
      'scope=default' \
    "${TOKEN_URL}"
)"

access_token="$(
  jq -r \
    '.access_token // empty' \
    <<<"${token_response}"
)"

expires_in="$(
  jq -r \
    '.expires_in // 0' \
    <<<"${token_response}"
)"

jwt_lifetime="$(
  python3 - "$access_token" <<'PY'
import base64
import json
import sys

token = sys.argv[1]

if not token:
    print(0)
    raise SystemExit(0)

parts = token.split(".")

if len(parts) < 2:
    print(0)
    raise SystemExit(0)

payload = parts[1]
payload += "=" * (
    (4 - len(payload) % 4) % 4
)

try:
    claims = json.loads(
        base64.urlsafe_b64decode(
            payload.encode("ascii")
        ).decode("utf-8")
    )

    issued_at = int(
        claims.get("iat", 0)
    )

    expires_at = int(
        claims.get("exp", 0)
    )

    if issued_at > 0 and expires_at > 0:
        print(expires_at - issued_at)
    else:
        print(0)

except Exception:
    print(0)
PY
)"

if [[ -z "$access_token" ]]; then
  printf '%s\n' "$token_response" |
    redact_token_response >&2

  fail \
    "The updated OAuth client did not issue an access token."
fi

if ! [[ "$expires_in" =~ ^[0-9]+$ ]] ||
   (( expires_in < 1 || expires_in > 2 ))
then
  printf '%s\n' "$token_response" |
    redact_token_response >&2

  fail \
    "Updated OAuth client returned expires_in=${expires_in}; expected 1-2."
fi

if ! [[ "$jwt_lifetime" =~ ^[0-9]+$ ]] ||
   (( jwt_lifetime < 1 || jwt_lifetime > 2 ))
then
  fail \
    "Updated OAuth client JWT lifetime=${jwt_lifetime}; expected 1-2."
fi

log \
  "Verified two-second client lifetime: expires_in=${expires_in}, JWT lifetime=${jwt_lifetime}."
RECONCILER

chmod +x "$LIFETIME_SCRIPT"

###############################################################################
# Add the authoritative key-mapping reconciliation to every OAuth cycle.
###############################################################################

python3 - "$RECONCILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

call = (
    "bash scripts/"
    "reconcile-short-lived-oauth-client.sh"
)

if call in text:
    print(
        "[short-client-installer] "
        "OAuth reconciliation hook already exists."
    )

    raise SystemExit(0)

anchors = (
    'log "Generating the MI persona registry',
    'bash scripts/generate-oauth-persona-sequence.sh',
)

position = -1

for anchor in anchors:
    position = text.find(anchor)

    if position >= 0:
        break

if position < 0:
    raise SystemExit(
        "[short-client-installer][FAIL] "
        "Could not locate the persona-registry phase "
        "inside reconcile-oauth-control-plane.sh."
    )

block = '''log "Reconciling the two-second OAuth client lifetime through the APIM key-mapping API."
bash scripts/reconcile-short-lived-oauth-client.sh

'''

updated = (
    text[:position]
    + block
    + text[position:]
)

path.write_text(
    updated,
    encoding="utf-8",
)

print(
    "[short-client-installer] "
    "Installed OAuth key-lifetime reconciliation hook."
)
PY

###############################################################################
# The verifier must test the configured client lifetime, not a request hint.
###############################################################################

python3 - "$VERIFY" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(
    encoding="utf-8",
).splitlines()

updated = []
removed = 0

for line in lines:
    if (
        "--data-urlencode "
        "'validity_period=2'"
        in line
    ):
        removed += 1
        continue

    updated.append(line)

text = "\n".join(updated) + "\n"

text = text.replace(
    "For an exact two-second runtime\n"
    "# test, call the WSO2 token endpoint "
    "directly with validity_period=2.",
    "The OAuth client's application access-token "
    "lifetime is reconciled to two seconds.\n"
    "# Request the token directly and verify the "
    "persisted client configuration.",
)

path.write_text(
    text,
    encoding="utf-8",
)

print(
    "[short-client-installer] "
    f"Removed {removed} per-request validity override(s) "
    "from the verifier."
)
PY

###############################################################################
# Static validation.
###############################################################################

chmod +x \
  "$RECONCILE" \
  "$VERIFY"

bash -n "$LIFETIME_SCRIPT"
bash -n "$RECONCILE"
bash -n "$VERIFY"
bash -n scripts/complete-oauth-post-start.sh

grep -Fq \
  'reconcile-short-lived-oauth-client.sh' \
  "$RECONCILE" ||
  fail "Key-lifetime reconciliation hook is absent."

if grep -Fq \
  'validity_period=2' \
  "$VERIFY"
then
  fail \
    "The obsolete per-request validity hint remains in the verifier."
fi

log "Static installation passed."

###############################################################################
# Run the exact lifecycle that a future restart will use.
###############################################################################

log \
  "Running one complete OAuth reconciliation and verification cycle."

COMPOSE_IGNORE_ORPHANS=1 \
OAUTH_RECONCILE_ATTEMPTS=1 \
OAUTH_VERIFY_ATTEMPTS=1 \
bash scripts/complete-oauth-post-start.sh

cat <<EOF

[short-client-installer] COMPLETE

The restart lifecycle now performs:

  OAuth application/key creation
  → key-mapping lifetime update
  → old-token revocation
  → actual two-second token verification
  → MI persona reconciliation
  → complete OAuth verification

Backups:
  ${backup_dir}

EOF
