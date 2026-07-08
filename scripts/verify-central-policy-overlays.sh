#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
GATEWAY_URL="${WSO2_GATEWAY_PUBLIC_URL:-https://127.0.0.1:8243}"
MI_URL="${WSO2_MI_PUBLIC_URL:-http://127.0.0.1:8290}"
OPA_URL="${OPA_PUBLIC_URL:-http://127.0.0.1:8181}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"
VERIFY_FAILOVER="${VERIFY_FAILOVER:-true}"

fail() {
  echo "[central-policy-verify] FAIL: $*" >&2
  exit 1
}

pass() {
  echo "[central-policy-verify] PASS: $*"
}

for command in curl jq python3 docker; do
  command -v "$command" >/dev/null 2>&1 || fail "Missing command: $command"
done

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose)
else
  fail "Docker Compose was not found."
fi

COMPOSE_FILES=(docker-compose.yml)
for file in \
  docker-compose.kafka.yml \
  docker-compose.opa.yml \
  docker-compose.mi.yml \
  docker-compose.commercial.yml \
  docker-compose.mi.soap.yml \
  docker-compose.observability.yml \
  docker-compose.runtime-persistence.yml \
  docker-compose.central-policy.yml
do
  [[ -f "$file" ]] && COMPOSE_FILES+=("$file")
done

COMPOSE=("${DC[@]}")
for file in "${COMPOSE_FILES[@]}"; do
  COMPOSE+=(-f "$file")
done

required_files=(
  artifacts/opa/central-policy-overlays.rego
  artifacts/apim-admin/central-policy-catalog.json
  contracts/openapi/central-policy-decision.openapi.yaml
  services/wso2-mi/synapse-configs/default/api/CentralPolicyDecisionAPI.xml
  services/wso2-mi/synapse-configs/default/endpoints/CentralPolicyOpaFailoverEndpoint.xml
  services/wso2-mi/synapse-configs/default/sequences/CentralPolicyFaultSequence.xml
  services/apim-bootstrapper/src/central-policy-preflight.js
  services/apim-bootstrapper/src/central-policy-setup.js
  scripts/register-central-policy-service-catalog.sh
  artifacts/postman/telco-central-policy-overlays.postman_collection.json
  docker-compose.central-policy.yml
)
for file in "${required_files[@]}"; do
  [[ -s "$file" ]] || fail "Missing or empty expected file: $file"
done
pass "All expected implementation files exist."

python3 -m json.tool artifacts/apim-admin/central-policy-catalog.json >/dev/null
python3 -m json.tool artifacts/apim-admin/api-product-bundles.json >/dev/null
python3 -m json.tool artifacts/postman/telco-central-policy-overlays.postman_collection.json >/dev/null
pass "JSON artifacts are valid."

grep -q "CENTRAL_POLICY_FAIL_ON_DENY: \"true\"" docker-compose.central-policy.yml ||
  fail "Selected production policies are not configured as blocking."
grep -q "OPA_FAIL_ON_DENY: \"false\"" docker-compose.central-policy.yml ||
  fail "The existing broad OPA overlay is no longer advisory."
grep -q "central-policy-preflight.js" services/apim-bootstrapper/package.json ||
  fail "Blocking central-policy preflight is absent from npm start."
grep -q "central-policy-setup.js" services/apim-bootstrapper/package.json ||
  fail "Central policy enrichment bootstrap is absent from npm start."
python3 - <<'PY'
import json
from pathlib import Path
package = json.loads(Path("services/apim-bootstrapper/package.json").read_text())
start = package.get("scripts", {}).get("start", "")
preflight = start.find("node src/central-policy-preflight.js")
bootstrap = start.find("node src/bootstrap.js")
if preflight < 0 or bootstrap < 0 or preflight > bootstrap:
    raise SystemExit(
        "Blocking central-policy preflight must execute before APIM publication."
    )
PY
grep -q "CentralPolicyDecisionAPI" services/apim-bootstrapper/src/bootstrap.js ||
  fail "Central policy API is absent from APICTL bootstrap."
