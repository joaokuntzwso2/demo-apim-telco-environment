#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

log() {
  printf '[oauth-final-runtime-fix] %s\n' "$*"
}

fail() {
  printf '[oauth-final-runtime-fix][FAIL] %s\n' "$*" >&2
  exit 1
}

for command in bash python3 docker curl jq; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Required command is missing: $command"
done

CONTEXT_XML="services/wso2-mi/synapse-configs/default/sequences/SubscriberAuthorizationContextSequence.xml"
DENY_XML="services/wso2-mi/synapse-configs/default/sequences/SubscriberAuthorizationDenySequence.xml"
OAUTH_JS="services/apim-bootstrapper/src/oauth-business-controls-setup.js"
RECONCILE="scripts/reconcile-oauth-control-plane.sh"
VERIFY="scripts/verify-oauth-consent-risk-controls.sh"
COMPOSE_CONTEXT="scripts/oauth-compose-context.sh"

for file in \
  "$CONTEXT_XML" \
  "$DENY_XML" \
  "$OAUTH_JS" \
  "$RECONCILE" \
  "$VERIFY" \
  "$COMPOSE_CONTEXT" \
  services/wso2-apim/Dockerfile \
  services/wso2-apim/merge-oauth-business-controls-config.sh
do
  [[ -f "$file" ]] ||
    fail "Required file is missing: $file"
done

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=".restart-backups/oauth-final-runtime-${timestamp}"
mkdir -p "$backup_dir"

for file in \
  "$CONTEXT_XML" \
  "$DENY_XML" \
  "$OAUTH_JS" \
  "$RECONCILE" \
  "$VERIFY"
do
  cp \
    "$file" \
    "$backup_dir/$(printf '%s' "$file" | tr '/' '_')"
done

log "Backups written under $backup_dir"

python3 - \
  "$CONTEXT_XML" \
  "$DENY_XML" \
  "$OAUTH_JS" \
  "$RECONCILE" \
  "$VERIFY" <<'PY'
from pathlib import Path
import re
import sys

context_path = Path(sys.argv[1])
deny_path = Path(sys.argv[2])
oauth_path = Path(sys.argv[3])
reconcile_path = Path(sys.argv[4])
verify_path = Path(sys.argv[5])

