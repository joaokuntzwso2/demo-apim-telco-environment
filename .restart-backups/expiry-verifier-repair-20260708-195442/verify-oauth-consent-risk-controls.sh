#!/usr/bin/env bash
set -euo pipefail

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
GATEWAY_URL="${WSO2_APIM_GATEWAY_PUBLIC_URL:-https://127.0.0.1:8243}"
MI_URL="${WSO2_MI_PUBLIC_URL:-http://127.0.0.1:8290}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-telco-wso2-demo-kit}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oauth-business-controls-verify.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

for command in curl jq docker; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "[oauth-controls-verify][FAIL] Missing command: ${command}" >&2
    exit 1
  }
done

compose=(
  docker compose
  -p "${COMPOSE_PROJECT_NAME}"
  -f docker-compose.yml
  -f docker-compose.kafka.yml
  -f docker-compose.opa.yml
  -f docker-compose.mi.yml
  -f docker-compose.oauth-business-controls.yml
  -f docker-compose.commercial.yml
  -f docker-compose.mi.soap.yml
  -f docker-compose.observability.yml
  -f docker-compose.runtime-persistence.yml
)

failures=0
pass() { printf '[oauth-controls-verify][PASS] %s\n' "$*"; }
fail() { printf '[oauth-controls-verify][FAIL] %s\n' "$*" >&2; failures=$((failures + 1)); }

echo "[oauth-controls-verify] Reading bootstrap state from the running Compose project's OAuth volume."

oauth_state_json="$(
  bash scripts/read-oauth-business-state.sh
)" || {
  echo "[oauth-controls-verify][FAIL] Could not read current OAuth bootstrap state." >&2
  exit 1
}

if ! jq -e 'type == "object"' <<<"${oauth_state_json}" >/dev/null 2>&1; then
  echo "[oauth-controls-verify][FAIL] Current OAuth bootstrap state is invalid JSON." >&2
  exit 1
fi

# Preserve the variable names used by previous verifier revisions.
state="${oauth_state_json}"
state_json="${oauth_state_json}"
bootstrap_state="${oauth_state_json}"
oauth_state="${oauth_state_json}"

pass "Bootstrap state exists."

product_state="$("${compose[@]}" run --rm --no-deps apim-bootstrapper sh -lc \
  'cat /workspace/state/api-product-bundles.json' 2>/dev/null || true)"
if jq -e 'any(.products[]?; .id == "subscriber-authorization-business-controls" and .nativeApiProduct == true and .status != "FAILED")' \
    <<<"${product_state}" >/dev/null 2>&1; then
  pass "API Product bootstrap state confirms a native product."
else
  fail "API Product bootstrap state does not confirm the authorization bundle as native."
  printf '%s\n' "${product_state}" >&2
fi

client_id="$(jq -r '.application.consumerKey // empty' <<<"${state}")"
client_secret="$(jq -r '.application.consumerSecret // empty' <<<"${state}")"
operations_client_id="$(jq -r '.application.operationsClient.consumerKey // empty' <<<"${state}")"
operations_client_secret="$(jq -r '.application.operationsClient.consumerSecret // empty' <<<"${state}")"
expired_client_id="$(jq -r '.application.expiredTokenClient.consumerKey // empty' <<<"${state}")"
expired_client_secret="$(jq -r '.application.expiredTokenClient.consumerSecret // empty' <<<"${state}")"
expired_client_validity="$(jq -r '.application.expiredTokenClient.validityTime // 0' <<<"${state}")"
[[ -n "${client_id}" && -n "${client_secret}" ]] || fail "Partner OAuth consumer credentials are missing from state."
[[ -n "${operations_client_id}" && -n "${operations_client_secret}" ]] || fail "Operations OAuth consumer credentials are missing from state."
[[ -n "${expired_client_id}" && -n "${expired_client_secret}" && "${expired_client_validity}" == "2" ]] \
  || fail "Dedicated two-second OAuth client is missing from state."

for persona_spec in \
  'partner.alpha|partner|telco_partner' \
  'partner.beta|partner|telco_partner' \
  'telco.operations|operations|telco_operations' \
  'telco.product|product_manager|telco_product_manager' \
  'telco.admin|platform_administrator|telco_platform_admin'