grep -q "central-policy-governance" services/apim-bootstrapper/src/api-product-bundles-setup.js ||
  fail "Central policy bundle is not configured as a native API Product."
pass "Bootstrap and mixed blocking/advisory mode are installed."

"${COMPOSE[@]}" config -q
pass "Merged Docker Compose topology is valid."

wait_http() {
  local url="$1"
  local label="$2"
  local insecure="${3:-false}"
  local attempts="${4:-120}"
  local args=(-fsS --max-time 5)
  [[ "$insecure" == true ]] && args=(-kfsS --max-time 5)
  for _ in $(seq 1 "$attempts"); do
    if curl "${args[@]}" "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  fail "${label} did not become reachable: ${url}"
}

wait_http "${OPA_URL}/health" "OPA" false 30 || true
wait_http "${MI_URL}/internal/central-policy/v1/health" "MI central policy API" false 120
wait_http "${APIM_URL}/services/Version" "WSO2 API Manager" true 180
pass "OPA/MI/APIM runtime endpoints are reachable."

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/central-policy-verify.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

descriptor() {
  local api_name="$1"
  jq -c --arg name "$api_name" \
    '.descriptors[] | select(.apiName == $name)' \
    artifacts/apim-admin/central-policy-catalog.json
}

opa_decision() {
  local payload="$1"
  curl -fsS \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --argjson input "$payload" '{input:$input}')" \
    "${OPA_URL}/v1/data/telco/central_policy/decision"
}

MX="$(descriptor OpenGatewaySimSwapRiskAPI)"
BR="$(descriptor SecureMobileTransactionsCommercialAPI)"
GROUP="$(descriptor CentralPolicyDecisionAPI)"

MX_RESULT="$(opa_decision "$MX")"
jq -e '.result.allow == true and .result.country == "MX" and
       (.result.approvalPath.steps | index("Mexico Privacy and Legal")) != null' \
  <<<"$MX_RESULT" >/dev/null ||
  fail "Compliant Mexico descriptor was not allowed through the Mexico path."
pass "Compliant Mexico HIGH-risk descriptor uses the Mexico approval path."

BR_RESULT="$(opa_decision "$BR")"
jq -e '.result.allow == true and .result.country == "BR" and
       (.result.approvalPath.steps | index("Brazil Data Protection Officer")) != null' \
  <<<"$BR_RESULT" >/dev/null ||
  fail "Compliant Brazil descriptor was not allowed through the Brazil path."
pass "Compliant Brazil CRITICAL descriptor uses the Brazil DPO path."

GROUP_RESULT="$(opa_decision "$GROUP")"
jq -e '.result.allow == true and .result.country == "GROUP"' \
  <<<"$GROUP_RESULT" >/dev/null ||
  fail "Compliant group descriptor was not allowed."
pass "Mandatory group-wide descriptor is allowed."

MX_DENIED="$(jq 'del(.localOwner.email)' <<<"$MX")"
MX_DENIED_RESULT="$(opa_decision "$MX_DENIED")"
jq -e '.result.allow == false and
       any(.result.blocking[]; .code == "LOCAL_OWNER_EMAIL_REQUIRED")' \
  <<<"$MX_DENIED_RESULT" >/dev/null ||
  fail "Missing Mexico local owner email did not produce a blocking denial."
pass "Mandatory local-owner rule blocks production."

BR_DENIED="$(jq '.dataResidency = "MX"' <<<"$BR")"
BR_DENIED_RESULT="$(opa_decision "$BR_DENIED")"
jq -e '.result.allow == false and
       any(.result.blocking[]; .code == "DATA_RESIDENCY_MISMATCH")' \
  <<<"$BR_DENIED_RESULT" >/dev/null ||
  fail "Brazil residency mismatch did not produce a blocking denial."
pass "Brazil data-residency mismatch blocks production."

ADVISORY_INPUT="$(jq '.evidence.sdkInstructions = false' <<<"$MX")"
ADVISORY_RESULT="$(opa_decision "$ADVISORY_INPUT")"
jq -e '.result.allow == true and .result.partialResponse == true and
       any(.result.advisories[]; .code == "SDK_INSTRUCTIONS_RECOMMENDED")' \
  <<<"$ADVISORY_RESULT" >/dev/null ||
  fail "Advisory documentation rule incorrectly blocked the decision."