context_xml = r'''<?xml version="1.0" encoding="UTF-8"?>
<sequence name="SubscriberAuthorizationContextSequence" trace="disable" xmlns="http://ws.apache.org/ns/synapse">
    <property name="correlation.id" expression="$trp:X-Correlation-ID" scope="default" type="STRING"/>

    <filter xpath="not(normalize-space(get-property('correlation.id')))">
        <then>
            <property
                name="correlation.id"
                expression="get-property('MessageID')"
                scope="default"
                type="STRING"
            />
        </then>
    </filter>

    <header
        name="X-Correlation-ID"
        expression="get-property('correlation.id')"
        scope="transport"
    />

    <property
        name="backend.jwt"
        expression="$trp:X-JWT-Assertion"
        scope="default"
        type="STRING"
    />

    <script language="js"><![CDATA[
        var jwt = String(mc.getProperty('backend.jwt') || '');
        var user = '';
        var rawSubject = '';
        var application = '';
        var claimKeys = '';

        function decodeBase64Url(value) {
            var alphabet =
                'ABCDEFGHIJKLMNOPQRSTUVWXYZ' +
                'abcdefghijklmnopqrstuvwxyz' +
                '0123456789+/';

            var normalized = String(value || '')
                .replace(/-/g, '+')
                .replace(/_/g, '/');

            while (normalized.length % 4 !== 0) {
                normalized += '=';
            }

            var bytes = '';
            var buffer = 0;
            var bits = 0;

            for (var i = 0; i < normalized.length; i++) {
                var ch = normalized.charAt(i);

                if (ch === '=') {
                    break;
                }

                var index = alphabet.indexOf(ch);

                if (index < 0) {
                    continue;
                }

                buffer = (buffer << 6) | index;
                bits += 6;

                if (bits >= 8) {
                    bits -= 8;

                    bytes += String.fromCharCode(
                        (buffer >> bits) & 255
                    );
                }
            }

            try {
                var encoded = '';

                for (var j = 0; j < bytes.length; j++) {
                    var hex =
                        bytes.charCodeAt(j).toString(16);

                    encoded +=
                        '%' +
                        (hex.length === 1 ? '0' + hex : hex);
                }

                return decodeURIComponent(encoded);
            } catch (ignored) {
                return bytes;
            }
        }

        function normalizeUser(value) {
            if (
                value === null ||
                typeof value === 'undefined'
            ) {
                return '';
            }

            if (
                Object.prototype.toString.call(value) ===
                '[object Array]'
            ) {
                value =
                    value.length > 0
                        ? value[0]
                        : '';
            }

            var normalized = String(value)
                .replace(/^\s+|\s+$/g, '')
                .replace(/^"+|"+$/g, '')
                .replace(/@carbon\.super$/i, '')
                .replace(/^PRIMARY\//i, '')
                .replace(/^Internal\//i, '')
                .replace(/^carbon\.super\//i, '');

            if (normalized.indexOf('/') >= 0) {
                var pieces = normalized.split('/');

                normalized =
                    pieces[pieces.length - 1];
            }

            return normalized;
        }

        function isKnownPersonaUser(value) {
            return (
                value === 'partner.alpha' ||
                value === 'partner.beta' ||
                value === 'telco.operations' ||
                value === 'telco.product' ||
                value === 'telco.admin' ||
                value === 'admin'
            );
        }

        try {
            var token = jwt;

            /*
             * Support both a direct signed JWT and an additional
             * Base64-encoded JWT representation.
             */
            if (
                token.indexOf('.') < 0 &&
                token.length > 0
            ) {
                var decodedOuter =
                    decodeBase64Url(token);

                if (
                    decodedOuter.indexOf('.') >= 0
                ) {
                    token = decodedOuter;
                }
            }

            var parts = token.split('.');

            if (parts.length >= 2) {
                var claims = JSON.parse(
                    decodeBase64Url(parts[1])
                );

                var keys = [];

                for (var claimName in claims) {
                    if (
                        Object.prototype
                            .hasOwnProperty
                            .call(claims, claimName)
                    ) {
                        keys.push(claimName);
                    }
                }

                claimKeys = keys.join(',');

                /*
                 * Explicit end-user claims must take precedence
                 * over sub. sub can contain a different subject
                 * representation depending on token configuration.
                 */
                var candidates = [
                    claims[
                        'http://wso2.org/claims/enduser'
                    ],
                    claims[
                        'http://wso2.org/claims/username'
                    ],
                    claims[
                        'http://wso2.org/claims/userid'
                    ],
                    claims.preferred_username,
                    claims.username,
                    claims.sub
                ];

                rawSubject = String(
                    claims[
                        'http://wso2.org/claims/enduser'
                    ] ||
                    claims[
                        'http://wso2.org/claims/username'
                    ] ||
                    claims.preferred_username ||
                    claims.username ||
                    claims.sub ||
                    ''
                );

                for (
                    var candidateIndex = 0;
                    candidateIndex < candidates.length;
                    candidateIndex++
                ) {
                    var candidate = normalizeUser(
                        candidates[candidateIndex]
                    );

                    if (
                        isKnownPersonaUser(candidate)
                    ) {
                        user = candidate;
                        break;
                    }
                }

                if (!user) {
                    user = normalizeUser(rawSubject);
                }

                application = String(
                    claims.application ||
                    claims.applicationname ||
                    claims[
                        'http://wso2.org/claims/applicationname'
                    ] ||
                    ''
                );
            }
        } catch (error) {
            mc.setProperty(
                'backend.jwt.decode.error',
                String(error)
            );
        }

        mc.setProperty(
            'backend.jwt.subject.raw',
            rawSubject
        );

        mc.setProperty(
            'backend.jwt.claim.keys',
            claimKeys
        );

        mc.setProperty(
            'authenticated.user',
            user
        );

        mc.setProperty(
            'authenticated.application',
            application
        );

        var persona = '';
        var partner = '';
        var countries = '';

        if (user === 'partner.alpha') {
            persona = 'partner';
            partner = 'partner-alpha';
            countries = 'BR';
        } else if (user === 'partner.beta') {
            persona = 'partner';
            partner = 'partner-beta';
            countries = 'MX';
        } else if (user === 'telco.operations') {
            persona = 'operations';
            partner = '*';
            countries = 'BR,MX,CO,AR,PE,CL';
        } else if (user === 'telco.product') {
            persona = 'product_manager';
            partner = '*';
            countries = 'BR,MX,CO,AR,PE,CL';
        } else if (
            user === 'telco.admin' ||
            user === 'admin'
        ) {
            persona = 'platform_administrator';
            partner = '*';
            countries = '*';
        }

        mc.setProperty(
            'persona',
            persona
        );

        mc.setProperty(
            'authorized.partner.id',
            partner
        );

        mc.setProperty(
            'authorized.countries',
            countries
        );
    ]]></script>
</sequence>
'''

