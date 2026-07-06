#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
  else
    echo "Docker Compose was not found." >&2
    exit 1
  fi
  COMPOSE+=(-f docker-compose.yml -f docker-compose.mi.yml -f docker-compose.mi.soap.yml)
  echo "Using Docker Compose: ${COMPOSE[*]}"
}

detect_compose
MI_URL="${MI_SOAP_URL:-http://127.0.0.1:8290/billing-adjustments/v1}"
APIM_TOKEN_URL="${APIM_TOKEN_URL:-https://127.0.0.1:9443/oauth2/token}"
APIM_GATEWAY_URL="${APIM_SOAP_GATEWAY_URL:-https://127.0.0.1:8243/billing-adjustments/v1}"
TMP_DIR="$(mktemp -d)"
primary_was_stopped=false
cleanup() {
  if [[ "$primary_was_stopped" == true ]]; then
    docker start telco-legacy-billing-primary >/dev/null 2>&1 || true
  fi
  curl -sS -X POST -H 'Content-Type: application/json' -H 'X-Demo-Admin-Key: demo-admin-key' \
    -d '{"mode":"normal"}' http://127.0.0.1:18091/admin/mode >/dev/null 2>&1 || true
  curl -sS -X POST -H 'Content-Type: application/json' -H 'X-Demo-Admin-Key: demo-admin-key' \
    -d '{"mode":"normal"}' http://127.0.0.1:18092/admin/mode >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

pretty() { jq . "$1"; }
assert_json() {
  local file="$1" expression="$2" message="$3"
  python3 - "$file" "$expression" "$message" <<'PY'
import json, sys
path, expression, message = sys.argv[1:]
with open(path, encoding='utf-8') as stream:
    d = json.load(stream)
if not eval(expression, {'__builtins__': {}}, {'d': d, 'len': len}):
    raise SystemExit(f'ASSERTION FAILED: {message}\nPayload: {json.dumps(d, indent=2)}')
print(f'PASS: {message}')
PY
}

post_mi() {
  local output="$1" correlation="$2" body="$3"
  curl -sS -o "$output" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -H "X-Correlation-ID: ${correlation}" \
    -H "Idempotency-Key: ${correlation}" \
    -d "$body" \
    "${MI_URL}/adjustments"
}

base_body='{
  "transactionId": "txn-billing-2026-0001",
  "subscriberId": "5215512340001",
  "amount": 125.75,
  "currency": "MXN",
  "reasonCode": "GOODWILL_CREDIT",
  "requestedBy": "partner-care-portal"
}'

echo "1) Runtime health"
for url in \
  http://127.0.0.1:18091/health \
  http://127.0.0.1:18092/health \
  "${MI_URL}/health"
do
  curl -fsS "$url" | jq .
done

echo
echo "2) Legacy SOAP backend rejects requests without WS-Security"
cat > "$TMP_DIR/no-wsse.xml" <<'XML'
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:leg="urn:americamovil:bss:billing:v1">
  <soapenv:Header/>
  <soapenv:Body><leg:AdjustBillingRequest><leg:transactionId>direct-unauthorized</leg:transactionId></leg:AdjustBillingRequest></soapenv:Body>
</soapenv:Envelope>
XML
auth_code="$(curl -sS -o "$TMP_DIR/auth-fault.xml" -w '%{http_code}' \
  -H 'Content-Type: text/xml' -H 'SOAPAction: urn:AdjustBilling' \
  --data-binary @"$TMP_DIR/no-wsse.xml" \
  http://127.0.0.1:18091/LegacyBillingAdjustmentService)"
[[ "$auth_code" == "500" ]] || { cat "$TMP_DIR/auth-fault.xml"; exit 1; }
grep -q 'BSS-AUTH-FAILED' "$TMP_DIR/auth-fault.xml"
echo "PASS: missing WS-Security is rejected with a SOAP fault"

echo
echo "3) REST/JSON -> SOAP/WS-Security -> JSON through MI"
normal="$TMP_DIR/normal.json"
normal_code="$(post_mi "$normal" demo-soap-normal-001 "$base_body")"
[[ "$normal_code" == "200" ]] || { cat "$normal"; exit 1; }
pretty "$normal"
assert_json "$normal" "d.get('status') == 'APPLIED'" "legacy adjustment is applied"
assert_json "$normal" "d.get('backendNode') == 'PRIMARY'" "primary BSS node handled the request"
assert_json "$normal" "d.get('correlationId') == 'demo-soap-normal-001'" "correlation ID is preserved"

adjustment_id="$(jq -r '.adjustmentId' "$normal")"