pass "Advisory findings remain non-blocking and produce a partial response."

CORRELATION="central-policy-mi-$(date +%s)"
MI_HEADERS="$WORK_DIR/mi.headers"
MI_BODY="$WORK_DIR/mi.json"
curl -fsS \
  -D "$MI_HEADERS" \
  -o "$MI_BODY" \
  -H 'Content-Type: application/json' \
  -H "X-Correlation-ID: ${CORRELATION}" \
  -d "$MX" \
  "${MI_URL}/internal/central-policy/v1/decisions"
jq -e --arg c "$CORRELATION" \
  '.allow == true and .correlationId == $c and .country == "MX"' \
  "$MI_BODY" >/dev/null ||
  fail "MI did not return the allowed Mexico decision with correlation."
grep -Eiq "^X-Correlation-ID: ${CORRELATION}\r?$" "$MI_HEADERS" ||
  fail "MI did not preserve X-Correlation-ID in the transport response."
pass "MI mediation preserves correlation and normalizes the OPA envelope."

if [[ "$VERIFY_FAILOVER" == true ]]; then
  echo "[central-policy-verify] Exercising OPA primary-to-DR failover."
  "${COMPOSE[@]}" stop opa >/dev/null
  trap '"${COMPOSE[@]}" start opa >/dev/null 2>&1 || true; rm -rf "$WORK_DIR"' EXIT
  sleep 2
  FAILOVER_RESULT="$(
    curl -fsS \
      -H 'Content-Type: application/json' \
      -H 'X-Correlation-ID: central-policy-failover-001' \
      -d "$BR" \
      "${MI_URL}/internal/central-policy/v1/decisions"
  )"
  jq -e '.allow == true and .country == "BR"' <<<"$FAILOVER_RESULT" >/dev/null ||
    fail "MI did not fail over to opa-dr."
  "${COMPOSE[@]}" start opa >/dev/null
  wait_http "${OPA_URL}/health" "restarted OPA" false 30 || true
  trap 'rm -rf "$WORK_DIR"' EXIT
  pass "MI failed over from primary OPA to opa-dr."
fi

cat > "$WORK_DIR/dcr.json" <<JSON
{
  "callbackUrl": "http://localhost:8080/callback",
  "clientName": "central-policy-verifier-$(date +%s)-$$",
  "owner": "${APIM_USER}",
  "grantType": "password refresh_token client_credentials",
  "saasApp": true
}
JSON

DCR="$(
  curl -ksS \
    -u "${APIM_USER}:${APIM_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d @"$WORK_DIR/dcr.json" \
    "${APIM_URL}/client-registration/v0.17/register"
)"
CLIENT_ID="$(jq -r '.clientId // empty' <<<"$DCR")"
CLIENT_SECRET="$(jq -r '.clientSecret // empty' <<<"$DCR")"
[[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]] ||
  fail "APIM DCR did not return credentials."

TOKEN="$(
  curl -ksS \
    -u "${CLIENT_ID}:${CLIENT_SECRET}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${APIM_USER}" \
    --data-urlencode "password=${APIM_PASSWORD}" \
    --data-urlencode \
      'scope=apim:api_view apim:api_manage apim:api_publish apim:api_metadata_view service_catalog:service_view apim:app_manage apim:sub_manage apim:subscribe apim:api_key apim:api_generate_key' \
    "${APIM_URL}/oauth2/token"
)"
ADMIN_TOKEN="$(jq -r '.access_token // empty' <<<"$TOKEN")"
[[ -n "$ADMIN_TOKEN" ]] || fail "APIM admin token was not returned."

APIS="$(
  curl -ksS \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${APIM_URL}/api/am/publisher/v4/apis?limit=1000"
)"

for name in \
  CentralPolicyDecisionAPI \
  OpenGatewaySimSwapRiskAPI \
  SecureMobileTransactionsCommercialAPI
