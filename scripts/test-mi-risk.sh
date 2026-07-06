#!/usr/bin/env bash
set -euo pipefail

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
  else
    echo "Docker Compose was not found." >&2
    echo "Install/update Docker Desktop, or install a compatible docker-compose executable." >&2
    exit 1
  fi
  COMPOSE+=(-f docker-compose.yml -f docker-compose.mi.yml)
  echo "Using Docker Compose: ${COMPOSE[*]}"
}

detect_compose
MI_URL="${MI_URL:-http://localhost:8290/secure-transaction-risk/v1}"
APIM_TOKEN_URL="${APIM_TOKEN_URL:-https://localhost:9443/oauth2/token}"
APIM_GATEWAY_URL="${APIM_GATEWAY_URL:-https://localhost:8243/secure-transaction-risk/v1}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pretty_file() {
  local file="$1"
  if command -v jq >/dev/null 2>&1; then
    jq . "$file"
  else
    python3 -m json.tool "$file"
  fi
}

assert_json() {
  local file="$1"
  local expression="$2"
  local message="$3"
  python3 - "$file" "$expression" "$message" <<'PY'
import json, sys
path, expression, message = sys.argv[1:]
with open(path, encoding='utf-8') as stream:
    data = json.load(stream)
if not eval(expression, {'__builtins__': {}}, {'d': data, 'len': len}):
    raise SystemExit(f'ASSERTION FAILED: {message}\nPayload: {json.dumps(data, indent=2)}')
print(f'PASS: {message}')
PY
}

post_json() {
  local output="$1"
  local body="$2"
  shift 2
  curl -sS -o "$output" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    "$@" \
    -d "$body" \
    "${MI_URL}/assessments"
}

request_body='{
  "transactionId": "txn-2026-0001",
  "partnerId": "partner-fintech-mx",
  "msisdn": "+525512340001",
  "amount": 249.90,
  "currency": "MXN",
  "expectedCountry": "MX",
  "device": {
    "latitude": 19.4326,
    "longitude": -99.1332
  },
  "partialResponsePolicy": "ALLOW_DEGRADED"
}'

echo "1) MI health"
health="$TMP_DIR/health.json"
health_code="$(curl -sS -o "$health" -w '%{http_code}' "${MI_URL}/health")"
[[ "$health_code" == "200" ]] || { cat "$health"; exit 1; }
pretty_file "$health"
assert_json "$health" "d.get('status') == 'UP'" "MI orchestration API is healthy"

echo
echo "2) Normal orchestration: four services, full response"
normal="$TMP_DIR/normal.json"
normal_code="$(post_json "$normal" "$request_body" -H 'X-Correlation-ID: demo-normal-001')"
[[ "$normal_code" == "200" ]] || { cat "$normal"; exit 1; }
pretty_file "$normal"
assert_json "$normal" "d.get('partialResponse') is False" "normal response is complete"
assert_json "$normal" "len(d.get('evidence', [])) == 4" "all four evidence services were aggregated"
assert_json "$normal" "d.get('correlationId') == 'demo-normal-001'" "correlation ID is preserved"

echo
echo "3) High-risk deterministic scenario"
high="$TMP_DIR/high.json"
high_body='{
  "transactionId": "txn-high-risk-0009",
  "partnerId": "partner-fintech-mx",
  "msisdn": "+525512340009",
  "amount": 25000,
  "currency": "MXN",
  "expectedCountry": "MX",
  "device": {"latitude": 19.4326, "longitude": -99.1332},
  "partialResponsePolicy": "ALLOW_DEGRADED"
}'
high_code="$(post_json "$high" "$high_body" -H 'X-Correlation-ID: demo-high-risk-001')"
[[ "$high_code" == "200" ]] || { cat "$high"; exit 1; }
pretty_file "$high"
assert_json "$high" "d.get('decision') == 'DENY'" "suspended account plus high amount is denied"
assert_json "$high" "d.get('riskScore', 0) >= 70" "high-risk score reaches the deny threshold"

echo
echo "4) Transport failure: retry, endpoint suspension and degraded response"
partial="$TMP_DIR/partial.json"
started_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
partial_code="$(post_json "$partial" "$request_body" \
  -H 'X-Correlation-ID: demo-partial-001' \
  -H 'X-Demo-Fail-Service: sim-swap' \
  -H 'X-Demo-Fail-Mode: transport')"
ended_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
[[ "$partial_code" == "200" ]] || { cat "$partial"; exit 1; }
pretty_file "$partial"
echo "First failed invocation duration: $((ended_ms-started_ms)) ms"
assert_json "$partial" "d.get('partialResponse') is True" "ALLOW_DEGRADED returns a partial decision"
assert_json "$partial" "'sim-swap' in d.get('unavailableServices', [])" "SIM Swap is marked unavailable"
assert_json "$partial" "d.get('decision') != 'ALLOW'" "missing critical evidence never yields unconditional ALLOW"

