#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
GATEWAY_URL="${WSO2_GATEWAY_URL:-https://127.0.0.1:8243}"
MI_URL="${WSO2_MI_PUBLIC_URL:-http://127.0.0.1:8290}"
STORE_URL="${COMMERCIAL_STORE_URL:-http://127.0.0.1:18086}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASS="${APIM_PASSWORD:-admin}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/commercial-verify.XXXXXX")"
VERIFY_APP_ID=""
trap 'if [[ -n "$VERIFY_APP_ID" && -n "${DEVPORTAL_TOKEN:-}" ]]; then curl -ksS -X DELETE -H "Authorization: Bearer ${DEVPORTAL_TOKEN}" "${APIM_URL}/api/am/devportal/v3/applications/${VERIFY_APP_ID}" >/dev/null 2>&1 || true; fi; rm -rf "$WORK_DIR"' EXIT

ok() { printf '[OK] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "$1 is required"; }
for command in curl jq python3 docker; do require "$command"; done

if docker compose version >/dev/null 2>&1; then DC=(docker compose); elif docker-compose version >/dev/null 2>&1; then DC=(docker-compose); else fail 'Docker Compose is required'; fi
COMPOSE_FILES=(docker-compose.yml)
for file in docker-compose.kafka.yml docker-compose.opa.yml docker-compose.mi.yml docker-compose.commercial.yml docker-compose.mi.soap.yml docker-compose.observability.yml docker-compose.runtime-persistence.yml; do
  [[ -f "$file" ]] && COMPOSE_FILES+=("$file")
done
COMPOSE=("${DC[@]}")
for file in "${COMPOSE_FILES[@]}"; do COMPOSE+=(-f "$file"); done

for file in \
  docker-compose.commercial.yml \
  services/commercial-meter-store/src/server.js \
  services/wso2-mi/synapse-configs/default/api/SecureMobileTransactionsCommercialAPI.xml \
  services/wso2-mi/synapse-configs/default/endpoints/CommercialMeterStoreFailoverEndpoint.xml \
  services/wso2-mi/synapse-configs/default/sequences/CommercialExecuteTransactionSequence.xml \
  contracts/openapi/secure-mobile-transactions-commercial.openapi.json \
  artifacts/developer-experience/secure-mobile-transactions/Secure-Mobile-Transactions.postman_collection.json; do
  [[ -s "$file" ]] || fail "Missing required artifact: $file"
done
ok 'Static commercial artifacts exist'

"${COMPOSE[@]}" config >/dev/null
ok 'Merged Docker Compose topology is valid'

for service in commercial-meter-store-primary commercial-meter-store-secondary wso2-mi wso2-apim; do
  id="$("${COMPOSE[@]}" ps -q "$service" 2>/dev/null || true)"
  [[ -n "$id" ]] || fail "Service is not running: $service"
done
ok 'APIM, MI and both meter-store replicas are running'

wait_url() {
  local url="$1" label="$2" insecure="${3:-false}"
  local args=(-fsS --max-time 5)
  [[ "$insecure" == true ]] && args=(-kfsS --max-time 5)
  for _ in $(seq 1 90); do
    if curl "${args[@]}" "$url" >/dev/null 2>&1; then ok "$label is ready"; return; fi
    sleep 2
  done
  fail "$label did not become ready: $url"
}
wait_url "$STORE_URL/health" 'Primary commercial meter store'
wait_url 'http://127.0.0.1:18087/health' 'Secondary commercial meter store'
wait_url "$MI_URL/secure-mobile-transactions/v1/health" 'MI commercial API'
wait_url "$APIM_URL/services/Version" 'APIM management plane' true

CLIENT_NAME="commercial-verifier-$(date +%s)-$$"
DCR="$(curl -ksS -u "$APIM_USER:$APIM_PASS" -X POST -H 'Content-Type: application/json' \
  -d "{\"callbackUrl\":\"www.google.lk\",\"clientName\":\"${CLIENT_NAME}\",\"owner\":\"${APIM_USER}\",\"grantType\":\"password refresh_token client_credentials\",\"saasApp\":true}" \
  "$APIM_URL/client-registration/v0.17/register")"
CLIENT_ID="$(jq -r '.clientId // empty' <<<"$DCR")"
CLIENT_SECRET="$(jq -r '.clientSecret // empty' <<<"$DCR")"
[[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]] || fail "DCR failed: $DCR"
password_token() {
  local scope="$1"
  curl -ksS -u "$CLIENT_ID:$CLIENT_SECRET" \
    --data-urlencode grant_type=password \
    --data-urlencode username="$APIM_USER" \
    --data-urlencode password="$APIM_PASS" \
    --data-urlencode "scope=$scope" \
    "$APIM_URL/oauth2/token"
}
ADMIN_TOKEN_JSON="$(password_token 'apim:admin_tier_view apim:admin_tier_manage')"
PUBLISHER_TOKEN_JSON="$(password_token 'apim:api_view apim:api_metadata_view apim:api_product_view apim:document_manage apim:document_create apim:document_update')"
CATALOG_TOKEN_JSON="$(password_token 'service_catalog:service_view service_catalog:service_write')"
DEVPORTAL_TOKEN_JSON="$(password_token 'apim:subscribe')"
ADMIN_TOKEN="$(jq -r '.access_token // empty' <<<"$ADMIN_TOKEN_JSON")"
PUBLISHER_TOKEN="$(jq -r '.access_token // empty' <<<"$PUBLISHER_TOKEN_JSON")"
CATALOG_TOKEN="$(jq -r '.access_token // empty' <<<"$CATALOG_TOKEN_JSON")"
DEVPORTAL_TOKEN="$(jq -r '.access_token // empty' <<<"$DEVPORTAL_TOKEN_JSON")"
[[ -n "$ADMIN_TOKEN" ]] || fail "Admin OAuth token failed: $ADMIN_TOKEN_JSON"
[[ -n "$PUBLISHER_TOKEN" ]] || fail "Publisher OAuth token failed: $PUBLISHER_TOKEN_JSON"
[[ -n "$CATALOG_TOKEN" ]] || fail "Service Catalog OAuth token failed: $CATALOG_TOKEN_JSON"
[[ -n "$DEVPORTAL_TOKEN" ]] || fail "DevPortal OAuth token failed: $DEVPORTAL_TOKEN_JSON"
ADMIN_AUTH=(-H "Authorization: Bearer $ADMIN_TOKEN" -H 'Accept: application/json')
PUBLISHER_AUTH=(-H "Authorization: Bearer $PUBLISHER_TOKEN" -H 'Accept: application/json')
CATALOG_AUTH=(-H "Authorization: Bearer $CATALOG_TOKEN" -H 'Accept: application/json')
DEVPORTAL_AUTH=(-H "Authorization: Bearer $DEVPORTAL_TOKEN" -H 'Accept: application/json')
ok 'Obtained dedicated APIM Admin, Publisher, DevPortal and Service Catalog tokens'

POLICIES="$(curl -ksS "${ADMIN_AUTH[@]}" "$APIM_URL/api/am/admin/v4/throttling/policies/subscription?limit=100&offset=0")"
for policy in SecureMobileSandbox SecureMobileBusiness SecureMobileEnterprise; do
  jq -e --arg name "$policy" 'any(.list[]?; .policyName == $name)' <<<"$POLICIES" >/dev/null || fail "Missing subscription policy: $policy"
done
jq -e 'any(.list[]?; .policyName == "SecureMobileBusiness" and .billingPlan == "COMMERCIAL" and .stopOnQuotaReach == false)' <<<"$POLICIES" >/dev/null || fail 'Business policy does not carry expected commercial behavior'
ok 'All three native APIM subscription policies exist'

APIS="$(curl -ksS "${PUBLISHER_AUTH[@]}" --get --data-urlencode 'query=name:SecureMobileTransactionsCommercialAPI' --data-urlencode 'limit=100' "$APIM_URL/api/am/publisher/v4/apis")"
API_ID="$(jq -r 'first(.list[]? | select(.name == "SecureMobileTransactionsCommercialAPI" and .version == "1.0.0") | .id) // empty' <<<"$APIS")"
[[ -n "$API_ID" ]] || fail 'Managed API is absent'
API="$(curl -ksS "${PUBLISHER_AUTH[@]}" "$APIM_URL/api/am/publisher/v4/apis/$API_ID")"
jq -e '.lifeCycleStatus == "PUBLISHED"' <<<"$API" >/dev/null || fail 'Managed API is not PUBLISHED'
jq -e '[.operations[]? | (.verb + " " + .target)] | contains(["POST /number-verification", "POST /sim-swap", "POST /quality-on-demand", "GET /partners/{partnerId}/usage"])' <<<"$API" >/dev/null || fail 'Managed API operations are incomplete'
DEPLOYMENTS="$(curl -ksS "${PUBLISHER_AUTH[@]}" "$APIM_URL/api/am/publisher/v4/apis/$API_ID/deployments")"
jq -e '((if type == "array" then . else (.list // []) end) | length) > 0' <<<"$DEPLOYMENTS" >/dev/null || fail 'Managed API has no deployed revision'
ok 'Managed API is published and deployed with the expected operations'

PRODUCTS="$(curl -ksS "${PUBLISHER_AUTH[@]}" "$APIM_URL/api/am/publisher/v4/api-products?limit=1000&offset=0")"
PRODUCT_ID="$(jq -r '
  def product_items:
    if type == "array" then .
    elif (.list? | type) == "array" then .list
    elif (.data? | type) == "array" then .data
    else []
    end;

  first(
    product_items[]?
    | select(
        .name == "SecureMobileTransactionsProduct"
        and ((.version // "") | tostring) == "1.0.0"
      )
    | .id
  ) // empty
' <<<"$PRODUCTS")"
if [[ -z "$PRODUCT_ID" ]]; then
  printf '[DEBUG] API Products returned by APIM:\n' >&2

  jq -r '
    def product_items:
      if type == "array" then .
      elif (.list? | type) == "array" then .list
      elif (.data? | type) == "array" then .data
      else []
      end;

    product_items[]?
    | "- \(.name):\(.version) [\(.id)]"
  ' <<<"$PRODUCTS" >&2 || true

  fail 'SecureMobileTransactionsProduct is absent'
fi
PRODUCT="$(curl -ksS "${PUBLISHER_AUTH[@]}" "$APIM_URL/api/am/publisher/v4/api-products/$PRODUCT_ID")"
jq -e '(.state == "PUBLISHED") or (.lifeCycleStatus == "PUBLISHED")' <<<"$PRODUCT" >/dev/null || fail 'API Product is not PUBLISHED'
jq -e '(.policies // []) | contains(["SecureMobileSandbox", "SecureMobileBusiness", "SecureMobileEnterprise"])' <<<"$PRODUCT" >/dev/null || fail 'API Product does not expose all commercial policies'
PRODUCT_DEPLOYMENTS="$(curl -ksS "${PUBLISHER_AUTH[@]}" "$APIM_URL/api/am/publisher/v4/api-products/$PRODUCT_ID/deployments")"
jq -e '((if type == "array" then . else (.list // []) end) | length) > 0' <<<"$PRODUCT_DEPLOYMENTS" >/dev/null || fail 'API Product has no deployed revision'
ok 'API Product is published, deployed and subscribable with all plans'

PRODUCT_DOCS="$(curl -ksS "${PUBLISHER_AUTH[@]}" "$APIM_URL/api/am/publisher/v4/api-products/$PRODUCT_ID/documents?limit=100&offset=0")"

for name in \
  '01 - Product Overview and API Map' \
  '02 - Product Onboarding and First Call' \
  '03 - Consent and Compliance Matrix' \
  '04 - Commercial Plans Rate Limits and SLA' \
  '05 - Sandbox Postman and SDK Toolkit'
do
  jq -e --arg name "$name" '
    def items:
      if type == "array" then .
      elif (.list? | type) == "array" then .list
      elif (.data? | type) == "array" then .data
      else []
      end;

    any(items[]?; .name == $name)
  ' <<<"$PRODUCT_DOCS" >/dev/null ||
    fail "Missing API Product Developer Portal document: $name"
done

ok 'Developer Portal product documentation is complete' 

CATALOG="$(curl -ksS "${CATALOG_AUTH[@]}" "$APIM_URL/api/am/service-catalog/v1/services?limit=100")"
jq -e 'any(.list[]?; .name == "SecureMobileTransactionsCommercialAPI" and .version == "1.0.0" and .definitionType == "OAS3")' <<<"$CATALOG" >/dev/null || fail 'MI service is absent from the APIM Service Catalog'
ok 'MI-managed commercial service is registered in the Service Catalog'

APPS="$(curl -ksS "${DEVPORTAL_AUTH[@]}" "$APIM_URL/api/am/devportal/v3/applications?limit=100&offset=0")"
PARTNER_APP_ID="$(jq -r 'first(.list[]? | select(.name == "Secure Mobile Fintech BR") | (.applicationId // .id)) // empty' <<<"$APPS")"
[[ -n "$PARTNER_APP_ID" ]] || fail 'Partner application is absent'
SUBS="$(curl -ksS "${DEVPORTAL_AUTH[@]}" --get --data-urlencode "applicationId=$PARTNER_APP_ID" --data-urlencode 'limit=100' "$APIM_URL/api/am/devportal/v3/subscriptions")"
jq -e --arg product "$PRODUCT_ID" 'any(.list[]?; .apiId == $product and .throttlingPolicy == "SecureMobileBusiness")' <<<"$SUBS" >/dev/null || fail 'Partner application is not subscribed to the API Product with Business plan'
ok 'Partner is assigned to the Business subscription plan in APIM'

curl -fsS -X POST -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-reset' -d '{}' "$MI_URL/secure-mobile-transactions/v1/demo/reset" >/dev/null
curl -fsS -X PUT -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-business-assignment' \
  -d '{"planId":"Business","country":"BR","currency":"BRL","contractReference":"VERIFY-BUSINESS"}' \
  "$MI_URL/secure-mobile-transactions/v1/partners/fintech-br-001/plan" > "$WORK_DIR/business-assignment.json"
jq -e '.assignment.planId == "Business" and .assignment.country == "BR" and .assignment.currency == "BRL"' "$WORK_DIR/business-assignment.json" >/dev/null || fail 'Business plan assignment runtime behavior failed'

curl -fsS -X POST -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-seed' \
  -d '{"partnerId":"fintech-br-001","apiProduct":"SecureMobileTransactionsProduct","meter":"number_verification","successfulRequests":10000,"rejectedRequests":0,"billedAmount":0}' \
  "$MI_URL/secure-mobile-transactions/v1/demo/seed" > "$WORK_DIR/seed.json"
jq -e '.usage.overLimit == true and .usage.totals.successfulRequests == 10000' "$WORK_DIR/seed.json" >/dev/null || fail 'Included allowance exhaustion was not seeded correctly'

curl -fsS -X POST -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-business-overage' \
  -d '{"partnerId":"fintech-br-001","msisdn":"+5511999990001","consentId":"verify-consent-001","country":"BR","currency":"BRL"}' \
  "$MI_URL/secure-mobile-transactions/v1/number-verification" > "$WORK_DIR/overage.json"
jq -e '.outcome == "SUCCESS" and .commercialUsage.planId == "Business" and .commercialUsage.meter == "number_verification" and .commercialUsage.overLimit == true and .commercialUsage.chargeType == "BUSINESS_OVERAGE" and .commercialUsage.billedAmount == 0.08 and .commercialUsage.currency == "BRL"' "$WORK_DIR/overage.json" >/dev/null || fail 'Business Number Verification overage rating failed'

curl -fsS -X POST -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-business-sim-swap' \
  -d '{"partnerId":"fintech-br-001","msisdn":"+5511999990001","consentId":"verify-consent-sim-success"}' \
  "$MI_URL/secure-mobile-transactions/v1/sim-swap" > "$WORK_DIR/sim-swap-success.json"
jq -e '.outcome == "SUCCESS" and .commercialUsage.planId == "Business" and .commercialUsage.meter == "sim_swap" and .commercialUsage.chargeType == "BUSINESS_OVERAGE" and .commercialUsage.billedAmount == 0.14' "$WORK_DIR/sim-swap-success.json" >/dev/null || fail 'Business SIM Swap overage rating failed'

curl -fsS -X POST -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-business-qod' \
  -d '{"partnerId":"fintech-br-001","consentId":"verify-consent-qod-success","profile":"QOS_E","durationSeconds":900}' \
  "$MI_URL/secure-mobile-transactions/v1/quality-on-demand" > "$WORK_DIR/qod-success.json"
jq -e '.outcome == "SUCCESS" and .commercialUsage.planId == "Business" and .commercialUsage.meter == "quality_on_demand" and .commercialUsage.chargeType == "BUSINESS_OVERAGE" and .commercialUsage.billedAmount == 0.35' "$WORK_DIR/qod-success.json" >/dev/null || fail 'Business Quality on Demand overage rating failed'
ok 'Business overage prices differ by meter: NV BRL 0.08, SIM Swap BRL 0.14, QoD BRL 0.35'

REJECT_HTTP="$(curl -sS -o "$WORK_DIR/rejected.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-rejected' \
  -d '{"partnerId":"fintech-br-001","msisdn":"+5511999990001","consentId":"verify-consent-002","forceOutcome":"REJECTED"}' \
  "$MI_URL/secure-mobile-transactions/v1/sim-swap")"
[[ "$REJECT_HTTP" == 422 ]] || fail "Rejected request returned HTTP $REJECT_HTTP instead of 422"
jq -e '.outcome == "REJECTED" and .commercialUsage.meter == "sim_swap" and .commercialUsage.billedAmount == 0 and .commercialUsage.chargeType == "REJECTED_NO_CHARGE"' "$WORK_DIR/rejected.json" >/dev/null || fail 'Rejected request rating failed'
ok 'Rejected SIM Swap is recorded but billed at zero'

curl -fsS -X PUT -H 'Content-Type: application/json' -d '{"planId":"Sandbox","country":"BR","currency":"BRL"}' "$MI_URL/secure-mobile-transactions/v1/partners/sandbox-partner-br/plan" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-sandbox' \
  -d '{"partnerId":"sandbox-partner-br","msisdn":"+5511888881234","consentId":"verify-consent-003"}' \
  "$MI_URL/secure-mobile-transactions/v1/number-verification" > "$WORK_DIR/sandbox.json"
jq -e '.commercialUsage.planId == "Sandbox" and .commercialUsage.billedAmount == 0 and .commercialUsage.dataPolicy == "MASKED" and .result.masked == true and (.result.msisdn | startswith("********"))' "$WORK_DIR/sandbox.json" >/dev/null || fail 'Sandbox masking/free rating failed'
ok 'Sandbox is free and returns masked data'

curl -fsS -X PUT -H 'Content-Type: application/json' -d '{"planId":"Enterprise","country":"BR","currency":"BRL"}' "$MI_URL/secure-mobile-transactions/v1/partners/operator-enterprise-br/plan" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-enterprise-qod' \
  -d '{"partnerId":"operator-enterprise-br","consentId":"verify-consent-004","profile":"QOS_E","durationSeconds":900,"forceOutcome":"PARTIAL"}' \
  "$MI_URL/secure-mobile-transactions/v1/quality-on-demand" > "$WORK_DIR/enterprise.json"
jq -e '.outcome == "PARTIAL" and .partial == true and .commercialUsage.planId == "Enterprise" and .commercialUsage.meter == "quality_on_demand" and .commercialUsage.unitPrice == 0.22 and .commercialUsage.ratingFactor == 0.7 and .commercialUsage.billedAmount == 0.154 and .commercialUsage.slaEntitlement.availabilityPercent == 99.95' "$WORK_DIR/enterprise.json" >/dev/null || fail 'Enterprise QoD partial/SLA rating failed'
ok 'Enterprise committed QoD price, partial-response factor and SLA entitlement work'

curl -fsS -H 'X-Correlation-ID: verify-usage' "$MI_URL/secure-mobile-transactions/v1/partners/fintech-br-001/usage" > "$WORK_DIR/usage.json"
jq -e '.partnerId == "fintech-br-001" and .apiProduct == "SecureMobileTransactionsProduct" and .totals.successfulRequests >= 10001 and .totals.rejectedRequests >= 1 and (.perMeter | length) >= 3 and .recentEvents[0].correlationId != null' "$WORK_DIR/usage.json" >/dev/null || fail 'Partner/API Product usage summary failed'
ok 'Usage is visible by partner, API Product, meter, outcome and correlation ID'

METRICS="$(curl -fsS "$STORE_URL/metrics")"
grep -q 'telco_commercial_usage_requests_total' <<<"$METRICS" || fail 'Commercial request metrics are absent'
grep -q 'telco_commercial_billed_amount_total' <<<"$METRICS" || fail 'Commercial billed amount metrics are absent'
ok 'Prometheus commercial usage metrics are exposed'

VERIFY_APP_NAME="Commercial Verification $(date +%s)-$$"
APP_JSON="$(curl -ksS -X POST "${DEVPORTAL_AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"name\":\"${VERIFY_APP_NAME}\",\"throttlingPolicy\":\"Unlimited\",\"description\":\"Ephemeral managed-runtime verifier\",\"tokenType\":\"JWT\"}" \
  "$APIM_URL/api/am/devportal/v3/applications")"
VERIFY_APP_ID="$(jq -r '.applicationId // .id // empty' <<<"$APP_JSON")"
[[ -n "$VERIFY_APP_ID" ]] || fail "Could not create verification application: $APP_JSON"
SUB_JSON="$(curl -ksS -X POST "${DEVPORTAL_AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"applicationId\":\"${VERIFY_APP_ID}\",\"apiId\":\"${PRODUCT_ID}\",\"throttlingPolicy\":\"SecureMobileBusiness\"}" \
  "$APIM_URL/api/am/devportal/v3/subscriptions")"
jq -e '.subscriptionId != null' <<<"$SUB_JSON" >/dev/null || fail "Could not subscribe verification application: $SUB_JSON"
KEY_JSON="$(curl -ksS -X POST "${DEVPORTAL_AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"keyType":"PRODUCTION","grantTypesToBeSupported":["client_credentials"],"callbackUrl":"","validityTime":3600}' \
  "$APIM_URL/api/am/devportal/v3/applications/$VERIFY_APP_ID/generate-keys")"
CONSUMER_KEY="$(jq -r '.consumerKey // empty' <<<"$KEY_JSON")"
CONSUMER_SECRET="$(jq -r '.consumerSecret // empty' <<<"$KEY_JSON")"
[[ -n "$CONSUMER_KEY" && -n "$CONSUMER_SECRET" ]] || fail "Could not generate application keys: $KEY_JSON"
APP_TOKEN_JSON="$(curl -ksS -u "$CONSUMER_KEY:$CONSUMER_SECRET" \
  --data-urlencode grant_type=client_credentials \
  --data-urlencode 'scope=secure_mobile_transactions:invoke secure_mobile_transactions:commercial.read secure_mobile_transactions:commercial.manage' \
  "$APIM_URL/oauth2/token")"
APP_TOKEN="$(jq -r '.access_token // empty' <<<"$APP_TOKEN_JSON")"
if [[ -z "$APP_TOKEN" ]]; then
  # Keep gateway verification diagnostic across APIM installations where newly imported OAS scopes
  # become available only after a cache refresh; the API itself still declares the required scopes.
  APP_TOKEN_JSON="$(curl -ksS -u "$CONSUMER_KEY:$CONSUMER_SECRET" \
    --data-urlencode grant_type=client_credentials \
    "$APIM_URL/oauth2/token")"
  APP_TOKEN="$(jq -r '.access_token // empty' <<<"$APP_TOKEN_JSON")"
fi
[[ -n "$APP_TOKEN" ]] || fail "Could not obtain application token: $APP_TOKEN_JSON"
for _ in $(seq 1 30); do
  GATEWAY_HTTP="$(curl -ksS -o "$WORK_DIR/gateway.json" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $APP_TOKEN" -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-gateway-product' \
    -d '{"partnerId":"fintech-br-001","msisdn":"+5511999990001","consentId":"verify-consent-gateway"}' \
    "$GATEWAY_URL/secure-mobile-transactions-product/1.0.0/number-verification" || true)"
  [[ "$GATEWAY_HTTP" == 200 ]] && break
  sleep 2
done
[[ "$GATEWAY_HTTP" == 200 ]] || fail "API Product gateway invocation failed with HTTP $GATEWAY_HTTP: $(cat "$WORK_DIR/gateway.json" 2>/dev/null || true)"
jq -e '.commercialUsage.apiProduct == "SecureMobileTransactionsProduct" and .commercialUsage.planId == "Business" and .commercialUsage.billedAmount == 0.08 and .correlationId == "verify-gateway-product"' "$WORK_DIR/gateway.json" >/dev/null || fail 'Gateway response does not contain expected commercial usage/correlation data'
ok 'OAuth subscription and API Product invocation work through the APIM Gateway'

printf '\n[PASS] Secure Mobile Transactions commercial plan and usage-meter flow is complete.\n'
printf '[PASS] Sandbox=free/masked; Business=included+overage; Enterprise=committed/lower-price/SLA.\n'
printf '[PASS] Usage is operational per partner and SecureMobileTransactionsProduct.\n'