do
  id="$(
    jq -r --arg name "$name" \
      'first(.list[]? | select(.name == $name and (.version // "1.0.0") == "1.0.0") | .id) // empty' \
      <<<"$APIS"
  )"
  [[ -n "$id" ]] || fail "Expected Publisher API is absent: ${name}:1.0.0"
  detail="$(
    curl -ksS \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      "${APIM_URL}/api/am/publisher/v4/apis/${id}"
  )"
  jq -e '.lifeCycleStatus == "PUBLISHED"' <<<"$detail" >/dev/null ||
    fail "${name} is not PUBLISHED."
  jq -e \
    'any(.additionalProperties[]?; .name == "CentralPolicyEnforcement" and .value == "BLOCKING_PRODUCTION_AND_ADVISORY_REPORT_ONLY")' \
    <<<"$detail" >/dev/null ||
    fail "${name} lacks central-policy metadata."

  case "$name" in
    CentralPolicyDecisionAPI) expected_policy="TelcoPartnerPremium" ;;
    OpenGatewaySimSwapRiskAPI) expected_policy="TelcoOpenGatewayTrustPremium" ;;
    SecureMobileTransactionsCommercialAPI) expected_policy="SecureMobileEnterprise" ;;
    *) fail "No expected policy mapping for ${name}." ;;
  esac
  jq -e --arg policy "$expected_policy" \
    '(.policies // []) | index($policy) != null' \
    <<<"$detail" >/dev/null ||
    fail "${name} is missing subscription policy ${expected_policy}."

  documents="$(
    curl -ksS \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      "${APIM_URL}/api/am/publisher/v4/apis/${id}/documents?limit=100"
  )"
  for document in \
    "10 - Central Policy and Country Overlay" \
    "11 - Consent Privacy and Data Residency" \
    "12 - Errors SLA Sandbox Postman and SDK"
  do
    jq -e --arg document "$document" \
      'any(.list[]?; .name == $document)' \
      <<<"$documents" >/dev/null ||
      fail "${name} is missing document: ${document}"
  done

  deployments="$(
    curl -ksS \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      "${APIM_URL}/api/am/publisher/v4/apis/${id}/deployments"
  )"
  jq -e '
    if type == "array" then
      length > 0
    elif type == "object" then
      ((.list // .data // .deployments // []) | length) > 0
    else
      false
    end
  ' <<<"$deployments" >/dev/null ||
    fail "${name} has no deployed revision."
done
pass "Expected APIs are published, deployed, documented and centrally labelled."

PRODUCTS="$(
  curl -ksS \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${APIM_URL}/api/am/publisher/v4/api-products?limit=1000"
)"
PRODUCT_ID="$(
  jq -r \
    'first(.list[]? | select(.name == "CentralPolicyGovernanceProduct" and (.version // "1.0.0") == "1.0.0") | .id) // empty' \
    <<<"$PRODUCTS"
)"
[[ -n "$PRODUCT_ID" ]] ||
  fail "CentralPolicyGovernanceProduct:1.0.0 is absent."

