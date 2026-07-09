#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

log() {
  printf '[final-oauth-logic] %s\n' "$*"
}

fail() {
  printf '[final-oauth-logic][FAIL] %s\n' "$*" >&2
  exit 1
}

required_commands=(
  bash
  python3
  docker
  curl
  jq
)

for command in "${required_commands[@]}"; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Required command is missing: $command"
done

OAUTH_JS="services/apim-bootstrapper/src/oauth-business-controls-setup.js"
CONTEXT_XML="services/wso2-mi/synapse-configs/default/sequences/SubscriberAuthorizationContextSequence.xml"
RECONCILE="scripts/reconcile-oauth-control-plane.sh"
VERIFY="scripts/verify-oauth-consent-risk-controls.sh"
COMPOSE_CONTEXT="scripts/oauth-compose-context.sh"

required_files=(
  "$OAUTH_JS"
  "$CONTEXT_XML"
  "$RECONCILE"
  "$VERIFY"
  "$COMPOSE_CONTEXT"
  scripts/complete-oauth-post-start.sh
  docker-compose.yml
)

for file in "${required_files[@]}"; do
  [[ -f "$file" ]] ||
    fail "Required file is missing: $file"
done

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/final-oauth-logic-${timestamp}"

mkdir -p "$backup_dir"

for file in \
  "$OAUTH_JS" \
  "$CONTEXT_XML" \
  "$RECONCILE" \
  "$VERIFY"
do
  cp \
    "$file" \
    "$backup_dir/$(printf '%s' "$file" | tr '/' '_')"
done

log "Backups written under $backup_dir"

###############################################################################
# 1. One authoritative, read-only deployment-state checker
###############################################################################

cat > scripts/check-oauth-api-deployment.sh <<'DEPLOYMENT_CHECK'
#!/usr/bin/env bash
set -Eeuo pipefail

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"

API_NAME="SubscriberAuthorizationControlAPI"
API_VERSION="1.0.0"
API_CONTEXT="/subscriber-authorization/v1"

fail() {
  printf '[oauth-deployment-check][FAIL] %s\n' "$*" >&2
  exit 1
}

work_dir="$(
  mktemp -d \
    "${TMPDIR:-/tmp}/oauth-deployment-check.XXXXXX"
)"

trap 'rm -rf "$work_dir"' EXIT

dcr_response="$(
  curl -ksS \
    -u "${APIM_USER}:${APIM_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d "{
      \"callbackUrl\":\"http://localhost:8080/callback\",
      \"clientName\":\"oauth-deployment-check-$(date +%s)-$$\",
      \"owner\":\"${APIM_USER}\",
      \"grantType\":\"password refresh_token client_credentials\",
      \"saasApp\":true
    }" \
    "${APIM_URL}/client-registration/v0.17/register"
)"

client_id="$(
  jq -r '.clientId // empty' \
    <<<"$dcr_response"
)"

client_secret="$(
  jq -r '.clientSecret // empty' \
    <<<"$dcr_response"
)"

[[ -n "$client_id" && -n "$client_secret" ]] || {
  printf '%s\n' "$dcr_response" >&2
  fail "Dynamic client registration failed."
}

token_response="$(
  curl -ksS \
    -u "${client_id}:${client_secret}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${APIM_USER}" \
    --data-urlencode "password=${APIM_PASSWORD}" \
    --data-urlencode \
      'scope=apim:api_view apim:api_manage apim:api_publish' \
    "${APIM_URL}/oauth2/token"
)"

publisher_token="$(
  jq -r '.access_token // empty' \
    <<<"$token_response"
)"

[[ -n "$publisher_token" ]] || {
  printf '%s\n' "$token_response" >&2
  fail "Publisher token acquisition failed."
}

api_list="$(
  curl -kfsS \
    -H "Authorization: Bearer ${publisher_token}" \
    "${APIM_URL}/api/am/publisher/v4/apis?limit=1000"
)"