echo
echo "4b) Immediate repeat while both failover children are suspended"
fast="$TMP_DIR/fast-fail.json"
started_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
fast_code="$(post_json "$fast" "$request_body" \
  -H 'X-Correlation-ID: demo-circuit-open-001' \
  -H 'X-Demo-Fail-Service: sim-swap' \
  -H 'X-Demo-Fail-Mode: transport')"
ended_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
[[ "$fast_code" == "200" ]] || { cat "$fast"; exit 1; }
pretty_file "$fast"
echo "Circuit-open invocation duration: $((ended_ms-started_ms)) ms"
assert_json "$fast" "'sim-swap' in d.get('unavailableServices', [])" "suspended endpoint fails fast into the partial policy"

echo "Waiting 6 seconds for the initial 5-second suspension window to expire..."
sleep 6

echo
echo "5) Timeout: OSS delay exceeds each 1500 ms endpoint timeout"
timeout="$TMP_DIR/timeout.json"
timeout_code="$(post_json "$timeout" "$request_body" \
  -H 'X-Correlation-ID: demo-timeout-001' \
  -H 'X-Demo-Delay-Service: oss' \
  -H 'X-Demo-Delay-Ms: 4000')"
[[ "$timeout_code" == "200" ]] || { cat "$timeout"; exit 1; }
pretty_file "$timeout"
assert_json "$timeout" "'oss' in d.get('unavailableServices', [])" "OSS timeout is normalized as unavailable evidence"

echo
echo "6) FAIL_CLOSED partial-response policy returns HTTP 503"
closed="$TMP_DIR/fail-closed.json"
closed_body='{
  "transactionId": "txn-fail-closed-001",
  "partnerId": "partner-fintech-mx",
  "msisdn": "+525512340001",
  "amount": 249.90,
  "currency": "MXN",
  "expectedCountry": "MX",
  "device": {"latitude": 19.4326, "longitude": -99.1332},
  "partialResponsePolicy": "FAIL_CLOSED"
}'
closed_code="$(post_json "$closed" "$closed_body" \
  -H 'X-Correlation-ID: demo-fail-closed-001' \
  -H 'X-Demo-Fail-Service: crm' \
  -H 'X-Demo-Fail-Mode: transport')"
[[ "$closed_code" == "503" ]] || { echo "Expected 503, received $closed_code"; cat "$closed"; exit 1; }
pretty_file "$closed"
assert_json "$closed" "d.get('status') == 503" "FAIL_CLOSED returns a standardized 503 problem"
assert_json "$closed" "'crm' in d.get('unavailableServices', [])" "failed CRM evidence is identified"

echo
echo "7) APIM façade using the generated application credentials"
state_json="$("${COMPOSE[@]}" exec -T demo-portal \
  cat /workspace/apim-portal-state/runtime.json 2>/dev/null || true)"

if [[ -z "$state_json" ]]; then
  echo "Could not read APIM runtime state; all direct MI assertions passed."
else
  consumer_key="$(printf '%s' "$state_json" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["application"]["consumerKey"])')"
  consumer_secret="$(printf '%s' "$state_json" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["application"]["consumerSecret"])')"

  token_json="$(curl -ksS -u "${consumer_key}:${consumer_secret}" \
    -d 'grant_type=client_credentials' "$APIM_TOKEN_URL")"
  access_token="$(printf '%s' "$token_json" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["access_token"])')"

  through_apim="$TMP_DIR/through-apim.json"
  apim_code="$(curl -ksS -o "$through_apim" -w '%{http_code}' \
    -H "Authorization: Bearer ${access_token}" \
    -H 'Content-Type: application/json' \
    -H 'X-Correlation-ID: demo-through-apim-001' \
    -d "$request_body" \
    "${APIM_GATEWAY_URL}/assessments")"
  [[ "$apim_code" == "200" ]] || { cat "$through_apim"; exit 1; }
  pretty_file "$through_apim"
  assert_json "$through_apim" "d.get('correlationId') == 'demo-through-apim-001'" "request traverses APIM and MI"
fi

echo
echo "8) Recent MI logs: correlation, fallback, failover and Service Catalog"
"${COMPOSE[@]}" logs --tail=220 wso2-mi | \
  grep -E 'risk-assessment|risk-adapter|SUSPENDED|Suspending endpoint|Timeout|correlation|Successfully updated the service catalog' || true

echo
echo "All Secure Transaction Risk Assessment checks passed."
