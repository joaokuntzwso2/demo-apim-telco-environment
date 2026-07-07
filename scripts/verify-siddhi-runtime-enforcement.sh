#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
GATEWAY_URL="${WSO2_APIM_GATEWAY_PUBLIC_URL:-https://127.0.0.1:8243}"
BACKEND_URL="${TELCO_BACKEND_PUBLIC_URL:-http://127.0.0.1:8081}"
MI_URL="${WSO2_MI_PUBLIC_URL:-http://127.0.0.1:8290}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD_VALUE="${APIM_PASSWORD:-admin}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/telco-siddhi-runtime.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"; }
require_file() { [[ -f "$1" ]] || fail "Missing file: $1"; }

for cmd in curl jq python3 docker awk grep sed; do require "$cmd"; done

files=(
  docker-compose.yml
  docker-compose.kafka.yml
  docker-compose.opa.yml
  docker-compose.mi.yml
  docker-compose.mi.soap.yml
  docker-compose.observability.yml
  docker-compose.runtime-persistence.yml
  docker-compose.siddhi-runtime.yml
)
compose=(docker compose)
for file in "${files[@]}"; do
  [[ -f "$file" ]] && compose+=( -f "$file" )
done

json_curl() {
  curl -ksS --connect-timeout 3 --max-time 20 --fail-with-body "$@"
}

http_json() {
  local method="$1" url="$2" token="$3"
  shift 3
  curl -ksS --connect-timeout 3 --max-time 20 --fail-with-body -X "$method" \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/json' \
    "$@" "$url"
}

printf '\n=== Static artifact verification ===\n'
for file in \
  artifacts/apim-admin/custom-throttling-policies/telco-siddhi-custom-policies.json \
  services/wso2-apim/sequences/_throttle_out_handler_.xml \
  services/wso2-mi/synapse-configs/default/api/RuntimePolicyAlertAPI.xml \
  services/wso2-mi/synapse-configs/default/endpoints/RuntimePolicyKafkaEndpoint.xml \
  contracts/openapi/network-slice.openapi.yaml \
  contracts/openapi/open-gateway-sim-swap-risk.openapi.yaml \
  contracts/openapi/runtime-policy-alert.openapi.yaml \
  artifacts/postman/telco-siddhi-runtime-enforcement.postman_collection.json \
  services/apim-bootstrapper/src/siddhi-runtime-enforcement-setup.js \
  docs/siddhi-runtime-enforcement.md; do
  require_file "$file"
done

jq -e '
  length == 2 and
  any(.[]; .policyName == "TelcoSiddhiSimSwapFraudFairUsePolicy" and
      .keyTemplate == "$appId:$apiContext:$apiVersion" and
      (.siddhiQuery | contains("/open-gateway/sim-swap/v1")) and
      (.siddhiQuery | contains("count(throttleKey) >= 6")) and
      (.siddhiQuery | contains("timeBatch(15 sec)"))) and
  any(.[]; .policyName == "TelcoSiddhiQoDAssuranceBurstPolicy" and
      .keyTemplate == "$apiContext:$apiVersion" and
      (.siddhiQuery | contains("/network-slice/v1")) and
      (.siddhiQuery | contains("count(throttleKey) >= 9")) and
      (.siddhiQuery | contains("timeBatch(5 sec)")))
' artifacts/apim-admin/custom-throttling-policies/telco-siddhi-custom-policies.json >/dev/null \
  || fail 'Custom policy artifact does not contain the expected runtime keys, contexts and thresholds.'
pass 'Custom Siddhi policy artifact matches the deployed API contexts.'

python3 - <<'PY'
import json
import xml.etree.ElementTree as ET
from pathlib import Path
for p in [
    Path('services/wso2-apim/sequences/_throttle_out_handler_.xml'),
    Path('services/wso2-mi/synapse-configs/default/api/RuntimePolicyAlertAPI.xml'),
    Path('services/wso2-mi/synapse-configs/default/endpoints/RuntimePolicyKafkaEndpoint.xml'),
]:
    ET.parse(p)