PRODUCT="$(
  curl -ksS \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${APIM_URL}/api/am/publisher/v4/api-products/${PRODUCT_ID}"
)"
jq -e '
  ((.state // .lifeCycleStatus // .status) | ascii_upcase) == "PUBLISHED" and
  any(.apis[]?; .name == "CentralPolicyDecisionAPI") and
  ((.policies // []) | index("TelcoPartnerPremium") != null)
' <<<"$PRODUCT" >/dev/null ||
  fail "CentralPolicyGovernanceProduct is not PUBLISHED, lacks its member API or lacks TelcoPartnerPremium."

PRODUCT_DEPLOYMENTS="$(
  curl -ksS \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${APIM_URL}/api/am/publisher/v4/api-products/${PRODUCT_ID}/deployments"
)"
jq -e '
  if type == "array" then
    length > 0
  elif type == "object" then
    ((.list // .data // .deployments // []) | length) > 0
  else
    false
  end
' <<<"$PRODUCT_DEPLOYMENTS" >/dev/null ||
  fail "CentralPolicyGovernanceProduct has no deployed revision."

PRODUCT_DOCS="$(
  curl -ksS \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${APIM_URL}/api/am/publisher/v4/api-products/${PRODUCT_ID}/documents?limit=100"
)"
jq -e '(.list | length) >= 3' <<<"$PRODUCT_DOCS" >/dev/null ||
  fail "CentralPolicyGovernanceProduct lacks expected documentation."
pass "Native API Product is published, contains the managed API and has documentation."

DEVPORTAL_APIS="$(
  curl -ksS \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${APIM_URL}/api/am/devportal/v3/apis?limit=1000"
)"
for name in \
  CentralPolicyDecisionAPI \
  OpenGatewaySimSwapRiskAPI \
  SecureMobileTransactionsCommercialAPI
do
  jq -e --arg name "$name" \
    'any((.list // .)[]?; .name == $name and ((.status // "PUBLISHED") | ascii_upcase) == "PUBLISHED")' \
    <<<"$DEVPORTAL_APIS" >/dev/null ||
    fail "${name} is not visible in the Developer Portal API listing."
done

DEVPORTAL_PRODUCT_FILE="$WORK_DIR/devportal-products.json"
DEVPORTAL_PRODUCT_STATUS="$(
  curl -ksS \
    -o "$DEVPORTAL_PRODUCT_FILE" \
    -w '%{http_code}' \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${APIM_URL}/api/am/devportal/v3/api-products?limit=1000"
)"
if [[ "$DEVPORTAL_PRODUCT_STATUS" == 200 ]]; then
  DEVPORTAL_PRODUCTS="$(cat "$DEVPORTAL_PRODUCT_FILE")"
else
  # Some 4.x distributions expose products in the unified /apis marketplace
  # result instead of a separate collection resource.
  DEVPORTAL_PRODUCTS="$DEVPORTAL_APIS"
fi
jq -e \
  'any((.list // .)[]?; .name == "CentralPolicyGovernanceProduct" and
       ((.status // "PUBLISHED") | ascii_upcase) == "PUBLISHED")' \
  <<<"$DEVPORTAL_PRODUCTS" >/dev/null ||
  fail "CentralPolicyGovernanceProduct is not visible in the Developer Portal."
pass "Governed APIs and the native API Product are visible in the Developer Portal."

CATALOG="$(
  curl -ksS \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${APIM_URL}/api/am/service-catalog/v1/services?limit=100"
)"
jq -e \
  'any(.list[]?; .name == "CentralPolicyDecisionAPI" and .version == "1.0.0")' \
  <<<"$CATALOG" >/dev/null ||
  fail "CentralPolicyDecisionAPI is absent from APIM Service Catalog."
pass "MI-managed service is registered in APIM Service Catalog."

UNAUTH_STATUS="$(
  curl -ksS -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -d "$GROUP" \
    "${GATEWAY_URL}/central-policy-decision/v1/1.0.0/decisions"
)"
case "$UNAUTH_STATUS" in
  401|403) ;;
  *) fail "Gateway did not enforce OAuth; expected 401/403, got ${UNAUTH_STATUS}." ;;
esac
pass "APIM gateway deployment enforces OAuth."

RUNTIME_STATE="$(
  "${COMPOSE[@]}" run --rm --no-deps \
    --entrypoint cat apim-bootstrapper /workspace/state/runtime.json 2>/dev/null
)" || fail "Could not read APIM bootstrap runtime state."

CONSUMER_KEY="$(jq -r '.application.consumerKey // empty' <<<"$RUNTIME_STATE")"
CONSUMER_SECRET="$(jq -r '.application.consumerSecret // empty' <<<"$RUNTIME_STATE")"
[[ -n "$CONSUMER_KEY" && -n "$CONSUMER_SECRET" ]] ||
  fail "Regional Portal production credentials are absent from runtime state."