deny_xml = r'''<?xml version="1.0" encoding="UTF-8"?>
<sequence name="SubscriberAuthorizationDenySequence" trace="disable" xmlns="http://ws.apache.org/ns/synapse">
    <property
        name="HTTP_SC"
        expression="get-property('auth.error.status')"
        scope="axis2"
        type="INTEGER"
    />

    <property
        name="messageType"
        scope="axis2"
        type="STRING"
        value="application/json"
    />

    <property
        name="ContentType"
        scope="axis2"
        type="STRING"
        value="application/json"
    />

    <header
        name="X-Correlation-ID"
        expression="get-property('correlation.id')"
        scope="transport"
    />

    <payloadFactory media-type="json">
        <format>{
          "code":"$1",
          "message":"$2",
          "correlationId":"$3",
          "details":{
            "persona":"$4",
            "authenticatedPartnerId":"$5",
            "requestedPartnerId":"$6",
            "country":"$7",
            "purpose":"$8",
            "authenticatedSubject":"$9",
            "jwtSubject":"$10",
            "jwtClaimKeys":"$11"
          }
        }</format>

        <args>
            <arg
                evaluator="xml"
                expression="get-property('auth.error.code')"
            />

            <arg
                evaluator="xml"
                expression="get-property('auth.error.message')"
            />

            <arg
                evaluator="xml"
                expression="get-property('correlation.id')"
            />

            <arg
                evaluator="xml"
                expression="get-property('persona')"
            />

            <arg
                evaluator="xml"
                expression="get-property('authorized.partner.id')"
            />

            <arg
                evaluator="xml"
                expression="get-property('requested.partner.id')"
            />

            <arg
                evaluator="xml"
                expression="get-property('requested.country')"
            />

            <arg
                evaluator="xml"
                expression="get-property('requested.purpose')"
            />

            <arg
                evaluator="xml"
                expression="get-property('authenticated.user')"
            />

            <arg
                evaluator="xml"
                expression="get-property('backend.jwt.subject.raw')"
            />

            <arg
                evaluator="xml"
                expression="get-property('backend.jwt.claim.keys')"
            />
        </args>
    </payloadFactory>

    <respond/>
</sequence>
'''

context_path.write_text(
    context_xml,
    encoding="utf-8",
)

deny_path.write_text(
    deny_xml,
    encoding="utf-8",
)

print(
    "[oauth-final-runtime-fix] "
    "Replaced MI backend-JWT persona extraction."
)

print(
    "[oauth-final-runtime-fix] "
    "Added safe JWT diagnostics to MI denials."
)

installer_paths = [
    Path(
        "install-oauth-consent-risk-controls-v2.sh"
    ),
    Path(
        "install-oauth-consent-risk-controls.sh"
    ),
]

context_heredoc = (
    "cat > "
    "services/wso2-mi/synapse-configs/default/"
    "sequences/SubscriberAuthorizationContextSequence.xml "
    "<<'XML'\n"
)

deny_heredoc = (
    "cat > "
    "services/wso2-mi/synapse-configs/default/"
    "sequences/SubscriberAuthorizationDenySequence.xml "
    "<<'XML'\n"
)


def replace_heredoc(
    text: str,
    marker: str,
    body: str,
) -> str:
    start = text.find(marker)

    if start < 0:
        return text

    content_start = start + len(marker)
    end = text.find(
        "\nXML\n",
        content_start,
    )

    if end < 0:
        raise SystemExit(
            "[oauth-final-runtime-fix][FAIL] "
            "Could not find XML heredoc ending."
        )

    return (
        text[:content_start]
        + body.rstrip()
        + text[end:]
    )


def allow_short_client_credentials(
    text: str,
) -> str:
    pattern = re.compile(
        r"grantTypesToBeSupported:\s*"
        r"\[\s*(['\"])password\1\s*\]"
        r"(?=\s*,[\s\S]{0,240}?"
        r"validityTime:\s*2\b)"
    )

    updated, count = pattern.subn(
        "grantTypesToBeSupported: "
        "['password', 'client_credentials']",
        text,
        count=1,
    )

    already_fixed = (
        "grantTypesToBeSupported: "
        "['password', 'client_credentials']"
        in text
    )

    if count == 0 and not already_fixed:
        raise SystemExit(
            "[oauth-final-runtime-fix][FAIL] "
            "Could not locate the two-second "
            "OAuth client's grant list."
        )

    return updated