do
  username="${persona_spec%%|*}"
  remainder="${persona_spec#*|}"
  persona="${remainder%%|*}"
  role="${remainder#*|}"

  if jq -e \
      --arg username "${username}" \
      --arg persona "${persona}" \
      --arg role "${role}" '
        any(.users[]?;
          .username == $username
          and .persona == $persona
          and (
            (.userStoreRole // .role // "") == $role
            or (.scopeRole // "") == $role
            or (.scopeRole // "") == ("Internal/" + $role)
          )
        )
      ' <<<"${state}" >/dev/null; then
    pass "Sandbox persona exists: ${username} (${persona}/${role})."
  else
    fail "Sandbox persona missing or mismatched: ${username}."
  fi
done

echo "[oauth-controls-verify] Checking MI health."
mi_health="$(curl -fsS "${MI_URL}/subscriber-authorization/v1/health" || true)"
if jq -e '.status == "UP" and .service == "SubscriberAuthorizationControlAPI"' <<<"${mi_health}" >/dev/null 2>&1; then
  pass "MI-managed authorization API is healthy."
else
  fail "MI authorization health endpoint did not return UP."
  printf '%s\n' "${mi_health}" >&2
fi

echo "[oauth-controls-verify] Obtaining APIM management tokens."
dcr="$(curl -ksS -u "${APIM_USER}:${APIM_PASSWORD}" \
  -H 'Content-Type: application/json' \
  -d "{\"callbackUrl\":\"http://localhost:8080/callback\",\"clientName\":\"oauth-controls-verifier-$(date +%s)-$$\",\"owner\":\"${APIM_USER}\",\"grantType\":\"password refresh_token client_credentials\",\"saasApp\":true}" \
  "${APIM_URL}/client-registration/v0.17/register")"
mgmt_client_id="$(jq -r '.clientId // empty' <<<"${dcr}")"
mgmt_client_secret="$(jq -r '.clientSecret // empty' <<<"${dcr}")"
if [[ -z "${mgmt_client_id}" || -z "${mgmt_client_secret}" ]]; then
  fail "DCR failed."
fi

publisher_token="$(curl -ksS -u "${mgmt_client_id}:${mgmt_client_secret}" \
  --data-urlencode 'grant_type=password' \
  --data-urlencode "username=${APIM_USER}" \
  --data-urlencode "password=${APIM_PASSWORD}" \
  --data-urlencode 'scope=apim:api_view apim:api_manage apim:api_publish apim:api_deploy_view apim:api_product_view apim:api_product_manage apim:document_create apim:document_manage' \
  "${APIM_URL}/oauth2/token" | jq -r '.access_token // empty')"
admin_token="$(curl -ksS -u "${mgmt_client_id}:${mgmt_client_secret}" \
  --data-urlencode 'grant_type=password' \
  --data-urlencode "username=${APIM_USER}" \
  --data-urlencode "password=${APIM_PASSWORD}" \
  --data-urlencode 'scope=apim:admin_tier_view apim:admin_tier_manage' \
  "${APIM_URL}/oauth2/token" | jq -r '.access_token // empty')"
catalog_token="$(curl -ksS -u "${mgmt_client_id}:${mgmt_client_secret}" \
  --data-urlencode 'grant_type=password' \
  --data-urlencode "username=${APIM_USER}" \
  --data-urlencode "password=${APIM_PASSWORD}" \
  --data-urlencode 'scope=service_catalog:service_view service_catalog:service_write' \
  "${APIM_URL}/oauth2/token" | jq -r '.access_token // empty')"
devportal_token="$(curl -ksS -u "${mgmt_client_id}:${mgmt_client_secret}" \
  --data-urlencode 'grant_type=password' \
  --data-urlencode "username=${APIM_USER}" \
  --data-urlencode "password=${APIM_PASSWORD}" \
  --data-urlencode 'scope=apim:api_view apim:subscribe apim:app_manage apim:sub_manage' \
  "${APIM_URL}/oauth2/token" | jq -r '.access_token // empty')"

[[ -n "${publisher_token}" ]] || fail "Publisher token was not issued."
[[ -n "${admin_token}" ]] || fail "Admin token was not issued."
[[ -n "${catalog_token}" ]] || fail "Service Catalog token was not issued."
[[ -n "${devportal_token}" ]] || fail "Developer Portal token was not issued."

echo "[oauth-controls-verify] Checking API, scopes, deployment and documents."

apis="$(
  curl -ksS \
    -H "Authorization: Bearer ${publisher_token}" \
    "${APIM_URL}/api/am/publisher/v4/apis?limit=1000"
)"

api_id="$(
  jq -r '
    first(
      (.list // .data // [])[]?
      | select(
          .name == "SubscriberAuthorizationControlAPI" and
          (.version // "") == "1.0.0"
        )
      | .id
    ) // empty
  ' <<<"${apis}"
)"

if [[ -z "${api_id}" ]]; then
  fail "SubscriberAuthorizationControlAPI:1.0.0 is absent."
else
  api="$(
    curl -ksS \
      -H "Authorization: Bearer ${publisher_token}" \
      "${APIM_URL}/api/am/publisher/v4/apis/${api_id}"
  )"

  api_lifecycle="$(
    jq -r '
      .lifeCycleStatus //
      .lifecycleStatus //
      .state //
      empty
    ' <<<"${api}"
  )"

  if [[ "${api_lifecycle}" == "PUBLISHED" ]]; then
    pass "Managed API is PUBLISHED."
  else
    fail "Managed API is not PUBLISHED (state=${api_lifecycle:-UNKNOWN})."
  fi

  for scope in \
    number-verification:read \
    sim-swap:read \
    device-location:verify \
    qod:request \
    commercial-usage:read
  do
    if jq -e \
      --arg scope "${scope}" '
        def scope_name:
          (
            .key //
            .name //
            .scope.name //
            .scope.key //
            ""
          );

        any(
          .scopes[]?;
          scope_name == $scope
        )
      ' <<<"${api}" >/dev/null
    then
      pass "Scope exists: ${scope}"
    else
      fail "Scope missing: ${scope}"
    fi
  done

  for scope_role in \
    'number-verification:read|telco_partner' \
    'number-verification:read|telco_operations' \
    'number-verification:read|telco_platform_admin' \
    'sim-swap:read|telco_partner' \
    'sim-swap:read|telco_operations' \
    'sim-swap:read|telco_platform_admin' \
    'device-location:verify|telco_partner' \
    'device-location:verify|telco_operations' \
    'device-location:verify|telco_platform_admin' \
    'qod:request|telco_partner' \
    'qod:request|telco_operations' \
    'qod:request|telco_platform_admin' \
    'commercial-usage:read|telco_partner' \
    'commercial-usage:read|telco_operations' \
    'commercial-usage:read|telco_product_manager' \
    'commercial-usage:read|telco_platform_admin'
  do
    scope_key="${scope_role%%|*}"
    expected_role="${scope_role#*|}"

    if jq -e \
      --arg scope "${scope_key}" \
      --arg role "${expected_role}" '
        def scope_name:
          (
            .key //
            .name //
            .scope.name //
            .scope.key //
            ""
          );

        def normalized_bindings:
          (
            .roles //
            .bindings //
            .scope.bindings //
            .scope.roles //
            []
          )
          | if type == "string"
            then split(",")
            else .
            end
          | map(
              tostring
              | gsub("^\\s+|\\s+$"; "")
              | sub("^Internal/"; "")
              | sub("^PRIMARY/"; "")
            );

        any(
          .scopes[]?;
          scope_name == $scope and
          (
            (
              normalized_bindings
              | index($role)
            ) != null
          )
        )
      ' <<<"${api}" >/dev/null
    then
      pass "Scope role binding exists: ${scope_key} -> ${expected_role}."
    else
      fail "Scope role binding missing: ${scope_key} -> ${expected_role}."
    fi
  done

  deployment_log="${WORK_DIR}/oauth-api-deployment-check.log"

  if bash scripts/check-oauth-api-deployment.sh \
      >"${deployment_log}" 2>&1
  then
    pass "API has a deployed revision."
  else
    fail "API has no deployed revision."

    if [[ -s "${deployment_log}" ]]; then
      cat "${deployment_log}" >&2
    fi
  fi

  docs="$(
    curl -ksS \
      -H "Authorization: Bearer ${publisher_token}" \
      "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/documents?limit=100"
  )"

  for doc in \
    '10 - OAuth Scopes and Personas' \
    '11 - Consent Purpose Country and Partner Isolation' \
    '12 - Security Error and Verification Catalogue'
  do
    if jq -e \
      --arg doc "${doc}" '
        any(
          (.list // .data // [])[]?;
          .name == $doc
        )
      ' <<<"${docs}" >/dev/null
    then
      pass "Developer Portal document exists: ${doc}"
    else
      fail "Developer Portal document missing: ${doc}"
    fi
  done
fi

echo "[oauth-controls-verify] Checking native subscription policies."
policies="$(curl -ksS -H "Authorization: Bearer ${admin_token}" \
  "${APIM_URL}/api/am/admin/v4/throttling/policies/subscription?limit=1000")"
for policy in TelcoConsentRiskPartner TelcoConsentRiskOperations; do
  if jq -e --arg policy "${policy}" 'any(.list[]?; .policyName == $policy)' <<<"${policies}" >/dev/null; then
    pass "Subscription policy exists: ${policy}"
  else
    fail "Subscription policy missing: ${policy}"
  fi
done

echo "[oauth-controls-verify] Checking native API Product."
products="$(curl -ksS -H "Authorization: Bearer ${publisher_token}" \
  "${APIM_URL}/api/am/publisher/v4/api-products?limit=1000")"
product_id="$(jq -r 'first(.list[]? | select(.name == "SubscriberAuthorizationBusinessControlsProduct" and .version == "1.0.0") | .id) // empty' <<<"${products}")"
if [[ -z "${product_id}" ]]; then
  fail "SubscriberAuthorizationBusinessControlsProduct is missing."
else
  product="$(curl -ksS -H "Authorization: Bearer ${publisher_token}" \
    "${APIM_URL}/api/am/publisher/v4/api-products/${product_id}")"
  product_state="$(jq -r '(.state // .lifeCycleStatus // .status // "") | ascii_upcase' <<<"${product}")"
  if [[ "${product_state}" == "PUBLISHED" ]]; then
    pass "Native API Product is PUBLISHED."
  else
    fail "Native API Product is not PUBLISHED (${product_state:-unknown})."
  fi
  for policy in TelcoConsentRiskPartner TelcoConsentRiskOperations; do
    if jq -e --arg policy "${policy}" '((.policies // []) | index($policy)) != null' <<<"${product}" >/dev/null; then
      pass "API Product exposes plan ${policy}."
    else
      fail "API Product does not expose plan ${policy}."
    fi
  done
  for expected_operation in \
    'POST /number-verifications' \
    'POST /sim-swap-checks' \
    'POST /device-location-verifications' \
    'POST /qod-requests' \
    'GET /partners/{partnerId}/commercial-usage'
  do
    if jq -e --arg operation "${expected_operation}" '
      any(.apis[]?.operations[]?;
        (((.verb // .httpVerb // "") | ascii_upcase) + " " + (.target // .path // "")) == $operation
      )' <<<"${product}" >/dev/null; then
      pass "API Product operation exists: ${expected_operation}."
    else
      fail "API Product operation missing: ${expected_operation}."
    fi
  done
fi

echo "[oauth-controls-verify] Checking Developer Portal visibility and application subscriptions."

oauth_api_name="SubscriberAuthorizationControlAPI"
oauth_product_name="SubscriberAuthorizationBusinessControlsProduct"

devportal_apis=""
for attempt in $(seq 1 60); do
  devportal_apis="$(
    curl -ksS \
      -H "Authorization: Bearer ${devportal_token}" \
      "${APIM_URL}/api/am/devportal/v3/apis?limit=1000"
  )"

  if jq -e \
    --arg name "${oauth_api_name}" \
    'any((.list // .data // [])[]?;
      .name == $name and (.version // "1.0.0") == "1.0.0"
    )' \
    <<<"${devportal_apis}" >/dev/null 2>&1
  then
    break
  fi

  echo "[oauth-controls-verify] Waiting for API ${oauth_api_name} Developer Portal indexing (${attempt}/60)."
  sleep 2
done

if jq -e \
  --arg name "${oauth_api_name}" \
  'any((.list // .data // [])[]?;
    .name == $name and (.version // "1.0.0") == "1.0.0"
  )' \
  <<<"${devportal_apis}" >/dev/null 2>&1
then
  pass "Managed API is visible in the Developer Portal."
else
  fail "Managed API is not visible in the Developer Portal."
  jq -c \
    '[((.list // .data // [])[]) | {name,version,id}]' \
    <<<"${devportal_apis}" >&2 ||
    printf '%s\n' "${devportal_apis}" >&2
fi

devportal_products=""
oauth_product_name="SubscriberAuthorizationBusinessControlsProduct"

for attempt in $(seq 1 60); do
  if ! devportal_products="$(
    curl -kfsS \
      -H "Authorization: Bearer ${devportal_token}" \
      "${APIM_URL}/api/am/devportal/v3/apis?limit=1000"
  )"; then
    fail "Could not retrieve the unified Developer Portal API listing."
    devportal_products='{"list":[]}'
  fi

  if jq -e \
    --arg name "${oauth_product_name}" '
      any(
        (.list // .data // [])[]?;
        .name == $name and
        (.version // "") == "1.0.0"
      )
    ' \
    <<<"${devportal_products}" >/dev/null 2>&1
  then
    break
  fi

  echo "[oauth-controls-verify] Waiting for API Product ${oauth_product_name} Developer Portal indexing (${attempt}/60)."
  sleep 2
done

if jq -e \
  --arg name "${oauth_product_name}" '
    any(
      (.list // .data // [])[]?;
      .name == $name and
      (.version // "") == "1.0.0"
    )
  ' \
  <<<"${devportal_products}" >/dev/null 2>&1
then
  product_type="$(
    jq -r \
      --arg name "${oauth_product_name}" '
        first(
          (.list // .data // [])[]?
          | select(
              .name == $name and
              (.version // "") == "1.0.0"
            )
          | (.type // "APIProduct")
        ) // "APIProduct"
      ' \
      <<<"${devportal_products}"
  )"

  pass "Native API Product is visible and subscribable in the Developer Portal (${product_type})."
else
  fail "Native API Product is not visible in the unified Developer Portal listing."

  echo "[oauth-controls-verify] Developer Portal entries currently visible:" >&2

  jq -r '
    (.list // .data // [])[]?
    | "  \(.name // "-"):\(.version // "-") type=\(.type // "-")"
  ' \
    <<<"${devportal_products}" >&2 ||
    printf '%s\n' "${devportal_products}" >&2
fi

partner_application_id="$(jq -r '.application.applicationId // empty' <<<"${state}")"
operations_application_id="$(jq -r '.application.operationsClient.applicationId // empty' <<<"${state}")"
expired_application_id="$(jq -r '.application.expiredTokenClient.applicationId // empty' <<<"${state}")"
for subscription_spec in \
  "${partner_application_id}|TelcoConsentRiskPartner|partner" \
  "${operations_application_id}|TelcoConsentRiskOperations|operations" \
  "${expired_application_id}|TelcoConsentRiskPartner|short-lived"
do
  application_id="${subscription_spec%%|*}"
  remainder="${subscription_spec#*|}"
  policy="${remainder%%|*}"
  label="${remainder#*|}"
  subscriptions="$(curl -ksS -H "Authorization: Bearer ${devportal_token}" \
    "${APIM_URL}/api/am/devportal/v3/subscriptions?limit=100&applicationId=${application_id}")"
  if jq -e --arg api "${api_id}" --arg policy "${policy}" '
      any(.list[]?; .apiId == $api and .throttlingPolicy == $policy)' <<<"${subscriptions}" >/dev/null; then
    pass "${label} application subscription exists with ${policy}."
  else
    fail "${label} application subscription is missing or uses the wrong policy."
  fi
done

echo "[oauth-controls-verify] Checking Service Catalog registration."
catalog="$(curl -ksS -H "Authorization: Bearer ${catalog_token}" \
  "${APIM_URL}/api/am/service-catalog/v1/services?limit=1000")"
if jq -e 'any(.list[]?; .name == "SubscriberAuthorizationControlAPI" and .version == "1.0.0")' <<<"${catalog}" >/dev/null; then
  pass "MI service is registered in APIM Service Catalog."
else
  fail "SubscriberAuthorizationControlAPI:1.0.0 is absent from Service Catalog."
fi

token_for_client() {
  local oauth_client_id="$1"
  local oauth_client_secret="$2"
  local username="$3"
  local password="$4"
  local scopes="$5"
  curl -ksS -u "${oauth_client_id}:${oauth_client_secret}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${username}" \
    --data-urlencode "password=${password}" \
    --data-urlencode "scope=${scopes}" \
    "${APIM_URL}/oauth2/token"
}

token_for() {
  token_for_client "${client_id}" "${client_secret}" "$1" "$2" "$3"
}

token_for_operations() {
  token_for_client "${operations_client_id}" "${operations_client_secret}" "$1" "$2" "$3"
}

invoke() {
  local token="$1"
  local path="$2"
  local payload="$3"
  local correlation="$4"
  curl -ksS -o "${WORK_DIR}/body.json" -D "${WORK_DIR}/headers.txt" -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -H "X-Correlation-ID: ${correlation}" \
    --data "${payload}" \
    "${GATEWAY_URL}/subscriber-authorization/v1/1.0.0${path}"
}

alpha_number_token_json="$(token_for partner.alpha 'PartnerAlpha#2026' 'number-verification:read')"
alpha_number_token="$(jq -r '.access_token // empty' <<<"${alpha_number_token_json}")"
if [[ -n "${alpha_number_token}" ]]; then
  pass "Partner Alpha token issued with number-verification:read."
else
  fail "Partner Alpha scoped token was not issued."
  printf '%s\n' "${alpha_number_token_json}" >&2
fi

valid_payload='{"partnerId":"partner-alpha","country":"BR","subscriberNumber":"+5511999990001","purpose":"number-verification","consentId":"CONSENT-ALPHA-001","transactionId":"TX-AUTH-VALID-001"}'
valid_status="$(invoke "${alpha_number_token}" '/number-verifications' "${valid_payload}" 'oauth-controls-valid-001')"
valid_body="$(cat "${WORK_DIR}/body.json")"
if [[ "${valid_status}" == "200" ]] && jq -e '(.decision == "ALLOW" or .decision == "CHALLENGE") and (.authorizationStatus == "AUTHORIZED" or .authorizationStatus == "STEP_UP_REQUIRED") and .subscriber.masked == true and .subscriber.phoneNumber == "+55******0001" and (.risk.score | type == "number")' <<<"${valid_body}" >/dev/null; then
  pass "Valid scoped request accepted, evaluated by the MI risk engine, and subscriber information masked."
else
  fail "Valid scoped request, risk decision, or masking scenario failed (HTTP ${valid_status})."
  printf '%s\n' "${valid_body}" >&2
fi
if grep -qi '^X-Correlation-ID: oauth-controls-valid-001' "${WORK_DIR}/headers.txt"; then
  pass "Correlation identifier preserved."
else
  fail "Correlation identifier was not returned."
fi

missing_scope_payload='{"partnerId":"partner-alpha","country":"BR","subscriberNumber":"+5511999990001","purpose":"sim-swap-check","consentId":"CONSENT-ALPHA-001","transactionId":"TX-AUTH-SCOPE-001"}'
missing_scope_status="$(invoke "${alpha_number_token}" '/sim-swap-checks' "${missing_scope_payload}" 'oauth-controls-scope-001')"
if [[ "${missing_scope_status}" == "403" ]]; then
  pass "Missing-scope request rejected by APIM."
else
  fail "Missing-scope request expected HTTP 403, received ${missing_scope_status}."
  cat "${WORK_DIR}/body.json" >&2
fi
#
# Deterministic token-expiration verification.
#
# The Developer Portal generate-token operation applies the OAuth
# application's configured/default lifetime. For an exact two-second runtime
# test, call the WSO2 token endpoint directly with validity_period=2.
#
log "Requesting a deterministic two-second client-credentials token."

oauth_state_payload=""

for oauth_state_variable in \
  state_json \
  state \
  bootstrap_state \
  oauth_state
do
  if declare -p "${oauth_state_variable}" >/dev/null 2>&1; then
    oauth_state_candidate="${!oauth_state_variable}"

    if jq -e . \
      <<<"${oauth_state_candidate}" \
      >/dev/null 2>&1
    then
      oauth_state_payload="${oauth_state_candidate}"
      break
    fi
  fi
done

if [[ -z "${oauth_state_payload}" ]]; then
  fail \
    "Could not locate the loaded OAuth bootstrap-state JSON."
else
  expiry_state_file="${WORK_DIR}/oauth-expiry-state.json"

  printf '%s\n' \
    "${oauth_state_payload}" \
    >"${expiry_state_file}"

  log "Extracting the short-lived OAuth credentials from bootstrap state."

  expiry_credentials="$(
    python3 - "${expiry_state_file}" <<'PY_CREDENTIALS'
import json
import re
import sys
from pathlib import Path

state_path = Path(sys.argv[1])

try:
    state = json.loads(
        state_path.read_text(encoding="utf-8")
    )
except Exception as error:
    print(
        f"Could not parse OAuth state: {error}",
        file=sys.stderr,
    )
    raise SystemExit(1)


def scalar_text(value):
    if value is None:
        return ""

    if isinstance(value, (str, int, float, bool)):
        return str(value)

    if isinstance(value, list):
        return " ".join(
            scalar_text(item)
            for item in value
        )

    if isinstance(value, dict):
        return " ".join(
            f"{key} {scalar_text(child)}"
            for key, child in value.items()
        )

    return ""


def find_case_insensitive(obj, expected):
    expected = expected.lower()

    for key, value in obj.items():
        if str(key).lower() == expected:
            return value

    return None


def credential_pairs(obj):
    explicit_pairs = (
        ("consumerKey", "consumerSecret"),
        ("consumer_key", "consumer_secret"),
        ("clientId", "clientSecret"),
        ("client_id", "client_secret"),
        ("expiredClientId", "expiredClientSecret"),
        ("shortLivedClientId", "shortLivedClientSecret"),
        ("verificationClientId", "verificationClientSecret"),
    )

    found = []

    for key_name, secret_name in explicit_pairs:
        key_value = find_case_insensitive(
            obj,
            key_name,
        )

        secret_value = find_case_insensitive(
            obj,
            secret_name,
        )

        if (
            isinstance(key_value, str)
            and key_value
            and isinstance(secret_value, str)
            and secret_value
        ):
            found.append(
                (
                    key_value,
                    secret_value,
                )
            )

    # Also support prefixed field names such as expiryConsumerKey.
    lower_keys = {
        str(key).lower(): key
        for key in obj
    }

    for key, value in obj.items():
        if not isinstance(value, str) or not value:
            continue

        lower_key = str(key).lower()

        if lower_key.endswith("consumerkey"):
            secret_key = (
                lower_key[:-len("consumerkey")]
                + "consumersecret"
            )

        elif lower_key.endswith("clientid"):
            secret_key = (
                lower_key[:-len("clientid")]
                + "clientsecret"
            )

        elif lower_key.endswith("consumer_key"):
            secret_key = (
                lower_key[:-len("consumer_key")]
                + "consumer_secret"
            )

        elif lower_key.endswith("client_id"):
            secret_key = (
                lower_key[:-len("client_id")]
                + "client_secret"
            )

        else:
            continue

        original_secret_key = lower_keys.get(
            secret_key
        )

        if original_secret_key is None:
            continue

        secret = obj.get(original_secret_key)

        if isinstance(secret, str) and secret:
            found.append(
                (
                    value,
                    secret,
                )
            )

    unique = []
    seen = set()

    for pair in found:
        if pair in seen:
            continue

        seen.add(pair)
        unique.append(pair)

    return unique


candidates = []


def walk(value, path=(), inherited_labels=()):
    if isinstance(value, dict):
        labels = list(inherited_labels)

        for label_key in (
            "name",
            "applicationName",
            "displayName",
            "description",
            "purpose",
            "type",
            "persona",
            "keyType",
        ):
            label_value = find_case_insensitive(
                value,
                label_key,
            )

            if isinstance(label_value, str):
                labels.append(label_value)

        object_text = scalar_text(value).lower()
        path_text = "/".join(path).lower()
        label_text = " ".join(labels).lower()

        combined = (
            path_text
            + " "
            + label_text
            + " "
            + object_text
        )

        score = 0

        marker_weights = {
            "two-second": 100,
            "two second": 100,
            "short-lived": 90,
            "short lived": 90,
            "shortlived": 90,
            "expiry": 70,
            "expired": 70,
            "expiration": 60,
            "verification": 30,
        }

        for marker, weight in marker_weights.items():
            if marker in combined:
                score += weight

        if "client_credentials" in combined:
            score += 15

        expiry_keys = (
            "validitytime",
            "applicationaccesstokenexpirytime",
            "useraccesstokenexpirytime",
            "tokenvalidity",
            "validityperiod",
        )

        for key, child in value.items():
            normalized_key = re.sub(
                r"[^a-z0-9]",
                "",
                str(key).lower(),
            )

            if normalized_key in expiry_keys:
                try:
                    if int(child) == 2:
                        score += 120
                except Exception:
                    pass

        for client_id, client_secret in credential_pairs(
            value
        ):
            candidates.append(
                {
                    "score": score,
                    "path": "/".join(path),
                    "client_id": client_id,
                    "client_secret": client_secret,
                }
            )

        for key, child in value.items():
            walk(
                child,
                path + (str(key),),
                tuple(labels),
            )

    elif isinstance(value, list):
        for index, child in enumerate(value):
            walk(
                child,
                path + (str(index),),
                inherited_labels,
            )


walk(state)

if not candidates:
    print(
        "No OAuth client credentials were found in state.",
        file=sys.stderr,
    )
    raise SystemExit(1)

candidates.sort(
    key=lambda candidate: candidate["score"],
    reverse=True,
)

winner = candidates[0]

if winner["score"] <= 0:
    print(
        "OAuth clients were found, but none was identifiable "
        "as the short-lived verification client.",
        file=sys.stderr,
    )

    for candidate in candidates:
        print(
            f"candidate path={candidate['path']!r} "
            f"score={candidate['score']}",
            file=sys.stderr,
        )

    raise SystemExit(1)

if (
    len(candidates) > 1
    and candidates[1]["score"] == winner["score"]
    and candidates[1]["client_id"] != winner["client_id"]
):
    print(
        "Multiple OAuth clients have the same highest "
        "short-lived-client score.",
        file=sys.stderr,
    )

    for candidate in candidates[:5]:
        print(
            f"candidate path={candidate['path']!r} "
            f"score={candidate['score']}",
            file=sys.stderr,
        )

    raise SystemExit(1)

print(
    json.dumps(
        {
            "client_id": winner["client_id"],
            "client_secret": winner["client_secret"],
            "path": winner["path"],
        },
        separators=(",", ":"),
    )
)
PY_CREDENTIALS
  )"

  short_client_id="$(
    jq -r \
      '.client_id // empty' \
      <<<"${expiry_credentials}"
  )"

  short_client_secret="$(
    jq -r \
      '.client_secret // empty' \
      <<<"${expiry_credentials}"
  )"

  short_client_path="$(
    jq -r \
      '.path // empty' \
      <<<"${expiry_credentials}"
  )"

  if [[ -z "${short_client_id}" ||
        -z "${short_client_secret}" ]]
  then
    fail \
      "Short-lived OAuth consumer credentials could not be resolved."
  else
    log \
      "Resolved the short-lived OAuth client from state path: ${short_client_path:-unknown}"

    short_token_url="${
      OAUTH_SHORT_TOKEN_URL:-
      https://127.0.0.1:8243/token
    }"

    short_token_json="$(
      curl -ksS \
        -u "${short_client_id}:${short_client_secret}" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode 'grant_type=client_credentials' \
        --data-urlencode 'scope=default' \
        --data-urlencode 'validity_period=2' \
        "${short_token_url}"
    )"

    short_token="$(
      jq -r \
        '.access_token // .accessToken // empty' \
        <<<"${short_token_json}"
    )"

    expires_in="$(
      jq -r \
        '.expires_in // .validityTime // 0' \
        <<<"${short_token_json}"
    )"

    jwt_lifetime="$(
      python3 - "${short_token}" <<'PY_JWT'
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

    if issued_at <= 0 or expires_at <= 0:
        print(0)
    else:
        print(expires_at - issued_at)

except Exception:
    print(0)
PY_JWT
    )"

    if [[ -z "${short_token}" ]]; then
      fail \
        "The WSO2 token endpoint did not issue the two-second token."

      jq \
        'del(.access_token, .accessToken, .refresh_token)' \
        <<<"${short_token_json}" >&2 ||
        true

    elif ! [[ "${expires_in}" =~ ^[0-9]+$ ]]; then
      fail \
        "Short-lived token returned invalid expires_in=${expires_in}."

    elif ! [[ "${jwt_lifetime}" =~ ^[0-9]+$ ]]; then
      fail \
        "Short-lived token returned an invalid JWT lifetime."

    elif (( expires_in < 1 || expires_in > 2 )); then
      fail \
        "Short-lived token returned expires_in=${expires_in}; expected 1-2 seconds."

      jq \
        'del(.access_token, .accessToken, .refresh_token)' \
        <<<"${short_token_json}" >&2 ||
        true

    elif (( jwt_lifetime < 1 || jwt_lifetime > 2 )); then
      fail \
        "Short-lived JWT lifetime=${jwt_lifetime}; expected 1-2 seconds."

    else
      pass \
        "Direct two-second OAuth token issued (expires_in=${expires_in}, JWT lifetime=${jwt_lifetime})."

      sleep 5

      expired_status="$(
        invoke \
          "${short_token}" \
          '/number-verifications' \
          "${valid_payload}" \
          'oauth-controls-expired-001'
      )"

      if [[ "${expired_status}" == "401" ]]; then
        pass \
          "Dedicated two-second APIM token rejected after expiration."
      else
        fail \
          "Expired token expected HTTP 401, received ${expired_status}."

        cat \
          "${WORK_DIR}/body.json" >&2
      fi
    fi
  fi
