#!/usr/bin/env bash
set -euo pipefail

APIM_URL="${APIM_URL:-https://127.0.0.1:9443}"
MI_URL="${MI_URL:-http://127.0.0.1:8290}"
LOKI_URL="${LOKI_URL:-http://127.0.0.1:3100}"
GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:3000}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/audit-siem-verify.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

ok() { printf '[audit-siem][OK] %s\n' "$*"; }
fail() { printf '[audit-siem][FAIL] %s\n' "$*" >&2; exit 1; }
require_file() { [[ -s "$1" ]] || fail "missing or empty file: $1"; }

for file in \
  contracts/openapi/telco-audit-events.openapi.yaml \
  artifacts/openapi/telco-audit-events.openapi.yaml \
  artifacts/apim-admin/commercial-plans.json \
  artifacts/apim-admin/api-product-bundles.json \
  services/wso2-mi/synapse-configs/default/api/TelcoAuditEventsAPI.xml \
  services/wso2-mi/synapse-configs/default/endpoints/AuditTelemetryFailoverEndpoint.xml \
  services/wso2-mi/synapse-configs/default/sequences/AuditDeliverySequence.xml \
  services/wso2-mi/synapse-configs/default/sequences/AuditDeliveryFaultSequence.xml \
  services/wso2-mi/synapse-configs/default/sequences/AuditApiFaultSequence.xml \
  services/wso2-mi/synapse-configs/default/sequences/EmitBillingCorrectionAuditSequence.xml \
  services/wso2-mi/synapse-configs/default/api/BillingAdjustmentModernizationAPI.xml \
  services/apim-bootstrapper/src/audit-siem-bootstrap-events.js \
  observability/grafana/dashboards/telco-audit-siem.json \
  artifacts/postman/telco-audit-siem.postman_collection.json \
  artifacts/sdk/audit-siem/README.md \
  docs/audit-siem.md \
  docker-compose.audit-siem.yml \
  scripts/generate-audit-siem-events.sh \
  scripts/register-mi-service-catalog.sh \
  scripts/telco-demo-control.sh; do
  require_file "$file"
done
ok "all expected source artifacts exist"

python3 - <<'PY'
import json
import xml.etree.ElementTree as ET
from pathlib import Path
for p in Path('services/wso2-mi/synapse-configs/default').rglob('*.xml'):
    if p.name in {
        'TelcoAuditEventsAPI.xml', 'AuditTelemetryFailoverEndpoint.xml',
        'AuditDeliverySequence.xml', 'AuditDeliveryFaultSequence.xml',
        'AuditApiFaultSequence.xml', 'EmitBillingCorrectionAuditSequence.xml'
    }:
        ET.parse(p)
for p in [
    Path('artifacts/apim-admin/commercial-plans.json'),
    Path('artifacts/apim-admin/api-product-bundles.json'),
    Path('observability/grafana/dashboards/telco-audit-siem.json'),
    Path('artifacts/postman/telco-audit-siem.postman_collection.json')
]:
    json.loads(p.read_text())
plans=json.loads(Path('artifacts/apim-admin/commercial-plans.json').read_text())
assert any(x.get('policyName')=='TelcoSecurityAuditBurst' for x in plans)
bundles=json.loads(Path('artifacts/apim-admin/api-product-bundles.json').read_text())
assert any(x.get('id')=='telco-audit-siem' and x.get('apim',{}).get('apiProductName')=='TelcoAuditSIEMProduct' for x in bundles)
PY
grep -q "TelcoAuditEventsAPI" services/apim-bootstrapper/src/bootstrap.js || fail "audit API bootstrap registration is absent"
grep -q "audit-siem-bootstrap-events.js" services/apim-bootstrapper/package.json || fail "audit management event emitter is absent from bootstrap start"
grep -q "EmitBillingCorrectionAuditSequence" services/wso2-mi/synapse-configs/default/api/BillingAdjustmentModernizationAPI.xml || fail "billing correction audit hook is absent"
grep -q "TelcoAuditEventsAPI" scripts/register-mi-service-catalog.sh || fail "audit Service Catalog registration is absent"
grep -q "BillingAdjustmentModernizationAPI" scripts/register-mi-service-catalog.sh || fail "billing Service Catalog registration is absent"
grep -q "docker-compose.audit-siem.yml" scripts/telco-demo-control.sh || fail "audit Compose overlay is absent from the controller"
ok "XML and JSON artifacts parse; expected plan, bundle and repository patches are present"