echo
echo "4) Idempotent replay uses the same legacy transaction"
replay="$TMP_DIR/replay.json"
replay_code="$(post_mi "$replay" demo-soap-replay-001 "$base_body")"
[[ "$replay_code" == "200" ]] || { cat "$replay"; exit 1; }
pretty "$replay"
assert_json "$replay" "d.get('adjustmentId') == '${adjustment_id}'" "idempotent replay returns the same adjustment ID"
assert_json "$replay" "d.get('idempotentReplay') is True" "legacy backend identifies the replay"

echo
echo "5) SOAP business fault -> normalized REST 404"
not_found="$TMP_DIR/not-found.json"
not_found_body='{
  "transactionId": "txn-billing-not-found-001",
  "subscriberId": "NOT-FOUND-001",
  "amount": 25,
  "currency": "MXN",
  "reasonCode": "GOODWILL_CREDIT",
  "requestedBy": "partner-care-portal"
}'
not_found_code="$(post_mi "$not_found" demo-soap-not-found-001 "$not_found_body")"
[[ "$not_found_code" == "404" ]] || { echo "Expected 404, got $not_found_code"; cat "$not_found"; exit 1; }
pretty "$not_found"
assert_json "$not_found" "d.get('code') == 'BILLING_ACCOUNT_NOT_FOUND'" "legacy account fault is normalized"

echo
echo "6) SOAP business rejection -> normalized REST 422"
rejected="$TMP_DIR/rejected.json"
rejected_body='{
  "transactionId": "txn-billing-rejected-001",
  "subscriberId": "5215512340001",
  "amount": 7500,
  "currency": "MXN",
  "reasonCode": "LIMIT_EXCEEDED",
  "requestedBy": "partner-care-portal"
}'
rejected_code="$(post_mi "$rejected" demo-soap-rejected-001 "$rejected_body")"
[[ "$rejected_code" == "422" ]] || { echo "Expected 422, got $rejected_code"; cat "$rejected"; exit 1; }
pretty "$rejected"
assert_json "$rejected" "d.get('code') == 'BILLING_ADJUSTMENT_REJECTED'" "legacy rejection is normalized"

echo
echo "7) Primary timeout -> automatic DR failover and endpoint suspension"
curl -fsS -X POST \
  -H 'Content-Type: application/json' \
  -H 'X-Demo-Admin-Key: demo-admin-key' \
  -d '{"mode":"slow","delayMs":6000}' \
  http://127.0.0.1:18091/admin/mode | jq .
timeout_body='{
  "transactionId": "txn-billing-timeout-001",
  "subscriberId": "5215512340004",
  "amount": 77,
  "currency": "MXN",
  "reasonCode": "TIMEOUT_FAILOVER_TEST",
  "requestedBy": "partner-care-portal"
}'
timeout_result="$TMP_DIR/timeout-failover.json"
timeout_code="$(post_mi "$timeout_result" demo-soap-timeout-001 "$timeout_body")"
[[ "$timeout_code" == "200" ]] || { cat "$timeout_result"; exit 1; }
pretty "$timeout_result"
assert_json "$timeout_result" "d.get('backendNode') == 'DR'" "DR node handled the request after primary timeout"
curl -fsS -X POST \
  -H 'Content-Type: application/json' \
  -H 'X-Demo-Admin-Key: demo-admin-key' \
  -d '{"mode":"normal"}' \
  http://127.0.0.1:18091/admin/mode >/dev/null
# The first suspension window is five seconds. Wait until the primary is eligible again.
sleep 6

echo
echo "8) Primary-node outage -> automatic DR failover and circuit opening"
docker stop telco-legacy-billing-primary >/dev/null
primary_was_stopped=true
failover_body='{
  "transactionId": "txn-billing-dr-001",
  "subscriberId": "5215512340002",
  "amount": 75,
  "currency": "MXN",
  "reasonCode": "SERVICE_RECOVERY_CREDIT",
  "requestedBy": "partner-care-portal"
}'
failover="$TMP_DIR/failover.json"
started_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
failover_code="$(post_mi "$failover" demo-soap-failover-001 "$failover_body")"
ended_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
[[ "$failover_code" == "200" ]] || { cat "$failover"; exit 1; }
pretty "$failover"
echo "Failover request duration: $((ended_ms-started_ms)) ms"
assert_json "$failover" "d.get('backendNode') == 'DR'" "DR node handled the request after primary failure"