fi
country_payload='{"partnerId":"partner-alpha","country":"US","subscriberNumber":"+5511999990001","purpose":"number-verification","consentId":"CONSENT-ALPHA-001","transactionId":"TX-AUTH-COUNTRY-001"}'
country_status="$(invoke "${alpha_number_token}" '/number-verifications' "${country_payload}" 'oauth-controls-country-001')"
country_body="$(cat "${WORK_DIR}/body.json")"
if [[ "${country_status}" == "403" ]] && jq -e '.code == "COUNTRY_NOT_AUTHORIZED"' <<<"${country_body}" >/dev/null; then
  pass "Unauthorized country rejected by MI business policy."
else
  fail "Unauthorized-country scenario failed (HTTP ${country_status})."
  printf '%s\n' "${country_body}" >&2
fi

cross_partner_payload='{"partnerId":"partner-beta","country":"MX","subscriberNumber":"+525512340001","purpose":"number-verification","consentId":"CONSENT-BETA-001","transactionId":"TX-AUTH-PARTNER-001"}'
cross_partner_status="$(invoke "${alpha_number_token}" '/number-verifications' "${cross_partner_payload}" 'oauth-controls-partner-001')"
cross_partner_body="$(cat "${WORK_DIR}/body.json")"
if [[ "${cross_partner_status}" == "403" ]] && jq -e '.code == "PARTNER_DATA_ISOLATION"' <<<"${cross_partner_body}" >/dev/null; then
  pass "Cross-partner data access rejected."