APP_TOKEN_RESPONSE="$(
  curl -ksS \
    -u "${CONSUMER_KEY}:${CONSUMER_SECRET}" \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode 'scope=central-policy:evaluate central-policy:read' \
    "${APIM_URL}/oauth2/token"
)"
APP_TOKEN="$(jq -r '.access_token // empty' <<<"$APP_TOKEN_RESPONSE")"
if [[ -z "$APP_TOKEN" ]]; then
  APP_TOKEN_RESPONSE="$(
    curl -ksS \
      -u "${CONSUMER_KEY}:${CONSUMER_SECRET}" \
      --data-urlencode 'grant_type=client_credentials' \
      "${APIM_URL}/oauth2/token"
  )"
  APP_TOKEN="$(jq -r '.access_token // empty' <<<"$APP_TOKEN_RESPONSE")"
fi
[[ -n "$APP_TOKEN" ]] || fail "Could not obtain a Regional Portal application token."

GATEWAY_CORRELATION="central-policy-gateway-$(date +%s)"
GATEWAY_HEADERS="$WORK_DIR/gateway.headers"
GATEWAY_BODY="$WORK_DIR/gateway.json"
curl -ksS \
  -D "$GATEWAY_HEADERS" \
  -o "$GATEWAY_BODY" \
  -H "Authorization: Bearer ${APP_TOKEN}" \
  -H 'Content-Type: application/json' \
  -H "X-Correlation-ID: ${GATEWAY_CORRELATION}" \
  -d "$MX" \
  "${GATEWAY_URL}/central-policy-decision/v1/1.0.0/decisions"
jq -e --arg c "$GATEWAY_CORRELATION" \
  '.allow == true and .country == "MX" and .correlationId == $c' \
  "$GATEWAY_BODY" >/dev/null ||
  fail "Authenticated APIM gateway call did not return the expected decision."
pass "Authenticated APIM → MI → OPA runtime behavior succeeded."

MI_LOGS="$("${COMPOSE[@]}" logs --no-color wso2-mi 2>&1)"
grep -q "central-policy-evaluation-start" <<<"$MI_LOGS" ||
  fail "MI observability logs lack central-policy-evaluation-start."
grep -q "central-policy-evaluation-complete" <<<"$MI_LOGS" ||
  fail "MI observability logs lack central-policy-evaluation-complete."
grep -q "${GATEWAY_CORRELATION}" <<<"$MI_LOGS" ||
  fail "MI observability logs do not contain the gateway correlation identifier."
pass "Central-policy decision and correlation are visible in the existing MI log pipeline."

PREFLIGHT_STATE="$(
  "${COMPOSE[@]}" run --rm --no-deps \
    --entrypoint cat apim-bootstrapper /workspace/state/central-policy-preflight.json 2>/dev/null
)" || fail "Could not read central-policy preflight state."
jq -e '
  .status == "READY" and
  .failOnDeny == true and
  (.decisions | length) == 3 and
  all(.decisions[]; .allow == true and .blockingCount == 0)
' <<<"$PREFLIGHT_STATE" >/dev/null ||
  fail "Blocking central-policy preflight state is incomplete or denied."
pass "Blocking preflight completed before APIM publication."

STATE="$(
  "${COMPOSE[@]}" run --rm --no-deps \
    --entrypoint cat apim-bootstrapper /workspace/state/central-policy.json 2>/dev/null
)" || fail "Could not read central-policy bootstrap state."
jq -e '
  .status == "READY" and
  (.apis | length) == 3 and
  (.products | length) == 1 and
  .serviceCatalog.name == "CentralPolicyDecisionAPI" and
  all(.decisions[]; .allow == true)
' <<<"$STATE" >/dev/null ||
  fail "Central-policy bootstrap state is incomplete or denied."
pass "Central-policy bootstrap state is complete."

echo
echo "[central-policy-verify] SUCCESS"
echo "[central-policy-verify] 3 governed APIs"
echo "[central-policy-verify] 1 published native API Product"
echo "[central-policy-verify] 3 APIM documents per governed API"
echo "[central-policy-verify] 1 MI Service Catalog entry"
echo "[central-policy-verify] blocking GROUP/MX/BR production gates"
echo "[central-policy-verify] non-blocking advisory partial responses"
echo "[central-policy-verify] correlation, observability, OAuth, Developer Portal visibility, deployment and OPA failover verified"