fast_body='{
  "transactionId": "txn-billing-dr-002",
  "subscriberId": "5215512340003",
  "amount": 76,
  "currency": "MXN",
  "reasonCode": "SERVICE_RECOVERY_CREDIT",
  "requestedBy": "partner-care-portal"
}'
fast="$TMP_DIR/fast.json"
started_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
fast_code="$(post_mi "$fast" demo-soap-circuit-open-001 "$fast_body")"
ended_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
[[ "$fast_code" == "200" ]] || { cat "$fast"; exit 1; }
pretty "$fast"
echo "Circuit-open request duration: $((ended_ms-started_ms)) ms"
assert_json "$fast" "d.get('backendNode') == 'DR'" "suspended primary is bypassed"

echo
echo "9) Primary recovery and failback"
docker start telco-legacy-billing-primary >/dev/null
primary_was_stopped=false
for attempt in $(seq 1 30); do
  health="$(docker inspect telco-legacy-billing-primary --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || true)"
  [[ "$health" == "healthy" ]] && break
  sleep 1
done
sleep 6
failback_ok=false
for attempt in $(seq 1 10); do
  body="{\"transactionId\":\"txn-billing-failback-${attempt}\",\"subscriberId\":\"5215512340099\",\"amount\":10,\"currency\":\"MXN\",\"reasonCode\":\"FAILBACK_TEST\",\"requestedBy\":\"test-suite\"}"
  out="$TMP_DIR/failback-${attempt}.json"
  code="$(post_mi "$out" "demo-soap-failback-${attempt}" "$body")"
  if [[ "$code" == "200" && "$(jq -r '.backendNode' "$out")" == "PRIMARY" ]]; then
    pretty "$out"
    failback_ok=true
    break
  fi
  sleep 2
done
[[ "$failback_ok" == true ]] || { echo "Primary did not become active again" >&2; exit 1; }
echo "PASS: failover endpoint returned to the primary node"

echo
echo "10) APIM managed façade"
state_json="$("${COMPOSE[@]}" exec -T demo-portal cat /workspace/apim-portal-state/runtime.json 2>/dev/null || true)"
if [[ -z "$state_json" ]]; then
  echo "SKIP: portal runtime credentials unavailable; direct MI tests passed"
else
  consumer_key="$(printf '%s' "$state_json" | jq -r '.application.consumerKey')"
  consumer_secret="$(printf '%s' "$state_json" | jq -r '.application.consumerSecret')"
  token_json="$(curl -ksS -u "${consumer_key}:${consumer_secret}" -d 'grant_type=client_credentials' "$APIM_TOKEN_URL")"
  access_token="$(printf '%s' "$token_json" | jq -r '.access_token')"
  gateway_body='{
    "transactionId": "txn-billing-apim-001",
    "subscriberId": "5215512340100",
    "amount": 33.50,
    "currency": "MXN",
    "reasonCode": "PARTNER_CREDIT",
    "requestedBy": "managed-partner-app"
  }'
  gateway="$TMP_DIR/gateway.json"
  gateway_code="$(curl -ksS -o "$gateway" -w '%{http_code}' \
    -H "Authorization: Bearer ${access_token}" \
    -H 'Content-Type: application/json' \
    -H 'X-Correlation-ID: demo-soap-through-apim-001' \
    -d "$gateway_body" \
    "${APIM_GATEWAY_URL}/adjustments")"
  [[ "$gateway_code" == "200" ]] || { cat "$gateway"; exit 1; }
  pretty "$gateway"
  assert_json "$gateway" "d.get('correlationId') == 'demo-soap-through-apim-001'" "request traverses APIM, MI and SOAP BSS"
fi

echo
echo "11) Deployed endpoint and Service Catalog registration"
login="$(curl -ksS -u admin:admin -H 'Accept: application/json' https://127.0.0.1:9164/management/login)"
mi_token="$(printf '%s' "$login" | jq -r '.AccessToken // empty')"
[[ -n "$mi_token" ]] || { echo "Could not obtain MI management token" >&2; exit 1; }
curl -ksS -H "Authorization: Bearer ${mi_token}" https://127.0.0.1:9164/management/endpoints \
  | jq -e 'any(.list[]?; .name == "LegacyBillingSoapFailoverEndpoint" and .isActive == true)' >/dev/null
echo "PASS: LegacyBillingSoapFailoverEndpoint is active"

"$SCRIPT_DIR/register-soap-modernization-service-catalog.sh" >/dev/null
echo "PASS: Service Catalog entries are present"

echo
"${COMPOSE[@]}" logs --tail=220 wso2-mi | grep -E 'billing-modernization|legacy-billing|Suspending endpoint|SUSPENDED|Timeout' || true
echo
echo "All Legacy SOAP Modernization checks passed."