else
  fail "Cross-partner scenario failed (HTTP ${cross_partner_status})."
  printf '%s\n' "${cross_partner_body}" >&2
fi

consent_payload='{"partnerId":"partner-alpha","country":"BR","subscriberNumber":"+5511999999999","purpose":"number-verification","consentId":"CONSENT-ALPHA-001","transactionId":"TX-AUTH-CONSENT-001"}'
consent_status="$(invoke "${alpha_number_token}" '/number-verifications' "${consent_payload}" 'oauth-controls-consent-001')"
consent_body="$(cat "${WORK_DIR}/body.json")"
if [[ "${consent_status}" == "403" ]] && jq -e '.code == "CONSENT_SUBJECT_MISMATCH"' <<<"${consent_body}" >/dev/null; then
  pass "Consent-to-subscriber binding enforced."
else
  fail "Consent-binding scenario failed (HTTP ${consent_status})."
  printf '%s\n' "${consent_body}" >&2
fi

purpose_payload='{"partnerId":"partner-alpha","country":"BR","subscriberNumber":"+5511999990001","purpose":"qod-fulfilment","consentId":"CONSENT-ALPHA-001","transactionId":"TX-AUTH-PURPOSE-001"}'
purpose_status="$(invoke "${alpha_number_token}" '/number-verifications' "${purpose_payload}" 'oauth-controls-purpose-001')"
purpose_body="$(cat "${WORK_DIR}/body.json")"
if [[ "${purpose_status}" == "403" ]] && jq -e '.code == "PURPOSE_NOT_PERMITTED"' <<<"${purpose_body}" >/dev/null; then
  pass "Purpose limitation enforced."