docker compose \
  -f docker-compose.yml \
  -f docker-compose.kafka.yml \
  -f docker-compose.opa.yml \
  -f docker-compose.mi.yml \
  -f docker-compose.commercial.yml \
  -f docker-compose.mi.soap.yml \
  -f docker-compose.observability.yml \
  -f docker-compose.runtime-persistence.yml \
  -f docker-compose.audit-siem.yml \
  config -q
ok "merged Docker Compose topology is valid"

health_status="$(curl -sS -o "$TMP_DIR/mi-health.json" -w '%{http_code}' "${MI_URL}/audit-events/v1/health")"
[[ "$health_status" == 200 ]] || { cat "$TMP_DIR/mi-health.json" >&2; fail "MI audit health returned HTTP ${health_status}"; }
jq -e '.status=="UP" and .service=="TelcoAuditEventsAPI" and (.correlationId|length>0)' "$TMP_DIR/mi-health.json" >/dev/null
ok "MI Audit Events API is healthy"

cat > "$TMP_DIR/dcr.json" <<JSON
{"callbackUrl":"http://localhost:8080/callback","clientName":"audit-siem-verifier-$(date +%s)-$$","owner":"${APIM_USER}","grantType":"password refresh_token client_credentials","saasApp":true}
JSON
curl -ksS -u "${APIM_USER}:${APIM_PASSWORD}" -H 'Content-Type: application/json' \
  -d @"$TMP_DIR/dcr.json" "${APIM_URL}/client-registration/v0.17/register" > "$TMP_DIR/dcr-response.json"
CLIENT_ID="$(jq -r '.clientId // empty' "$TMP_DIR/dcr-response.json")"
CLIENT_SECRET="$(jq -r '.clientSecret // empty' "$TMP_DIR/dcr-response.json")"
[[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]] || { cat "$TMP_DIR/dcr-response.json" >&2; fail "APIM DCR failed"; }

obtain_token() {
  local scope="$1" output="$2" token
  curl -ksS -u "${CLIENT_ID}:${CLIENT_SECRET}" \
    --data-urlencode grant_type=password \
    --data-urlencode "username=${APIM_USER}" \
    --data-urlencode "password=${APIM_PASSWORD}" \
    --data-urlencode "scope=${scope}" \
    "${APIM_URL}/oauth2/token" > "$output"
  token="$(jq -r '.access_token // empty' "$output")"
  [[ -n "$token" ]] || return 1
  printf '%s' "$token"
}

TOKEN=''
for scope in \
  'apim:api_view apim:api_product_view apim:admin_tier_view apim:document_view' \
  'apim:api_view apim:api_product_view apim:admin_tier_view' \
  'apim:api_view apim:api_product_view'; do
  if TOKEN="$(obtain_token "$scope" "$TMP_DIR/publisher-token.json")"; then
    break
  fi
done
[[ -n "$TOKEN" ]] || { cat "$TMP_DIR/publisher-token.json" >&2; fail "APIM Publisher/Admin token acquisition failed"; }
AUTH=(-H "Authorization: Bearer ${TOKEN}" -H 'Accept: application/json')

CATALOG_TOKEN=''
for scope in \
  'service_catalog:service_view' \
  'service_catalog:service_view apim:api_view'; do
  if CATALOG_TOKEN="$(obtain_token "$scope" "$TMP_DIR/catalog-token.json")"; then
    break
  fi
done
[[ -n "$CATALOG_TOKEN" ]] || { cat "$TMP_DIR/catalog-token.json" >&2; fail "APIM Service Catalog token acquisition failed"; }
CATALOG_AUTH=(-H "Authorization: Bearer ${CATALOG_TOKEN}" -H 'Accept: application/json')