json.loads(Path('artifacts/postman/telco-siddhi-runtime-enforcement.postman_collection.json').read_text())
json.loads(Path('services/apim-bootstrapper/package.json').read_text())
PY
pass 'APIM/MI XML and JSON artifacts are well formed.'

grep -q 'createQualityOnDemandSession' contracts/openapi/network-slice.openapi.yaml \
  || fail 'QoD operation is absent from NetworkSliceAPI contract.'
grep -q 'network.qod.request' contracts/openapi/network-slice.openapi.yaml \
  || fail 'QoD OAuth scope is absent from NetworkSliceAPI contract.'
grep -q 'TelcoSiddhiSimSwapFraudFairUsePolicy' contracts/openapi/open-gateway-sim-swap-risk.openapi.yaml \
  || fail 'SIM Swap runtime 429 contract is absent.'
grep -q 'telco.runtime.policy.alerts' services/telco-backend/src/kafka-broker.js \
  || fail 'Kafka alert topic is absent from backend topic list.'
grep -q 'RuntimePolicyAlertAPI' scripts/register-mi-service-catalog.sh \
  || fail 'RuntimePolicyAlertAPI is absent from Service Catalog registration.'
grep -q 'siddhi-runtime-enforcement-setup.js' services/apim-bootstrapper/package.json \
  || fail 'Runtime documentation bootstrap is absent from package start order.'
pass 'Contracts, Kafka topic, Service Catalog and bootstrap order are patched.'

printf '\n=== Runtime health verification ===\n'
json_curl "${APIM_URL}/services/Version" >/dev/null || fail 'APIM is not reachable.'
pass 'WSO2 API Manager is reachable.'
json_curl "${MI_URL}/internal/runtime-policy-alerts/v1/health" \
  | jq -e '.status == "UP" and .service == "RuntimePolicyAlertAPI"' >/dev/null \
  || fail 'RuntimePolicyAlertAPI health check failed.'
pass 'WSO2 Integrator RuntimePolicyAlertAPI is healthy.'
json_curl "${BACKEND_URL}/health" >/dev/null || fail 'Telco backend is not healthy.'
KAFKA_STATUS="$(json_curl "${BACKEND_URL}/api/v1/kafka/status")"
printf '%s' "$KAFKA_STATUS" | jq -e '.enabled == true and .connected == true and (.topics | index("telco.runtime.policy.alerts")) != null' >/dev/null \
  || fail 'Kafka is not enabled or runtime policy alert topic is missing.'
pass 'Kafka/Redpanda is enabled and the runtime alert topic is registered.'

printf '\n=== APIM OAuth client registration ===\n'
DCR_RESPONSE="$(
  curl -ksS --connect-timeout 3 --max-time 20 --fail-with-body \
    -u "${APIM_USER}:${APIM_PASSWORD_VALUE}" \
    -H 'Content-Type: application/json' \
    -d "{\"callbackUrl\":\"http://localhost:8080/callback\",\"clientName\":\"telco-siddhi-runtime-verifier-$(date +%s)-$$\",\"owner\":\"${APIM_USER}\",\"grantType\":\"password refresh_token client_credentials\",\"saasApp\":true}" \
    "${APIM_URL}/client-registration/v0.17/register"
)"
CLIENT_ID="$(printf '%s' "$DCR_RESPONSE" | jq -r '.clientId // empty')"
CLIENT_SECRET="$(printf '%s' "$DCR_RESPONSE" | jq -r '.clientSecret // empty')"
[[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]] || fail 'Dynamic client registration did not return credentials.'
pass 'Verifier OAuth client registered.'