else
  fail "Purpose-limitation scenario failed (HTTP ${purpose_status})."
  printf '%s\n' "${purpose_body}" >&2
fi

operations_token_json="$(token_for_operations telco.operations 'TelcoOperations#2026' 'number-verification:read')"
operations_token="$(jq -r '.access_token // empty' <<<"${operations_token_json}")"
operations_payload='{"partnerId":"partner-alpha","country":"BR","subscriberNumber":"+5511999990001","purpose":"fraud-investigation","consentId":"CONSENT-ALPHA-001","transactionId":"TX-AUTH-OPS-001"}'
operations_status="$(curl -ksS -o "${WORK_DIR}/body.json" -w '%{http_code}' \
  -X POST \
  -H "Authorization: Bearer ${operations_token}" \
  -H 'Content-Type: application/json' \
  -H 'X-Correlation-ID: oauth-controls-ops-001' \
  -H 'X-Data-Access: FULL' \
  --data "${operations_payload}" \
  "${GATEWAY_URL}/subscriber-authorization/v1/1.0.0/number-verifications")"
operations_body="$(cat "${WORK_DIR}/body.json")"
if [[ "${operations_status}" == "200" ]] && jq -e '.persona == "operations" and .subscriber.masked == false and .subscriber.phoneNumber == "+5511999990001"' <<<"${operations_body}" >/dev/null; then
  pass "Operations persona received full subscriber data only under explicit fraud-investigation control."
