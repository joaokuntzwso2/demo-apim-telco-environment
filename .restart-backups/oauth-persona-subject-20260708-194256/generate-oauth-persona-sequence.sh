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