oauth = oauth_path.read_text(
    encoding="utf-8",
)

oauth = allow_short_client_credentials(
    oauth
)

oauth_path.write_text(
    oauth,
    encoding="utf-8",
)

print(
    "[oauth-final-runtime-fix] "
    "Enabled client_credentials on the "
    "two-second OAuth client."
)

for installer_path in installer_paths:
    if not installer_path.exists():
        continue

    installer = installer_path.read_text(
        encoding="utf-8",
    )

    installer = replace_heredoc(
        installer,
        context_heredoc,
        context_xml,
    )

    installer = replace_heredoc(
        installer,
        deny_heredoc,
        deny_xml,
    )

    installer = allow_short_client_credentials(
        installer
    )

    installer_path.write_text(
        installer,
        encoding="utf-8",
    )

    print(
        "[oauth-final-runtime-fix] "
        f"Updated installer template: "
        f"{installer_path}"
    )

verify = verify_path.read_text(
    encoding="utf-8",
)

legacy_deployment_test = (
    "'((.list // .) | length) > 0'"
)

robust_deployment_test = r"""'
    def deployment_items:
      if type == "array" then .
      elif type == "object" then
        (
          .list //
          .data //
          .deployments //
          .deploymentInfo //
          .deploymentEnvironments //
          []
        )
      else []
      end;

    ((.count // 0) > 0) or
    ((deployment_items | length) > 0)
  '"""

if legacy_deployment_test in verify:
    verify = verify.replace(
        legacy_deployment_test,
        robust_deployment_test,
        1,
    )

    verify_path.write_text(
        verify,
        encoding="utf-8",
    )

    print(
        "[oauth-final-runtime-fix] "
        "Made the API deployment verification "
        "response-shape tolerant."
    )
elif "def deployment_items:" in verify:
    print(
        "[oauth-final-runtime-fix] "
        "Deployment verifier is already tolerant."
    )
else:
    raise SystemExit(
        "[oauth-final-runtime-fix][FAIL] "
        "Could not locate the API deployment "
        "verifier expression."
    )

reconcile = reconcile_path.read_text(
    encoding="utf-8",
)

deployment_call = (
    "bash scripts/ensure-oauth-api-deployment.sh"
)

if deployment_call not in reconcile:
    anchors = [
        (
            'log "Reconciling API Product '
            'publication after refreshing applications."'
        ),
        (
            'log "Reconciling API Product publication."'
        ),
        (
            'log "Reconciling API Product deployment '
            'and Developer Portal publication."'
        ),
    ]

    anchor_index = -1

    for anchor in anchors:
        anchor_index = reconcile.find(anchor)

        if anchor_index >= 0:
            break

    if anchor_index < 0:
        raise SystemExit(
            "[oauth-final-runtime-fix][FAIL] "
            "Could not locate the API Product phase "
            "inside reconciliation."
        )

    deployment_block = r'''log "Ensuring SubscriberAuthorizationControlAPI has a fresh Gateway deployment."
bash scripts/ensure-oauth-api-deployment.sh

'''

    reconcile = (
        reconcile[:anchor_index]
        + deployment_block
        + reconcile[anchor_index:]
    )

    reconcile_path.write_text(
        reconcile,
        encoding="utf-8",
    )

    print(
        "[oauth-final-runtime-fix] "
        "Added API deployment convergence "
        "to reconciliation."
    )
else:
    print(
        "[oauth-final-runtime-fix] "
        "API deployment convergence hook "
        "already exists."
    )
PY

cat > scripts/ensure-oauth-api-deployment.sh <<'DEPLOY'
#!/usr/bin/env bash
set -Eeuo pipefail

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"

API_NAME="SubscriberAuthorizationControlAPI"
API_VERSION="1.0.0"

WORK_DIR="$(
  mktemp -d \
    "${TMPDIR:-/tmp}/oauth-api-deployment.XXXXXX"
)"

trap 'rm -rf "$WORK_DIR"' EXIT

log() {
  printf '[oauth-api-deployment] %s\n' "$*"
}