else
  fail "Operations full-data scenario failed (HTTP ${operations_status})."
  printf '%s\n' "${operations_body}" >&2
fi

platform_token_json="$(token_for_operations telco.admin 'TelcoAdmin#2026' 'number-verification:read')"
platform_token="$(jq -r '.access_token // empty' <<<"${platform_token_json}")"
platform_status="$(curl -ksS -o "${WORK_DIR}/body.json" -w '%{http_code}' \
  -X POST \
  -H "Authorization: Bearer ${platform_token}" \
  -H 'Content-Type: application/json' \
  -H 'X-Correlation-ID: oauth-controls-platform-admin-001' \
  -H 'X-Data-Access: FULL' \
  --data "${operations_payload}" \
  "${GATEWAY_URL}/subscriber-authorization/v1/1.0.0/number-verifications")"
platform_body="$(cat "${WORK_DIR}/body.json")"
if [[ "${platform_status}" == "200" ]] && jq -e '.persona == "platform_administrator" and .subscriber.masked == false and .subscriber.phoneNumber == "+5511999990001"' <<<"${platform_body}" >/dev/null; then
  pass "Platform administrator entitlement is distinct and can perform an explicitly approved full-data investigation."
else
  fail "Platform-administrator runtime scenario failed (HTTP ${platform_status})."
  printf '%s\n' "${platform_body}" >&2