DEVPORTAL_TOKEN=''
for scope in \
  'apim:subscribe apim:app_manage apim:sub_manage' \
  'apim:subscribe apim:app_manage'; do
  if DEVPORTAL_TOKEN="$(obtain_token "$scope" "$TMP_DIR/devportal-token.json")"; then
    break
  fi
done
[[ -n "$DEVPORTAL_TOKEN" ]] || { cat "$TMP_DIR/devportal-token.json" >&2; fail "APIM DevPortal token acquisition failed"; }
DEVPORTAL_AUTH=(-H "Authorization: Bearer ${DEVPORTAL_TOKEN}" -H 'Accept: application/json')

curl -ksS "${AUTH[@]}" "${APIM_URL}/api/am/publisher/v4/apis?limit=1000" > "$TMP_DIR/apis.json"
API_ID="$(jq -r 'first((.list // .data // [])[] | select(.name=="TelcoAuditEventsAPI" and .version=="1.0.0") | .id) // empty' "$TMP_DIR/apis.json")"
[[ -n "$API_ID" ]] || fail "TelcoAuditEventsAPI:1.0.0 is missing"
curl -ksS "${AUTH[@]}" "${APIM_URL}/api/am/publisher/v4/apis/${API_ID}" > "$TMP_DIR/api.json"
jq -e '.name=="TelcoAuditEventsAPI" and .version=="1.0.0" and (.state // .lifeCycleStatus)=="PUBLISHED"' "$TMP_DIR/api.json" >/dev/null || { cat "$TMP_DIR/api.json" >&2; fail "Audit API is not PUBLISHED"; }
POLICIES="$(jq -r '(.policies // []) | join(",")' "$TMP_DIR/api.json")"
[[ "$POLICIES" == *TelcoSecurityAuditBurst* ]] || fail "Audit API is not assigned TelcoSecurityAuditBurst"
ok "audit API exists, is PUBLISHED and has the expected commercial policy"

curl -ksS "${AUTH[@]}" "${APIM_URL}/api/am/publisher/v4/apis/${API_ID}/revisions" > "$TMP_DIR/revisions.json"
jq -e 'any((.list // .data // [])[]?; ((.deploymentInfo // []) | length) > 0)' "$TMP_DIR/revisions.json" >/dev/null || { cat "$TMP_DIR/revisions.json" >&2; fail "Audit API has no deployed revision"; }
ok "audit API has a deployed gateway revision"

SIM_API_ID="$(jq -r 'first((.list // .data // [])[] | select(.name=="OpenGatewaySimSwapRiskAPI" and .version=="1.0.0") | .id) // empty' "$TMP_DIR/apis.json")"
BILLING_API_ID="$(jq -r 'first((.list // .data // [])[] | select(.name=="BillingAdjustmentModernizationAPI" and .version=="1.0.0") | .id) // empty' "$TMP_DIR/apis.json")"
[[ -n "$SIM_API_ID" && -n "$BILLING_API_ID" ]] || fail "SIM Swap or Billing Adjustment API is missing"
curl -ksS "${AUTH[@]}" "${APIM_URL}/api/am/publisher/v4/apis/${SIM_API_ID}" > "$TMP_DIR/sim-api.json"
jq -e '.lifeCycleStatus=="PUBLISHED" and any((.policies // [])[]?; .=="TelcoSecurityAuditBurst")' "$TMP_DIR/sim-api.json" >/dev/null || { cat "$TMP_DIR/sim-api.json" >&2; fail "SIM Swap API is not published with TelcoSecurityAuditBurst"; }