password_token() {
  local scope="$1"
  curl -ksS --connect-timeout 3 --max-time 20 --fail-with-body \
    -u "${CLIENT_ID}:${CLIENT_SECRET}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${APIM_USER}" \
    --data-urlencode "password=${APIM_PASSWORD_VALUE}" \
    --data-urlencode "scope=${scope}" \
    "${APIM_URL}/oauth2/token" | jq -r '.access_token // empty'
}

ADMIN_TOKEN="$(password_token 'apim:admin_tier_view apim:admin_tier_manage')"
PUBLISHER_TOKEN="$(password_token 'apim:api_view apim:api_metadata_view apim:api_product_view apim:document_manage apim:document_create apim:document_update')"
CATALOG_TOKEN="$(password_token 'service_catalog:service_view service_catalog:service_write')"
DEVPORTAL_TOKEN="$(password_token 'apim:subscribe')"
[[ -n "$ADMIN_TOKEN" && -n "$PUBLISHER_TOKEN" && -n "$CATALOG_TOKEN" && -n "$DEVPORTAL_TOKEN" ]] \
  || fail 'Could not obtain all management-plane access tokens.'
pass 'Admin, Publisher, Developer Portal and Service Catalog tokens obtained.'

printf '\n=== Custom throttling policy verification ===\n'
CUSTOM_POLICIES="$(http_json GET "${APIM_URL}/api/am/admin/v4/throttling/policies/custom?limit=1000" "$ADMIN_TOKEN")"
policy_exists() {
  local name="$1" context="$2" expression="$3" window="$4"
  printf '%s' "$CUSTOM_POLICIES" | jq -e \
    --arg name "$name" --arg context "$context" --arg expression "$expression" --arg window "$window" '
      (if type == "array" then . else (.list // .data // []) end)
      | any(.[];
          .policyName == $name and
          (.isDeployed // true) != false and
          (.siddhiQuery | contains($context)) and
          (.siddhiQuery | contains($expression)) and
          (.siddhiQuery | contains($window)))
    ' >/dev/null
}
policy_exists 'TelcoSiddhiSimSwapFraudFairUsePolicy' '/open-gateway/sim-swap/v1' 'count(throttleKey) >= 6' 'timeBatch(15 sec)' \
  || fail 'SIM Swap custom policy is missing, undeployed or stale in APIM.'
policy_exists 'TelcoSiddhiQoDAssuranceBurstPolicy' '/network-slice/v1' 'count(throttleKey) >= 9' 'timeBatch(5 sec)' \
  || fail 'QoD custom policy is missing, undeployed or stale in APIM.'
pass 'Both custom policies are deployed with live API matching.'

printf '\n=== API, deployment, document and product verification ===\n'
APIS="$(http_json GET "${APIM_URL}/api/am/publisher/v4/apis?limit=1000" "$PUBLISHER_TOKEN")"
api_id() {
  local name="$1"
  printf '%s' "$APIS" | jq -r --arg name "$name" 'first(
  (if type == "array" then . else (.list // .data // []) end)[]?
  | select(.name == $name and .version == "1.0.0")
  | .id
) // empty'
}
verify_api() {
  local name="$1"
  local id state deployments docs
  id="$(api_id "$name")"
  [[ -n "$id" ]] || fail "Required API not found: ${name}:1.0.0"
  state="$(printf '%s' "$APIS" | jq -r --arg id "$id" 'first(.list[]? | select(.id == $id) | (.lifeCycleStatus // .state // ""))')"
  [[ "$state" == 'PUBLISHED' ]] || fail "${name}:1.0.0 is not PUBLISHED (state=${state})."
  deployments="$(http_json GET "${APIM_URL}/api/am/publisher/v4/apis/${id}/deployments" "$PUBLISHER_TOKEN")"
  printf '%s' "$deployments" | jq -e '((if type == "array" then . else (.list // .data // []) end) | length) > 0' >/dev/null \
    || fail "${name}:1.0.0 has no Gateway deployment."
  docs="$(http_json GET "${APIM_URL}/api/am/publisher/v4/apis/${id}/documents?limit=100" "$PUBLISHER_TOKEN")"
  for expected in \
    '01 - Business Overview' \
    '02 - Contract and CAMARA Alignment' \
    '03 - Authentication and First Call' \
    '04 - Consent and Privacy Requirements' \
    '05 - Error Catalogue' \
    '06 - Rate Limits and Commercial Plan' \
    '07 - SLA Support and Resilience' \
    '08 - Code Samples Postman and SDKs' \
    '09 - Sandbox Test Data' \
    '10 - Runtime Business Controls'; do
    printf '%s' "$docs" | jq -e --arg name "$expected" 'any(.list[]?; .name == $name)' >/dev/null \
      || fail "${name}:1.0.0 is missing Developer Portal document: ${expected}"
  done
  pass "${name}:1.0.0 is published, deployed and has all ten consumer documents." >&2
  printf '%s' "$id"
}

SIM_API_ID="$(verify_api OpenGatewaySimSwapRiskAPI | tail -n1)"
QOD_API_ID="$(verify_api NetworkSliceAPI | tail -n1)"

SIM_SWAGGER="$(http_json GET "${APIM_URL}/api/am/publisher/v4/apis/${SIM_API_ID}/swagger" "$PUBLISHER_TOKEN")"
printf '%s' "$SIM_SWAGGER" | grep -q 'TelcoSiddhiSimSwapFraudFairUsePolicy' \
  || fail 'Published SIM Swap definition does not document the runtime policy.'
QOD_SWAGGER="$(http_json GET "${APIM_URL}/api/am/publisher/v4/apis/${QOD_API_ID}/swagger" "$PUBLISHER_TOKEN")"
printf '%s' "$QOD_SWAGGER" | grep -q 'createQualityOnDemandSession' \
  || fail 'Published NetworkSliceAPI does not contain the QoD operation.'
printf '%s' "$QOD_SWAGGER" | grep -q 'network.qod.request' \
  || fail 'Published NetworkSliceAPI does not contain the QoD OAuth scope.'
pass 'Published API definitions contain the runtime 429 contracts and QoD scope.'

PRODUCTS="$(http_json GET "${APIM_URL}/api/am/publisher/v4/api-products?limit=1000" "$PUBLISHER_TOKEN")"
verify_product() {
  local name="$1" member="$2" operation_marker="$3" id state detail revisions swagger
  id="$(printf '%s' "$PRODUCTS" | jq -r --arg name "$name" 'first(
  (if type == "array" then . else (.list // .data // []) end)[]?
  | select(.name == $name and .version == "1.0.0")
  | .id
) // empty')"
  [[ -n "$id" ]] || fail "Required API Product not found: ${name}:1.0.0"
  state="$(printf '%s' "$PRODUCTS" | jq -r --arg id "$id" 'first(
  (if type == "array" then . else (.list // .data // []) end)[]?
  | select(.id == $id)
  | (.state // .lifeCycleStatus // "")
)')"
  [[ "$state" == 'PUBLISHED' ]] || fail "${name}:1.0.0 is not PUBLISHED (state=${state})."
  detail="$(http_json GET "${APIM_URL}/api/am/publisher/v4/api-products/${id}" "$PUBLISHER_TOKEN")"
  printf '%s' "$detail" | jq -e --arg member "$member" 'any(.apis[]?; (.name // .apiName) == $member)' >/dev/null \
    || fail "${name}:1.0.0 does not contain ${member}."
  swagger="$(http_json GET "${APIM_URL}/api/am/publisher/v4/api-products/${id}/swagger" "$PUBLISHER_TOKEN")"
  printf '%s' "$swagger" | grep -q "$operation_marker" \
    || fail "${name}:1.0.0 does not expose operation marker ${operation_marker}."
  revisions="$(http_json GET "${APIM_URL}/api/am/publisher/v4/api-products/${id}/revisions" "$PUBLISHER_TOKEN")"
  printf '%s' "$revisions" | jq -e '((if type == "array" then . else (.list // .data // []) end) | length) > 0' >/dev/null \
    || fail "${name}:1.0.0 has no revision."
  pass "${name}:1.0.0 is published, revisioned and exposes ${member}/${operation_marker}."
}
verify_product OpenGatewayFraudDefenseProduct OpenGatewaySimSwapRiskAPI getSimSwapRisk
verify_product FiveGNetworkMonetizationProduct NetworkSliceAPI createQualityOnDemandSession

SUBSCRIPTION_POLICIES="$(http_json GET "${APIM_URL}/api/am/admin/v4/throttling/policies/subscription?limit=1000" "$ADMIN_TOKEN")"
for policy in TelcoFreeTrial TelcoOpenGatewayTrustStarter TelcoOpenGatewayTrustPremium TelcoPartnerStandard TelcoPartnerPremium; do
  printf '%s' "$SUBSCRIPTION_POLICIES" | jq -e --arg p "$policy" '
    (if type == "array" then . else (.list // .data // []) end) | any(.[]; .policyName == $p)
  ' >/dev/null || fail "Required commercial/subscription policy missing: ${policy}"
done
pass 'All required commercial/subscription policies are present.'

DEVPORTAL_APIS="$(curl -ksS --connect-timeout 3 --max-time 20 --fail-with-body -H "Authorization: Bearer ${DEVPORTAL_TOKEN}" -H 'X-WSO2-Tenant: carbon.super' "${APIM_URL}/api/am/devportal/v3/apis?limit=1000")"
for api in OpenGatewaySimSwapRiskAPI NetworkSliceAPI; do
  printf '%s' "$DEVPORTAL_APIS" | jq -e --arg api "$api" 'any(.list[]?; .name == $api and .version == "1.0.0")' >/dev/null \
    || fail "${api}:1.0.0 is not visible through the Developer Portal API."
done
# APIM 4.7 exposes APIs and API Products through the same DevPortal
# marketplace listing. There is no separate /api-products collection route.
DEVPORTAL_PRODUCTS="$DEVPORTAL_APIS"
for product in OpenGatewayFraudDefenseProduct FiveGNetworkMonetizationProduct; do
  printf '%s' "$DEVPORTAL_PRODUCTS" | jq -e --arg product "$product" '
    (if type == "array" then . else (.list // .data // []) end)
    | any(.[]?; .name == $product and .version == "1.0.0")
  ' >/dev/null \
    || fail "${product}:1.0.0 is not visible through the Developer Portal API."
done
pass 'Affected APIs and API Products are visible in the Developer Portal.'

printf '\n=== MI Service Catalog verification ===\n'
CATALOG="$(http_json GET "${APIM_URL}/api/am/service-catalog/v1/services?limit=1000" "$CATALOG_TOKEN")"
printf '%s' "$CATALOG" | jq -e '
  any(.list[]?;
      .name == "RuntimePolicyAlertAPI" and
      .version == "1.0.0" and
      .definitionType == "OAS3" and
      (.serviceUrl | contains("/internal/runtime-policy-alerts/v1")))
' >/dev/null || fail 'RuntimePolicyAlertAPI is absent or incorrect in APIM Service Catalog.'
pass 'RuntimePolicyAlertAPI is registered in APIM Service Catalog.'

printf '\n=== Subscribed application credentials ===\n'
RUNTIME_STATE="$("${compose[@]}" run --rm --no-deps --entrypoint sh apim-bootstrapper -c 'cat /workspace/state/runtime.json')"
printf '%s' "$RUNTIME_STATE" | jq -e . >/dev/null || fail 'runtime.json could not be read from the bootstrap state volume.'
APP_CREDS="$(printf '%s' "$RUNTIME_STATE" | jq -c '
  def pair:
    {id: (.consumerKey? // .clientId? // ""), secret: (.consumerSecret? // .clientSecret? // "")}
    | select((.id | type == "string" and length > 0) and (.secret | type == "string" and length > 0));
  ([.. | objects
      | select((((.name? // .applicationName? // .appName? // "") | tostring | ascii_downcase) == "regional portal"))
      | .. | objects | pair] | first)
  // ([.. | objects | pair] | first)
  // {}
')"
APP_CLIENT_ID="$(printf '%s' "$APP_CREDS" | jq -r '.id // empty')"
APP_CLIENT_SECRET="$(printf '%s' "$APP_CREDS" | jq -r '.secret // empty')"
[[ -n "$APP_CLIENT_ID" && -n "$APP_CLIENT_SECRET" ]] \
  || fail 'Regional Portal application production credentials are missing from runtime.json.'
pass 'Regional Portal application credentials found.'

application_token() {
  local scope="$1"
  local response
  response="$(curl -ksS --connect-timeout 3 --max-time 20 --fail-with-body \
    -u "${APP_CLIENT_ID}:${APP_CLIENT_SECRET}" \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode "scope=${scope}" \
    "${APIM_URL}/oauth2/token")"
  printf '%s' "$response" | jq -r '.access_token // empty'
}
SIM_TOKEN="$(application_token 'opengateway_sim_swap')"
QOD_TOKEN="$(application_token 'network.qod.request')"
[[ -n "$SIM_TOKEN" && -n "$QOD_TOKEN" ]] || fail 'Could not obtain scoped application tokens.'
pass 'Scoped SIM Swap and QoD application tokens obtained.'

resolve_url() {
  local method="$1" token="$2" partner="$3" body="$4" expected="$5"; shift 5
  local candidate status
  for candidate in "$@"; do
    if [[ "$method" == 'POST' ]]; then
      status="$(curl -ksS --connect-timeout 3 --max-time 20 -o "$WORK_DIR/resolve-body" -w '%{http_code}' -X POST \
        -H "Authorization: Bearer ${token}" -H "X-Partner-Id: ${partner}" \
        -H 'X-Correlation-ID: resolve-url' -H 'Content-Type: application/json' \
        -d "$body" "$candidate")"
    else
      status="$(curl -ksS --connect-timeout 3 --max-time 20 -o "$WORK_DIR/resolve-body" -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" -H "X-Partner-Id: ${partner}" \
        -H 'X-Correlation-ID: resolve-url' "$candidate")"
    fi
    if [[ "$status" == "$expected" || "$status" == '429' ]]; then
      printf '%s' "$candidate"
      return 0
    fi
    [[ "$status" == '404' ]] || fail "Gateway URL probe returned HTTP ${status} for ${candidate}: $(cat "$WORK_DIR/resolve-body")"
  done
  fail 'No valid Gateway URL candidate was found.'
}

SIM_URL="$(resolve_url GET "$SIM_TOKEN" digital-bank-demo '' 200 \
  "${GATEWAY_URL}/open-gateway/sim-swap/v1/1.0.0/api/v1/open-gateway/sim-swap/%2B525512340001/risk?lookbackHours=168" \
  "${GATEWAY_URL}/open-gateway/sim-swap/v1/api/v1/open-gateway/sim-swap/%2B525512340001/risk?lookbackHours=168")"
QOD_BODY='{"device":{"phoneNumber":"+525512340001"},"area":{"type":"CELL_ID","value":"MX-MEX-CELL-001"},"profile":"QOD_GOLD","durationSeconds":120,"maxLatencyMs":20,"minThroughputMbps":100}'
QOD_URL="$(resolve_url POST "$QOD_TOKEN" enterprise-qod-demo "$QOD_BODY" 201 \
  "${GATEWAY_URL}/network-slice/v1/1.0.0/api/v1/network/qod/sessions" \
  "${GATEWAY_URL}/network-slice/v1/api/v1/network/qod/sessions")"
pass 'Gateway invocation URLs resolved.'

header_value() {
  local file="$1" name="$2"
  awk -v name="$name" 'BEGIN{IGNORECASE=1} $0 ~ "^" name ":" {sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0} END{print value}' "$file"
}

assert_429() {
  local label="$1" header_file="$2" body_file="$3" expected_policy="$4" expected_partner="$5" expected_context="$6" expected_retry="$7" expected_limit="$8" expected_corr="$9"
  local retry limit remaining reset policy corr content_type
  retry="$(header_value "$header_file" 'Retry-After')"
  limit="$(header_value "$header_file" 'RateLimit-Limit')"
  remaining="$(header_value "$header_file" 'RateLimit-Remaining')"
  reset="$(header_value "$header_file" 'RateLimit-Reset')"
  policy="$(header_value "$header_file" 'RateLimit-Policy')"
  corr="$(header_value "$header_file" 'X-Correlation-ID')"
  content_type="$(header_value "$header_file" 'Content-Type')"
  [[ "$retry" == "$expected_retry" ]] || fail "${label}: Retry-After=${retry}, expected ${expected_retry}."
  [[ "$limit" == "$expected_limit" ]] || fail "${label}: RateLimit-Limit=${limit}, expected ${expected_limit}."
  [[ "$remaining" == '0' ]] || fail "${label}: RateLimit-Remaining=${remaining}, expected 0."
  [[ -n "$reset" ]] || fail "${label}: RateLimit-Reset header missing."
  [[ "$policy" == "$expected_policy" ]] || fail "${label}: RateLimit-Policy=${policy}, expected ${expected_policy}."
  [[ "$corr" == "$expected_corr" ]] || fail "${label}: correlation header was not preserved."
  [[ "$content_type" == application/problem+json* ]] || fail "${label}: content type is not application/problem+json."
  jq -e --arg policy "$expected_policy" --arg partner "$expected_partner" --arg context "$expected_context" --arg corr "$expected_corr" \
    '.status == 429 and .code == "900806" and .policyName == $policy and .partnerId == $partner and .apiContext == $context and .correlationId == $corr and (.applicationId | type == "string" and length > 0 and . != "null")' \
    "$body_file" >/dev/null || fail "${label}: normalized 429 body is missing policy/partner/API/application/correlation identity: $(cat "$body_file")"
}

trigger_policy() {
  local label="$1" method="$2" url="$3" token="$4" partner="$5" body="$6" threshold="$7" window="$8" policy="$9" context="${10}" retry="${11}" limit="${12}"
  local i status corr header_file body_file deadline

  printf '\n[runtime] Clearing previous %s window...\n' "$label" >&2
  sleep "$((window + 3))"
  printf '[runtime] Sending %s qualifying requests for %s...\n' "$threshold" "$label" >&2
  for i in $(seq 1 "$threshold"); do
    corr="verify-${label// /-}-fill-${i}-$(date +%s%N)"
    if [[ "$method" == 'POST' ]]; then
      status="$(curl -ksS --connect-timeout 3 --max-time 20 -o /dev/null -w '%{http_code}' -X POST \
        -H "Authorization: Bearer ${token}" -H "X-Partner-Id: ${partner}" \
        -H "X-Correlation-ID: ${corr}" -H 'Content-Type: application/json' \
        -d "$body" "$url")"
    else
      status="$(curl -ksS --connect-timeout 3 --max-time 20 -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" -H "X-Partner-Id: ${partner}" \
        -H "X-Correlation-ID: ${corr}" "$url")"
    fi
    [[ "$status" == '200' || "$status" == '201' || "$status" == '429' ]] \
      || fail "${label}: qualifying request ${i} returned HTTP ${status}."
  done

  deadline=$((SECONDS + window + 20))
  while (( SECONDS < deadline )); do
    corr="verify-${label// /-}-throttled-$(date +%s%N)"
    header_file="$WORK_DIR/${label// /-}.headers"
    body_file="$WORK_DIR/${label// /-}.body"
    : > "$header_file"
    : > "$body_file"
    if [[ "$method" == 'POST' ]]; then
      status="$(curl -ksS --connect-timeout 3 --max-time 20 -D "$header_file" -o "$body_file" -w '%{http_code}' -X POST \
        -H "Authorization: Bearer ${token}" -H "X-Partner-Id: ${partner}" \
        -H "X-Correlation-ID: ${corr}" -H 'Content-Type: application/json' \
        -d "$body" "$url")"
    else
      status="$(curl -ksS --connect-timeout 3 --max-time 20 -D "$header_file" -o "$body_file" -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" -H "X-Partner-Id: ${partner}" \
        -H "X-Correlation-ID: ${corr}" "$url")"
    fi
    if [[ "$status" == '429' ]]; then
      assert_429 "$label" "$header_file" "$body_file" "$policy" "$partner" "$context" "$retry" "$limit" "$corr"
      printf '%s' "$corr"
      return 0
    fi
    [[ "$status" == '200' || "$status" == '201' ]] || fail "${label}: probe returned HTTP ${status}: $(cat "$body_file")"
    sleep 1
  done
  fail "${label}: no HTTP 429 was observed after the Siddhi threshold."
}

printf '\n=== Live SIM Swap runtime enforcement ===\n'
SIM_CORRELATION="$(trigger_policy 'SIM-Swap' GET "$SIM_URL" "$SIM_TOKEN" digital-bank-demo '' 6 15 \
  TelcoSiddhiSimSwapFraudFairUsePolicy /open-gateway/sim-swap/v1 15 6)"
pass 'SIM Swap fair-use policy returned normalized HTTP 429 and rate-limit headers.'

printf '\n=== Live QoD runtime enforcement ===\n'
QOD_CORRELATION="$(trigger_policy 'QoD' POST "$QOD_URL" "$QOD_TOKEN" enterprise-qod-demo "$QOD_BODY" 9 5 \
  TelcoSiddhiQoDAssuranceBurstPolicy /network-slice/v1 5 9)"
pass 'QoD assurance policy returned normalized HTTP 429 and rate-limit headers.'

verify_alert() {
  local label="$1" correlation="$2" policy="$3" partner="$4" context="$5" deadline events
  deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    events="$(json_curl "${BACKEND_URL}/api/v1/kafka/topics/telco.runtime.policy.alerts/events")"
    if printf '%s' "$events" | jq -e --arg corr "$correlation" --arg policy "$policy" --arg partner "$partner" --arg context "$context" '
      any(.. | objects;
          .correlationId? == $corr and
          .policyName? == $policy and
          .partnerId? == $partner and
          .apiContext? == $context and
          (.applicationId? | type == "string" and length > 0 and . != "null"))
    ' >/dev/null; then
      pass "${label} alert is present in Kafka with partner, API, application and correlation identity."
      return 0
    fi
    sleep 1
  done
  fail "${label}: matching Kafka alert was not observed within 30 seconds."
}

printf '\n=== Kafka alert evidence ===\n'
verify_alert 'SIM Swap' "$SIM_CORRELATION" TelcoSiddhiSimSwapFraudFairUsePolicy digital-bank-demo /open-gateway/sim-swap/v1
verify_alert 'QoD' "$QOD_CORRELATION" TelcoSiddhiQoDAssuranceBurstPolicy enterprise-qod-demo /network-slice/v1

printf '\n============================================================\n'
printf 'SIDDHI RUNTIME ENFORCEMENT VERIFICATION PASSED\n'
printf 'SIM correlation: %s\n' "$SIM_CORRELATION"
printf 'QoD correlation: %s\n' "$QOD_CORRELATION"
printf 'Kafka topic: telco.runtime.policy.alerts\n'
printf '============================================================\n'