fail() {
  printf '[oauth-api-deployment][FAIL] %s\n' \
    "$*" >&2
  exit 1
}

dcr="$(
  curl -ksS \
    -u "${APIM_USER}:${APIM_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d "{
      \"callbackUrl\":\"http://localhost:8080/callback\",
      \"clientName\":\"oauth-api-deployment-$(date +%s)-$$\",
      \"owner\":\"${APIM_USER}\",
      \"grantType\":\"password refresh_token client_credentials\",
      \"saasApp\":true
    }" \
    "${APIM_URL}/client-registration/v0.17/register"
)"

client_id="$(
  jq -r '.clientId // empty' \
    <<<"$dcr"
)"

client_secret="$(
  jq -r '.clientSecret // empty' \
    <<<"$dcr"
)"

[[ -n "$client_id" && -n "$client_secret" ]] || {
  printf '%s\n' "$dcr" >&2
  fail "Dynamic client registration failed."
}

token_json="$(
  curl -ksS \
    -u "${client_id}:${client_secret}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${APIM_USER}" \
    --data-urlencode "password=${APIM_PASSWORD}" \
    --data-urlencode \
      'scope=apim:api_view apim:api_manage apim:api_publish' \
    "${APIM_URL}/oauth2/token"
)"

token="$(
  jq -r '.access_token // empty' \
    <<<"$token_json"
)"

[[ -n "$token" ]] || {
  printf '%s\n' "$token_json" >&2
  fail "Publisher token acquisition failed."
}

apis="$(
  curl -kfsS \
    -H "Authorization: Bearer ${token}" \
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
    <<<"$apis"
)"

[[ -n "$api_id" ]] ||
  fail \
    "${API_NAME}:${API_VERSION} was not found."

deployment_exists() {
  jq -e '
    def deployment_items:
      if type == "array" then .
      elif type == "object" then
        (
          .list //
          .data //
          .deployments //
          .deploymentInfo //
          .deploymentEnvironments //
          []
        )
      else []
      end;

    ((.count // 0) > 0) or
    ((deployment_items | length) > 0)
  ' >/dev/null 2>&1
}

deployments="$(
  curl -kfsS \
    -H "Authorization: Bearer ${token}" \
    "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/deployments"
)"

if deployment_exists <<<"$deployments"; then
  log \
    "${API_NAME} already has a deployed revision."

  exit 0
fi

log \
  "${API_NAME} has no control-plane deployment; creating a fresh revision."

revisions="$(
  curl -kfsS \
    -H "Authorization: Bearer ${token}" \
    "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/revisions?limit=100"
)"

revision_count="$(
  jq -r '
    (
      .list //
      .data //
      (if type == "array" then . else [] end)
    )
    | length
  ' \
    <<<"$revisions"
)"

if [[ "$revision_count" =~ ^[0-9]+$ ]] &&
   (( revision_count >= 5 ))
then
  oldest_revision="$(
    jq -r '
      (
        .list //
        .data //
        (if type == "array" then . else [] end)
      )
      | sort_by(
          .createdTime //
          .revisionNumber //
          .id
        )
      | first
      | (.id // .revisionId // empty)
    ' \
      <<<"$revisions"
  )"

  [[ -n "$oldest_revision" ]] ||
    fail \
      "Five revisions exist, but the oldest ID could not be resolved."

  log \
    "Removing oldest undeployed revision ${oldest_revision}."

  delete_status="$(
    curl -ksS \
      -o "$WORK_DIR/delete.json" \
      -w '%{http_code}' \
      -X DELETE \
      -H "Authorization: Bearer ${token}" \
      "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/revisions/${oldest_revision}"
  )"

  case "$delete_status" in
    200|202|204)
      ;;
    *)
      cat "$WORK_DIR/delete.json" >&2

      fail \
        "Could not delete the oldest revision; HTTP ${delete_status}."
      ;;
  esac
fi

create_status="$(
  curl -ksS \
    -o "$WORK_DIR/revision.json" \
    -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -d '{
      "description":
        "OAuth persona consent purpose country and partner-control deployment"
    }' \
    "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/revisions"
)"

case "$create_status" in
  200|201|202)
    ;;
  *)
    cat "$WORK_DIR/revision.json" >&2

    fail \
      "Revision creation failed; HTTP ${create_status}."
    ;;
esac

revision_id="$(
  jq -r \
    '.id // .revisionId // empty' \
    "$WORK_DIR/revision.json"
)"