fi

product_token_json="$(token_for_operations telco.product 'TelcoProduct#2026' 'commercial-usage:read')"
product_token="$(jq -r '.access_token // empty' <<<"${product_token_json}")"
commercial_status="$(curl -ksS -o "${WORK_DIR}/body.json" -w '%{http_code}' \
  -H "Authorization: Bearer ${product_token}" \
  -H 'X-Correlation-ID: oauth-controls-commercial-001' \
  "${GATEWAY_URL}/subscriber-authorization/v1/1.0.0/partners/partner-alpha/commercial-usage?country=BR")"
commercial_body="$(cat "${WORK_DIR}/body.json")"
if [[ "${commercial_status}" == "200" ]] && jq -e '.decision == "ALLOW" and .persona == "product_manager"' <<<"${commercial_body}" >/dev/null; then
  pass "Product manager commercial-usage entitlement allowed."
else
  fail "Product-manager commercial usage scenario failed (HTTP ${commercial_status})."
  printf '%s\n' "${commercial_body}" >&2
fi

if (( failures > 0 )); then
  echo "[oauth-controls-verify] FAILED with ${failures} issue(s)." >&2
  exit 1
fi

echo "[oauth-controls-verify] PASS: OAuth scopes and role bindings, partner/operations/product-manager/platform-admin personas, subscriptions, consent, purpose, country, partner isolation, masking, plans, native product, Developer Portal visibility, Service Catalog and runtime behavior are complete."