api_id="$(
  jq -r \
    --arg name "$API_NAME" \
    --arg version "$API_VERSION" '
      first(
        (.list // .data // [])[]?
        | select(
            .name == $name and
            (.version // "") == $version
          )
        | .id
      ) // empty
    ' \
    <<<"$api_list"
)"

[[ -n "$api_id" ]] ||
  fail "${API_NAME}:${API_VERSION} was not found."

deployments="$(
  curl -kfsS \
    -H "Authorization: Bearer ${publisher_token}" \
    "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/deployments"
)"

revisions="$(
  curl -kfsS \
    -H "Authorization: Bearer ${publisher_token}" \
    "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/revisions?limit=100"
)"

has_successful_deployment() {
  jq -e '
    def top_level_items:
      if type == "array" then .
      elif type == "object" then
        (
          .list //
          .data //
          .deployments //
          .deploymentInfo //
          []
        )
      else []
      end;

    def revision_deployments:
      [
        (
          .list //
          .data //
          (if type == "array" then . else [] end)
        )[]?
        | (.deploymentInfo // [])[]?
      ];

    def successful($item):
      (
        ($item.status // "") == "APPROVED"
      ) and (
        (($item.deployedGatewayCount // 0) > 0) or
        (($item.successDeployedTime // null) != null)
      );

    any(top_level_items[]?; successful(.)) or
    any(revision_deployments[]?; successful(.))
  ' >/dev/null 2>&1
}

if has_successful_deployment <<<"$deployments" ||
   has_successful_deployment <<<"$revisions"
then
  printf '[oauth-deployment-check] %s has a successful Gateway deployment.\n' \
    "$API_NAME"

  exit 0
fi

# A Gateway OAuth rejection proves that the API route exists and is secured.
gateway_status="$(
  curl -ksS \
    -o "$work_dir/gateway-response.json" \
    -w '%{http_code}' \
    -X POST \
    -H 'Content-Type: application/json' \
    -d '{}' \
    "https://127.0.0.1:8243${API_CONTEXT}/number-verifications" ||
    true
)"

case "$gateway_status" in
  401|403)
    printf '[oauth-deployment-check] %s route is active on the Gateway.\n' \
      "$API_NAME"

    exit 0
    ;;
esac

echo "[oauth-deployment-check] Publisher deployments:" >&2
jq . <<<"$deployments" >&2 ||
  printf '%s\n' "$deployments" >&2

echo "[oauth-deployment-check] Publisher revisions:" >&2
jq . <<<"$revisions" >&2 ||
  printf '%s\n' "$revisions" >&2

echo "[oauth-deployment-check] Gateway status: $gateway_status" >&2

fail "$API_NAME does not have a successful Gateway deployment."
DEPLOYMENT_CHECK

chmod +x scripts/check-oauth-api-deployment.sh

###############################################################################
# 2. Generate MI persona mappings from authoritative SCIM user UUIDs
###############################################################################

cat > scripts/generate-oauth-persona-sequence.sh <<'PERSONA_GENERATOR'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"
cd "$ROOT_DIR"

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"

TARGET="services/wso2-mi/synapse-configs/default/sequences/SubscriberAuthorizationContextSequence.xml"

log() {
  printf '[oauth-persona-registry] %s\n' "$*"
}

fail() {
  printf '[oauth-persona-registry][FAIL] %s\n' "$*" >&2
  exit 1
}

lookup_user_id() {
  local username="$1"
  local response
  local user_id

  response="$(
    curl -kfsS \
      -u "${APIM_USER}:${APIM_PASSWORD}" \
      --get \
      --data-urlencode "filter=userName eq \"${username}\"" \
      --data-urlencode 'count=10' \
      "${APIM_URL}/scim2/Users"
  )"

  user_id="$(
    jq -r \
      --arg username "$username" '
        first(
          (.Resources // [])[]?
          | select(
              .userName == $username or
              .userName == ($username + "@carbon.super") or
              (.userName | endswith("/" + $username))
            )
          | .id
        ) // empty
      ' \
      <<<"$response"
  )"

  [[ -n "$user_id" ]] || {
    printf '%s\n' "$response" >&2
    fail "Could not resolve SCIM ID for ${username}."
  }

  printf '%s' "$user_id"
}

partner_alpha_id="$(lookup_user_id partner.alpha)"
partner_beta_id="$(lookup_user_id partner.beta)"
operations_id="$(lookup_user_id telco.operations)"
product_id="$(lookup_user_id telco.product)"
admin_id="$(lookup_user_id telco.admin)"

registry_json="$(
  jq -cn \
    --arg partner_alpha_id "$partner_alpha_id" \
    --arg partner_beta_id "$partner_beta_id" \
    --arg operations_id "$operations_id" \
    --arg product_id "$product_id" \
    --arg admin_id "$admin_id" '
      {
        ($partner_alpha_id): {
          username: "partner.alpha",
          persona: "partner",
          partnerId: "partner-alpha",
          countries: "BR"
        },
        "partner.alpha": {
          username: "partner.alpha",
          persona: "partner",
          partnerId: "partner-alpha",
          countries: "BR"
        },

        ($partner_beta_id): {
          username: "partner.beta",
          persona: "partner",
          partnerId: "partner-beta",
          countries: "MX"
        },
        "partner.beta": {
          username: "partner.beta",
          persona: "partner",
          partnerId: "partner-beta",
          countries: "MX"
        },

        ($operations_id): {
          username: "telco.operations",
          persona: "operations",
          partnerId: "*",
          countries: "BR,MX,CO,AR,PE,CL"
        },
        "telco.operations": {
          username: "telco.operations",
          persona: "operations",
          partnerId: "*",
          countries: "BR,MX,CO,AR,PE,CL"
        },

        ($product_id): {
          username: "telco.product",
          persona: "product_manager",
          partnerId: "*",
          countries: "BR,MX,CO,AR,PE,CL"
        },
        "telco.product": {
          username: "telco.product",
          persona: "product_manager",
          partnerId: "*",
          countries: "BR,MX,CO,AR,PE,CL"
        },

        ($admin_id): {
          username: "telco.admin",
          persona: "platform_administrator",
          partnerId: "*",
          countries: "*"
        },
        "telco.admin": {
          username: "telco.admin",
          persona: "platform_administrator",
          partnerId: "*",
          countries: "*"
        },

        "admin": {
          username: "admin",
          persona: "platform_administrator",
          partnerId: "*",
          countries: "*"
        }
      }
    '
)"

temporary_file="$(
  mktemp \
    "${TMPDIR:-/tmp}/SubscriberAuthorizationContextSequence.XXXXXX.xml"
)"

trap 'rm -f "$temporary_file"' EXIT

REGISTRY_JSON="$registry_json" \
python3 - "$temporary_file" <<'PY'
from pathlib import Path
import json
import os
import sys

target = Path(sys.argv[1])
registry = json.loads(os.environ["REGISTRY_JSON"])
registry_literal = json.dumps(
    registry,
    separators=(",", ":"),
)

xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<sequence name="SubscriberAuthorizationContextSequence"
          trace="disable"
          xmlns="http://ws.apache.org/ns/synapse">

    <property name="correlation.id"
              expression="$trp:X-Correlation-ID"
              scope="default"
              type="STRING"/>

    <filter xpath="not(normalize-space(get-property('correlation.id')))">
        <then>
            <property name="correlation.id"
                      expression="get-property('MessageID')"
                      scope="default"
                      type="STRING"/>
        </then>
    </filter>

    <header name="X-Correlation-ID"
            expression="get-property('correlation.id')"
            scope="transport"/>

    <property name="backend.jwt"
              expression="$trp:X-JWT-Assertion"
              scope="default"
              type="STRING"/>

    <script language="js"><![CDATA[
        var registry = {registry_literal};
        var jwt = String(
            mc.getProperty('backend.jwt') || ''
        );

        var subjectRaw = '';
        var username = '';
        var persona = '';
        var partnerId = '';
        var countries = '';
        var claimKeys = '';

        function decodeBase64Url(value) {{
            var alphabet =
                'ABCDEFGHIJKLMNOPQRSTUVWXYZ' +
                'abcdefghijklmnopqrstuvwxyz' +
                '0123456789+/';

            var normalized = String(value || '')
                .replace(/-/g, '+')
                .replace(/_/g, '/');

            while (normalized.length % 4 !== 0) {{
                normalized += '=';
            }}

            var bytes = '';
            var buffer = 0;
            var bits = 0;

            for (
                var index = 0;
                index < normalized.length;
                index++
            ) {{
                var character =
                    normalized.charAt(index);

                if (character === '=') {{
                    break;
                }}

                var alphabetIndex =
                    alphabet.indexOf(character);

                if (alphabetIndex < 0) {{
                    continue;
                }}

                buffer =
                    (buffer << 6) |
                    alphabetIndex;

                bits += 6;

                if (bits >= 8) {{
                    bits -= 8;

                    bytes += String.fromCharCode(
                        (buffer >> bits) & 255
                    );
                }}
            }}

            try {{
                var encoded = '';

                for (
                    var byteIndex = 0;
                    byteIndex < bytes.length;
                    byteIndex++
                ) {{
                    var hex =
                        bytes
                            .charCodeAt(byteIndex)
                            .toString(16);

                    encoded +=
                        '%' +
                        (
                            hex.length === 1
                                ? '0' + hex
                                : hex
                        );
                }}

                return decodeURIComponent(encoded);
            }} catch (ignored) {{
                return bytes;
            }}
        }}

        function normalizeIdentity(value) {{
            if (
                value === null ||
                typeof value === 'undefined'
            ) {{
                return '';
            }}

            var normalized = String(value)
                .replace(/^\\s+|\\s+$/g, '')
                .replace(/^"+|"+$/g, '')
                .replace(/@carbon\\.super$/i, '')
                .replace(/^PRIMARY\\//i, '')
                .replace(/^Internal\\//i, '');

            if (
                normalized.indexOf('/') >= 0
            ) {{
                var pieces =
                    normalized.split('/');

                normalized =
                    pieces[pieces.length - 1];
            }}

            return normalized;
        }}

        try {{
            var token = jwt;

            if (
                token.indexOf('.') < 0 &&
                token.length > 0
            ) {{
                var outerDecoded =
                    decodeBase64Url(token);

                if (
                    outerDecoded.indexOf('.') >= 0
                ) {{
                    token = outerDecoded;
                }}
            }}

            var tokenParts =
                token.split('.');

            if (tokenParts.length >= 2) {{
                var claims = JSON.parse(
                    decodeBase64Url(
                        tokenParts[1]
                    )
                );

                var keys = [];

                for (var key in claims) {{
                    if (
                        Object.prototype
                            .hasOwnProperty
                            .call(claims, key)
                    ) {{
                        keys.push(key);
                    }}
                }}

                claimKeys = keys.join(',');

                var candidates = [
                    claims[
                        'http://wso2.org/claims/enduser'
                    ],
                    claims[
                        'http://wso2.org/claims/username'
                    ],
                    claims.preferred_username,
                    claims.username,
                    claims.sub
                ];

                subjectRaw = String(
                    candidates[0] ||
                    candidates[candidates.length - 1] ||
                    ''
                );

                for (
                    var candidateIndex = 0;
                    candidateIndex < candidates.length;
                    candidateIndex++
                ) {{
                    var candidate =
                        normalizeIdentity(
                            candidates[candidateIndex]
                        );

                    if (
                        candidate &&
                        registry[candidate]
                    ) {{
                        var identity =
                            registry[candidate];

                        username =
                            identity.username;

                        persona =
                            identity.persona;

                        partnerId =
                            identity.partnerId;

                        countries =
                            identity.countries;

                        break;
                    }}
                }}
            }}
        }} catch (error) {{
            mc.setProperty(
                'backend.jwt.decode.error',
                String(error)
            );
        }}

        mc.setProperty(
            'backend.jwt.subject.raw',
            subjectRaw
        );

        mc.setProperty(
            'backend.jwt.claim.keys',
            claimKeys
        );

        mc.setProperty(
            'authenticated.user',
            username
        );

        mc.setProperty(
            'persona',
            persona
        );

        mc.setProperty(
            'authorized.partner.id',
            partnerId
        );

        mc.setProperty(
            'authorized.countries',
            countries
        );
    ]]></script>
</sequence>
'''

target.write_text(
    xml,
    encoding="utf-8",
)
PY

if cmp -s "$temporary_file" "$TARGET"; then
  log "Persona registry is unchanged; MI recreation is unnecessary."
  exit 0
fi

cp "$temporary_file" "$TARGET"

log "Updated MI persona registry:"
log "  partner.alpha     -> $partner_alpha_id"
log "  partner.beta      -> $partner_beta_id"
log "  telco.operations  -> $operations_id"
log "  telco.product     -> $product_id"
log "  telco.admin       -> $admin_id"

source scripts/oauth-compose-context.sh
resolve_oauth_compose_context "$ROOT_DIR"

services="$(
  "${OAUTH_COMPOSE[@]}" config --services
)"

grep -Fxq 'wso2-mi' <<<"$services" ||
  fail "wso2-mi is absent from the Compose topology."

log "Rebuilding MI with the updated persona registry."

"${OAUTH_COMPOSE[@]}" build wso2-mi

log "Recreating MI."

"${OAUTH_COMPOSE[@]}" up \
  -d \
  --no-deps \
  --force-recreate \
  wso2-mi

log "Waiting for the MI subscriber-authorization API."

for attempt in $(seq 1 180); do
  if curl -fsS \
    http://localhost:8290/subscriber-authorization/v1/health \
    >/dev/null 2>&1
  then
    log "MI persona registry is active."
    exit 0
  fi

  sleep 2
done

fail "MI did not become ready after persona-registry deployment."
PERSONA_GENERATOR

chmod +x scripts/generate-oauth-persona-sequence.sh

###############################################################################
# 3. Patch short-lived OAuth key generation using WSO2 key-manager properties
###############################################################################

python3 - "$OAUTH_JS" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

if (
    "applicationAccessTokenExpiryTime: 2" in text
    and "userAccessTokenExpiryTime: 2" in text
):
    print(
        "[final-oauth-logic] "
        "Short-lived key properties are already installed."
    )
else:
    validity_matches = list(
        re.finditer(
            r"\bvalidityTime\s*:\s*2\b",
            text,
        )
    )

    if not validity_matches:
        raise SystemExit(
            "[final-oauth-logic][FAIL] "
            "Could not find the two-second key-generation payload."
        )

    ranked = []

    for match in validity_matches:
        start = max(0, match.start() - 2000)
        end = min(len(text), match.end() + 1200)
        context = text[start:end].lower()

        score = 0

        for token in (
            "two-second",
            "short-lived",
            "expired token",
            "expiry client",
        ):
            if token in context:
                score += 1

        ranked.append(
            (
                score,
                match.start(),
                match,
            )
        )

    ranked.sort(
        key=lambda item: (
            item[0],
            item[1],
        ),
        reverse=True,
    )

    best_score, _, match = ranked[0]

    if len(validity_matches) > 1 and best_score == 0:
        raise SystemExit(
            "[final-oauth-logic][FAIL] "
            "Multiple validityTime: 2 payloads exist and none can be "
            "identified as the short-lived OAuth client."
        )

    replacement = '''validityTime: 2,
      additionalProperties: {
        applicationAccessTokenExpiryTime: 2,
        userAccessTokenExpiryTime: 2
      }'''

    text = (
        text[:match.start()]
        + replacement
        + text[match.end():]
    )

    print(
        "[final-oauth-logic] "
        "Added applicationAccessTokenExpiryTime=2 to the "
        "short-lived key mapping."
    )

# Restrict the short-lived client to the grant actually used by the expiry
# test. Only alter the object surrounding the two-second validity property.
expiry_position = text.find(
    "applicationAccessTokenExpiryTime: 2"
)

segment_start = max(
    0,
    expiry_position - 2500,
)

segment_end = min(
    len(text),
    expiry_position + 1200,
)

segment = text[
    segment_start:segment_end
]

grant_matches = list(
    re.finditer(
        r"grantTypesToBeSupported\s*:\s*\[[^\]]*\]",
        segment,
        re.DOTALL,
    )
)

if grant_matches:
    grant_match = grant_matches[-1]

    segment = (
        segment[:grant_match.start()]
        + "grantTypesToBeSupported: ['client_credentials']"
        + segment[grant_match.end():]
    )

    text = (
        text[:segment_start]
        + segment
        + text[segment_end:]
    )

    print(
        "[final-oauth-logic] "
        "Restricted the short-lived client to client_credentials."
    )
else:
    raise SystemExit(
        "[final-oauth-logic][FAIL] "
        "Could not locate grantTypesToBeSupported near the "
        "short-lived key payload."
    )

path.write_text(
    text,
    encoding="utf-8",
)
PY

###############################################################################
# 4. Simplify reconciliation: no builds, no second deployment owner,
#    no global Developer Experience bootstrap
###############################################################################

python3 - "$RECONCILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(
    encoding="utf-8",
).splitlines()

updated = []
skip_next_build = False

for line in lines:
    stripped = line.strip()

    if (
        "Rebuilding apim-bootstrapper" in line
        or (
            "build apim-bootstrapper" in line
            and "OAUTH_COMPOSE" in line
        )
    ):
        continue

    if "ensure-oauth-api-deployment.sh" in line:
        continue

    if (
        "Ensuring SubscriberAuthorizationControlAPI" in line
        and "Gateway deployment" in line
    ):
        continue

    if "node src/developer-experience-setup.js" in line:
        indentation = line[:len(line) - len(line.lstrip())]

        updated.append(
            indentation +
            'echo "[oauth-reconcile] Global Developer Experience '
            'is owned by the base bootstrap and is skipped here."'
        )

        continue

    updated.append(line)

text = "\n".join(updated) + "\n"

persona_call = (
    "bash scripts/generate-oauth-persona-sequence.sh"
)

if persona_call not in text:
    anchors = [
        'log "Reconciling API Product publication."',
        'mkdir -p .runtime',
        'log "OAuth applications, keys, subscriptions and Product were reconciled."',
    ]

    insertion_index = -1

    for anchor in anchors:
        insertion_index = text.find(anchor)

        if insertion_index >= 0:
            break

    if insertion_index < 0:
        raise SystemExit(
            "[final-oauth-logic][FAIL] "
            "Could not locate a safe persona-registry insertion point "
            "inside reconcile-oauth-control-plane.sh."
        )

    block = '''log "Generating the MI persona registry from authoritative SCIM user IDs."
bash scripts/generate-oauth-persona-sequence.sh

'''

    text = (
        text[:insertion_index]
        + block
        + text[insertion_index:]
    )

path.write_text(
    text,
    encoding="utf-8",
)

print(
    "[final-oauth-logic] "
    "Removed image building, duplicate deployment creation, and global "
    "Developer Experience execution from OAuth reconciliation."
)
PY

###############################################################################
# 5. Make the verifier use the authoritative read-only deployment checker
###############################################################################

python3 - "$VERIFY" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
lines = path.read_text(
    encoding="utf-8",
).splitlines()

if any(
    "check-oauth-api-deployment.sh" in line
    for line in lines
):
    print(
        "[final-oauth-logic] "
        "Verifier already uses the authoritative deployment checker."
    )

    raise SystemExit(0)

failure_index = next(
    (
        index
        for index, line in enumerate(lines)
        if "API has no deployed revision." in line
    ),
    None,
)

if failure_index is None:
    raise SystemExit(
        "[final-oauth-logic][FAIL] "
        "Could not locate the existing deployment failure in the verifier."
    )

start = failure_index

while start >= 0:
    stripped = lines[start].strip()

    if re.match(r"^if\b", stripped):
        break

    start -= 1

if start < 0:
    raise SystemExit(
        "[final-oauth-logic][FAIL] "
        "Could not locate the beginning of the deployment-check if block."
    )

depth = 0
end = None

for index in range(start, len(lines)):
    stripped = lines[index].strip()

    if re.match(r"^if\b", stripped):
        depth += 1

    if stripped == "fi":
        depth -= 1

        if depth == 0:
            end = index
            break

if end is None:
    raise SystemExit(
        "[final-oauth-logic][FAIL] "
        "Could not locate the end of the deployment-check if block."
    )

old_block = "\n".join(
    lines[start:end + 1]
)

if "API has a deployed revision." not in old_block:
    raise SystemExit(
        "[final-oauth-logic][FAIL] "
        "The identified block does not contain the expected deployment PASS."
    )

indentation = lines[start][
    :len(lines[start]) - len(lines[start].lstrip())
]

replacement = [
    indentation + "if bash scripts/check-oauth-api-deployment.sh >/dev/null; then",
    indentation + '  pass "API has a deployed revision."',
    indentation + "else",
    indentation + '  fail "API has no deployed revision."',
    indentation + "fi",
]

updated = (
    lines[:start]
    + replacement
    + lines[end + 1:]
)

path.write_text(
    "\n".join(updated) + "\n",
    encoding="utf-8",
)

print(
    "[final-oauth-logic] "
    f"Replaced verifier deployment logic at lines {start + 1}-{end + 1}."
)
PY

###############################################################################
# 6. Validate every generated artifact before execution
###############################################################################

chmod +x \
  scripts/check-oauth-api-deployment.sh \
  scripts/generate-oauth-persona-sequence.sh \
  "$RECONCILE" \
  "$VERIFY"

log "Validating Bash syntax."

bash -n scripts/check-oauth-api-deployment.sh
bash -n scripts/generate-oauth-persona-sequence.sh
bash -n "$RECONCILE"
bash -n "$VERIFY"
bash -n scripts/complete-oauth-post-start.sh

if command -v node >/dev/null 2>&1; then
  node --check "$OAUTH_JS"
fi

if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$CONTEXT_XML"
fi

grep -Fq \
  'applicationAccessTokenExpiryTime: 2' \
  "$OAUTH_JS" ||
  fail "Short-lived application token expiry was not installed."

grep -Fq \
  "grantTypesToBeSupported: ['client_credentials']" \
  "$OAUTH_JS" ||
  fail "Short-lived client grant configuration was not installed."

grep -Fq \
  'generate-oauth-persona-sequence.sh' \
  "$RECONCILE" ||
  fail "Persona-registry generation is absent from reconciliation."

if grep -Fq \
  'ensure-oauth-api-deployment.sh' \
  "$RECONCILE"
then
  fail "Duplicate deployment creation remains in reconciliation."
fi

if grep -Fq \
  'node src/developer-experience-setup.js' \
  "$RECONCILE"
then
  fail "Global Developer Experience execution remains in OAuth reconciliation."
fi

grep -Fq \
  'check-oauth-api-deployment.sh' \
  "$VERIFY" ||
  fail "Verifier does not use the authoritative deployment checker."

if grep -Eq \
  'OAUTH_COMPOSE.*build[[:space:]]+apim-bootstrapper' \
  "$RECONCILE"
then
  fail "OAuth reconciliation still rebuilds apim-bootstrapper."
fi

cat <<EOF

[final-oauth-logic] Static installation passed.

Backups:
  ${backup_dir}

EOF

if [[ "${PATCH_ONLY:-0}" == "1" ]]; then
  log "PATCH_ONLY=1; runtime build and verification were skipped."
  exit 0
fi

###############################################################################
# 7. One-time build and complete execution
###############################################################################

source "$COMPOSE_CONTEXT"
resolve_oauth_compose_context "$ROOT"

services="$(
  "${OAUTH_COMPOSE[@]}" config --services
)"

grep -Fxq 'apim-bootstrapper' <<<"$services" ||
  fail "apim-bootstrapper is absent from the Compose topology."

grep -Fxq 'wso2-mi' <<<"$services" ||
  fail "wso2-mi is absent from the Compose topology."

log "Building apim-bootstrapper once with the corrected key-generation logic."

"${OAUTH_COMPOSE[@]}" build apim-bootstrapper

log "Running one complete reconciliation and verification cycle."

COMPOSE_IGNORE_ORPHANS=1 \
OAUTH_RECONCILE_ATTEMPTS=1 \
OAUTH_VERIFY_ATTEMPTS=1 \
bash scripts/complete-oauth-post-start.sh

cat <<EOF

[final-oauth-logic] Complete OAuth runtime logic passed.

The normal restart path now uses:

  Existing API reconciliation
  → existing/new revision handling inside the OAuth bootstrap
  → application and key reconciliation
  → SCIM UUID-based MI persona registry
  → OAuth Service Catalog registration
  → one authoritative deployment verification
  → complete runtime scenarios

EOF