[[ -n "$revision_id" ]] || {
  cat "$WORK_DIR/revision.json" >&2

  fail \
    "Revision creation did not return an ID."
}

deploy_status="$(
  curl -ksS \
    -o "$WORK_DIR/deploy.json" \
    -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -d '[
      {
        "name":"Default",
        "vhost":"localhost",
        "displayOnDevportal":true
      }
    ]' \
    "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/deploy-revision?revisionId=${revision_id}"
)"

case "$deploy_status" in
  200|201|202)
    ;;
  *)
    cat "$WORK_DIR/deploy.json" >&2

    fail \
      "Revision deployment failed; HTTP ${deploy_status}."
    ;;
esac

for attempt in $(seq 1 30); do
  deployments="$(
    curl -kfsS \
      -H "Authorization: Bearer ${token}" \
      "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/deployments"
  )"

  if deployment_exists <<<"$deployments"; then
    log \
      "Deployed revision ${revision_id} to Default."

    exit 0
  fi

  log \
    "Waiting for deployment state (${attempt}/30)."

  sleep 2
done

printf '%s\n' "$deployments" >&2

fail \
  "Revision deployment did not converge."
DEPLOY

chmod +x \
  scripts/ensure-oauth-api-deployment.sh \
  "$RECONCILE" \
  "$VERIFY"

bash -n \
  scripts/ensure-oauth-api-deployment.sh

bash -n "$RECONCILE"
bash -n "$VERIFY"

if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$CONTEXT_XML"
  xmllint --noout "$DENY_XML"
fi

if command -v node >/dev/null 2>&1; then
  node --check "$OAUTH_JS"
fi

grep -Fq \
  'http://wso2.org/claims/enduser' \
  "$CONTEXT_XML" ||
  fail \
    "End-user claim preference was not installed."

grep -Fq \
  "['password', 'client_credentials']" \
  "$OAUTH_JS" ||
  fail \
    "The short-lived client grant fix was not installed."

grep -Fq \
  'ensure-oauth-api-deployment.sh' \
  "$RECONCILE" ||
  fail \
    "The deployment convergence hook was not installed."

if [[ "${PATCH_ONLY:-0}" == "1" ]]; then
  log \
    "PATCH_ONLY=1; build, recreation and verification were skipped."

  exit 0
fi

source "$COMPOSE_CONTEXT"

resolve_oauth_compose_context "$ROOT"

services="$(
  "${OAUTH_COMPOSE[@]}" config --services
)"

for service in \
  wso2-apim \
  wso2-mi \
  apim-bootstrapper
do
  grep -Fxq "$service" <<<"$services" ||
    fail "Compose service is absent: $service"
done

log \
  "Building APIM, MI and the bootstrapper with the corrected configuration."

"${OAUTH_COMPOSE[@]}" build \
  wso2-apim \
  wso2-mi \
  apim-bootstrapper

log \
  "Recreating APIM and MI while preserving named volumes."

"${OAUTH_COMPOSE[@]}" up \
  -d \
  --no-deps \
  --force-recreate \
  wso2-apim \
  wso2-mi

log "Waiting for APIM."

for attempt in $(seq 1 180); do
  if curl -kfsS \
    https://localhost:9443/services/Version \
    >/dev/null 2>&1
  then
    log "APIM is ready."
    break
  fi

  if (( attempt == 180 )); then
    fail "APIM did not become ready."
  fi

  sleep 2
done

log \
  "Waiting for the MI subscriber-authorization API."

for attempt in $(seq 1 180); do
  if curl -fsS \
    http://localhost:8290/subscriber-authorization/v1/health \
    >/dev/null 2>&1
  then
    log \
      "MI subscriber-authorization API is ready."

    break
  fi

  if (( attempt == 180 )); then
    fail \
      "MI subscriber-authorization API did not become ready."
  fi

  sleep 2
done

log \
  "Running complete reconciliation and verification."

COMPOSE_IGNORE_ORPHANS=1 \
  bash scripts/complete-oauth-post-start.sh

cat <<EOF

[oauth-final-runtime-fix] Complete repair passed.

Backups:
  ${backup_dir}

The normal restart path now also:
  - verifies or creates an API Gateway deployment;
  - rebuilds APIM with backend JWT enabled;
  - resolves the explicit end-user claim before mapping the MI persona;
  - permits the deterministic client-credentials expiry test;
  - fails when verification fails.

EOF