curl -ksS "${AUTH[@]}" "${APIM_URL}/api/am/publisher/v4/api-products?limit=1000" > "$TMP_DIR/products.json"
PRODUCT_ID="$(jq -r 'first((.list // .data // [])[] | select(.name=="TelcoAuditSIEMProduct" and .version=="1.0.0") | .id) // empty' "$TMP_DIR/products.json")"
[[ -n "$PRODUCT_ID" ]] || fail "TelcoAuditSIEMProduct:1.0.0 is missing"
curl -ksS "${AUTH[@]}" "${APIM_URL}/api/am/publisher/v4/api-products/${PRODUCT_ID}" > "$TMP_DIR/product.json"
jq -e --arg auditId "$API_ID" --arg simId "$SIM_API_ID" --arg billingId "$BILLING_API_ID" '
  (.state // .lifeCycleStatus)=="PUBLISHED" and
  any((.policies // [])[]?; .=="TelcoSecurityAuditBurst") and
  any((.apis // [])[]?; .apiId==$auditId) and
  any((.apis // [])[]?; .apiId==$simId) and
  any((.apis // [])[]?; .apiId==$billingId)
' "$TMP_DIR/product.json" >/dev/null || { cat "$TMP_DIR/product.json" >&2; fail "API Product is not published, lacks the expected policy, or lacks a member API"; }
ok "TelcoAuditSIEMProduct is published with all three member APIs and the expected plan"

curl -ksS "${AUTH[@]}" "${APIM_URL}/api/am/publisher/v4/api-products/${PRODUCT_ID}/revisions" > "$TMP_DIR/product-revisions.json"
jq -e 'any((.list // .data // [])[]?; ((.deploymentInfo // []) | length) > 0)' "$TMP_DIR/product-revisions.json" >/dev/null || { cat "$TMP_DIR/product-revisions.json" >&2; fail "Audit API Product has no deployed revision"; }
ok "audit API Product has a deployed gateway revision"

curl -ksS "${AUTH[@]}" "${APIM_URL}/api/am/admin/v4/throttling/policies/subscription?limit=1000" > "$TMP_DIR/policies.json"
jq -e '
  any((.list // .data // [])[]?;
    .policyName == "TelcoSecurityAuditBurst"
    and .billingPlan == "COMMERCIAL"
    and .stopOnQuotaReach == true
    and .defaultLimit.type == "REQUESTCOUNTLIMIT"
    and .defaultLimit.requestCount.requestCount == 5
    and .defaultLimit.requestCount.unitTime == 1
    and (
      (.defaultLimit.requestCount.timeUnit // "")
      | ascii_downcase
    ) == "min"
  )
' "$TMP_DIR/policies.json" >/dev/null || {
  jq -c '
    (.list // .data // [])
    | map(select(.policyName == "TelcoSecurityAuditBurst"))
  ' "$TMP_DIR/policies.json" >&2
  fail "TelcoSecurityAuditBurst is missing or incorrect"
}
ok "subscription/commercial policy is installed with 5 requests per minute"

curl -ksS "${DEVPORTAL_AUTH[@]}" \
  "${APIM_URL}/api/am/devportal/v3/applications?limit=1000" > "$TMP_DIR/applications.json"
AUDIT_APP_ID="$(jq -r 'first((.list // .data // [])[] | select(.name=="Audit SIEM Verifier") | .applicationId) // empty' "$TMP_DIR/applications.json")"
[[ -n "$AUDIT_APP_ID" ]] || { cat "$TMP_DIR/applications.json" >&2; fail "Audit SIEM Verifier application is missing"; }

curl -ksS "${DEVPORTAL_AUTH[@]}" \
  "${APIM_URL}/api/am/devportal/v3/subscriptions?applicationId=${AUDIT_APP_ID}&limit=100" > "$TMP_DIR/subscriptions.json"
jq -e '
  ((.list // .data // []) as $items |
    any($items[]?; .apiInfo.name=="TelcoAuditEventsAPI" and .throttlingPolicy=="TelcoSecurityAuditBurst") and
    any($items[]?; .apiInfo.name=="OpenGatewaySimSwapRiskAPI" and .throttlingPolicy=="TelcoSecurityAuditBurst"))
' "$TMP_DIR/subscriptions.json" >/dev/null || { cat "$TMP_DIR/subscriptions.json" >&2; fail "Audit SIEM Verifier subscriptions are missing or use the wrong policy"; }

curl -ksS "${DEVPORTAL_AUTH[@]}" \
  "${APIM_URL}/api/am/devportal/v3/applications/${AUDIT_APP_ID}/oauth-keys" > "$TMP_DIR/oauth-keys.json"
jq -e 'any((.list // .data // [])[]?; ((.keyType // "") | ascii_upcase)=="PRODUCTION" and ((.consumerKey // "") | length)>0)' \
  "$TMP_DIR/oauth-keys.json" >/dev/null || { cat "$TMP_DIR/oauth-keys.json" >&2; fail "Audit SIEM Verifier production credential mapping is missing"; }

# audit-bootstrapper-state-exec-v1
# The APIM bootstrapper is a one-shot Compose service, not a permanently
# running container. Execute state inspection commands in a temporary
# bootstrapper container that mounts the same persistent state volume.
bootstrapper_exec() {
  local executable="${1:-}"

  [[ -n "$executable" ]] || {
    fail "bootstrapper_exec requires a command"
  }

  shift

  local -a compose=(docker compose -f docker-compose.yml)
  local compose_file

  for compose_file in \
    docker-compose.kafka.yml \
    docker-compose.opa.yml \
    docker-compose.mi.yml \
    docker-compose.commercial.yml \
    docker-compose.mi.soap.yml \
    docker-compose.observability.yml \
    docker-compose.audit-siem.yml \
    docker-compose.runtime-persistence.yml
  do
    [[ -f "$compose_file" ]] && compose+=(-f "$compose_file")
  done

  "${compose[@]}" run \
    -T \
    --rm \
    --no-deps \
    --entrypoint "$executable" \
    apim-bootstrapper \
    "$@"
}

bootstrapper_exec sh -lc 'cat /workspace/state/audit-siem-bootstrap-events.json' > "$TMP_DIR/audit-runtime-state.json"
jq -e --arg appId "$AUDIT_APP_ID" '
  .application.applicationId==$appId and
  .application.subscriptionPolicy=="TelcoSecurityAuditBurst" and
  ((.application.consumerKey // "") | length)>0 and
  ((.application.consumerSecret // "") | length)>0
' "$TMP_DIR/audit-runtime-state.json" >/dev/null || { cat "$TMP_DIR/audit-runtime-state.json" >&2; fail "Persisted audit runtime credentials are missing or inconsistent"; }
ok "dedicated verifier application, subscriptions and production credentials are present"

curl -ksS "${AUTH[@]}" -H 'Accept: application/json, application/yaml, text/yaml, */*' \
  "${APIM_URL}/api/am/publisher/v4/apis/${API_ID}/swagger" > "$TMP_DIR/audit-swagger.txt"
grep -q 'telco_audit_write' "$TMP_DIR/audit-swagger.txt" || { cat "$TMP_DIR/audit-swagger.txt" >&2; fail "published audit definition lacks telco_audit_write"; }
ok "published API definition contains the required OAuth write scope"

curl -ksS "${AUTH[@]}" "${APIM_URL}/api/am/publisher/v4/apis/${API_ID}/documents?limit=100" > "$TMP_DIR/api-docs.json"
API_DOC_NAMES=(
  '01 - Business Overview'
  '02 - Contract and CAMARA Alignment'
  '03 - Authentication and First Call'
  '04 - Consent and Privacy Requirements'
  '05 - Error Catalogue'
  '06 - Rate Limits and Commercial Plan'
  '07 - SLA Support and Resilience'
  '08 - Code Samples Postman and SDKs'
  '09 - Sandbox Test Data'
)
for expected_doc in "${API_DOC_NAMES[@]}"; do
  jq -e --arg name "$expected_doc" 'any((.list // .data // [])[]?; .name==$name)' "$TMP_DIR/api-docs.json" >/dev/null || { cat "$TMP_DIR/api-docs.json" >&2; fail "missing audit API document: ${expected_doc}"; }
done
ok "all nine expected Developer Portal API documents are present"

curl -ksS "${AUTH[@]}" "${APIM_URL}/api/am/publisher/v4/api-products/${PRODUCT_ID}/documents?limit=100" > "$TMP_DIR/product-docs.json"
PRODUCT_DOC_NAMES=(
  '01 - Product Overview and API Map'
  '02 - Product Onboarding and First Call'
  '03 - Consent and Compliance Matrix'
  '04 - Commercial Plans Rate Limits and SLA'
  '05 - Sandbox Postman and SDK Toolkit'
)
for expected_doc in "${PRODUCT_DOC_NAMES[@]}"; do
  jq -e --arg name "$expected_doc" 'any((.list // .data // [])[]?; .name==$name)' "$TMP_DIR/product-docs.json" >/dev/null || { cat "$TMP_DIR/product-docs.json" >&2; fail "missing audit API Product document: ${expected_doc}"; }
done
ok "all five expected Developer Portal API Product documents are present"

curl -ksS "${CATALOG_AUTH[@]}" "${APIM_URL}/api/am/service-catalog/v1/services?limit=100" > "$TMP_DIR/catalog.json"
EXPECTED_CATALOG_SERVICES=(
  SecureTransactionRiskAssessmentAPI
  CrmRiskAdapterAPI
  SimSwapRiskAdapterAPI
  DeviceLocationRiskAdapterAPI
  OssRiskAdapterAPI
  RuntimePolicyAlertAPI
  TelcoAuditEventsAPI
  BillingAdjustmentModernizationAPI
)
for expected_service in "${EXPECTED_CATALOG_SERVICES[@]}"; do
  jq -e --arg name "$expected_service" 'any((.list // .data // [])[]?; .name==$name and .version=="1.0.0")' "$TMP_DIR/catalog.json" >/dev/null || { cat "$TMP_DIR/catalog.json" >&2; fail "missing Service Catalog entry: ${expected_service}:1.0.0"; }
done
ok "all eight expected MI-managed services are registered in the APIM Service Catalog"

curl -fsS "${GRAFANA_URL}/api/health" > "$TMP_DIR/grafana-health.json"
curl -fsS -u admin:admin "${GRAFANA_URL}/api/dashboards/uid/telco-audit-siem" > "$TMP_DIR/dashboard.json"
jq -e '.dashboard.uid=="telco-audit-siem"' "$TMP_DIR/dashboard.json" >/dev/null || { cat "$TMP_DIR/dashboard.json" >&2; fail "Grafana audit dashboard was not provisioned"; }
ok "Grafana SIEM dashboard is provisioned"

CORRELATION_PREFIX="audit-siem-verify-$(date +%s)" scripts/generate-audit-siem-events.sh
ok "runtime authentication, burst and billing scenarios executed"

EXPECTED=(
  API_PUBLICATION
  POLICY_MODIFICATION
  SUBSCRIPTION_APPROVAL
  CREDENTIAL_CREATION
  FAILED_AUTHENTICATION
  EXCESSIVE_SIM_SWAP_REQUESTS
  BILLING_CORRECTION
  ADMINISTRATOR_ACTION
)
QUERY='{job="telco.structured"} | json | stage="audit"'
found=0
for attempt in $(seq 1 30); do
  curl -sS -G "${LOKI_URL}/loki/api/v1/query_range" \
    --data-urlencode "query=${QUERY}" \
    --data-urlencode "limit=5000" \
    --data-urlencode "start=$(($(date +%s)-604800))000000000" \
    --data-urlencode "end=$(date +%s)000000000" > "$TMP_DIR/loki.json"
  jq -r '.data.result[]?.values[]?[1]' "$TMP_DIR/loki.json" > "$TMP_DIR/lines.txt"
  missing=0
  for event in "${EXPECTED[@]}"; do
    grep -q "\"eventType\":\"${event}\"" "$TMP_DIR/lines.txt" || grep -q "\"eventType\": \"${event}\"" "$TMP_DIR/lines.txt" || missing=$((missing+1))
  done
  if (( missing == 0 )); then found=1; break; fi
  sleep 2
done
(( found == 1 )) || { cat "$TMP_DIR/loki.json" >&2; fail "Loki does not contain all eight expected audit event types"; }
ok "Loki contains all eight expected audit event types"

echo
printf '%s\n' '[audit-siem] Verification completed successfully.'
printf '%s\n' '[audit-siem] Dashboard: http://localhost:3000/d/telco-audit-siem/telco-api-platform-audit-and-siem'
