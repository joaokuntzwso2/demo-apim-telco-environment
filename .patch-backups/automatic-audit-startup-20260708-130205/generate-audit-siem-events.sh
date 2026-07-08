#!/usr/bin/env bash
set -euo pipefail

MI_URL="${MI_URL:-http://127.0.0.1:8290}"
APIM_GATEWAY_URL="${APIM_GATEWAY_URL:-https://127.0.0.1:8243}"
APIM_TOKEN_URL="${APIM_TOKEN_URL:-https://127.0.0.1:9443/oauth2/token}"
CORRELATION_PREFIX="${CORRELATION_PREFIX:-audit-siem-verify-$(date +%s)}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/audit-siem-events.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

post_event() {
  local event_type="$1" actor="$2" country="$3" resource="$4" action="$5" result="$6" details="$7" correlation="$8"
  local status
  status="$(curl -sS -o "$TMP_DIR/response.json" -w '%{http_code}' \
    -X POST "${MI_URL}/audit-events/v1/events" \
    -H 'Content-Type: application/json' \
    -H "X-Correlation-ID: ${correlation}" \
    --data "$(jq -cn \
      --arg eventType "$event_type" \
      --arg actor "$actor" \
      --arg country "$country" \
      --arg resource "$resource" \
      --arg action "$action" \
      --arg result "$result" \
      --argjson details "$details" \
      '{eventType:$eventType,actor:$actor,country:$country,resource:$resource,action:$action,result:$result,details:$details}')")"
  [[ "$status" == "202" ]] || { cat "$TMP_DIR/response.json" >&2; echo "Expected 202 for ${event_type}; got ${status}" >&2; exit 1; }
  jq -e '.accepted == true and (.auditId|length>0) and (.correlationId|length>0)' "$TMP_DIR/response.json" >/dev/null
  printf '[audit-events] %-32s accepted (%s)\n' "$event_type" "$correlation"
}

health_status="$(curl -sS -o "$TMP_DIR/health.json" -w '%{http_code}' "${MI_URL}/audit-events/v1/health")"
[[ "$health_status" == "200" ]] || { cat "$TMP_DIR/health.json" >&2; echo "MI audit health failed: HTTP ${health_status}" >&2; exit 1; }

invalid_status="$(curl -ksS -o "$TMP_DIR/invalid-auth.json" -w '%{http_code}' \
  -X POST "${APIM_GATEWAY_URL}/audit-events/v1/1.0.0/events" \
  -H 'Authorization: Bearer deliberately-invalid-audit-token' \
  -H 'Content-Type: application/json' \
  -H "X-Correlation-ID: ${CORRELATION_PREFIX}-failed-auth" \
  --data '{"eventType":"ADMINISTRATOR_ACTION","actor":"invalid-client","country":"BR","resource":"/audit-events/v1/events","action":"TEST","result":"SUCCESS"}')"
case "$invalid_status" in 401|403) ;; *) echo "Expected failed gateway authentication (401/403); got ${invalid_status}" >&2; cat "$TMP_DIR/invalid-auth.json" >&2; exit 1 ;; esac
post_event \
  FAILED_AUTHENTICATION \
  invalid-client \
  BR \
  /audit-events/v1/events \
  AUTHENTICATE_API_REQUEST \
  DENIED \
  "$(jq -cn --argjson status "$invalid_status" '{httpStatus:$status,credentialType:"Bearer",secretMaterialIncluded:false}')" \
  "${CORRELATION_PREFIX}-failed-auth"

# audit-events-bootstrapper-state-exec-v1
# The APIM bootstrapper is a one-shot Compose service. Use a temporary
# container to read the persistent bootstrap state volume.
bootstrapper_exec() {
  local executable="${1:-}"

  [[ -n "$executable" ]] || {
    echo "[audit-events][FAIL] bootstrapper_exec requires a command" >&2
    return 1
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

state_json="$(bootstrapper_exec cat /workspace/state/audit-siem-bootstrap-events.json 2>/dev/null)" || {
  echo "Could not read persisted Audit SIEM verifier credentials from the APIM bootstrap state volume." >&2
  exit 1
}
consumer_key="$(jq -r '.application.consumerKey // empty' <<<"$state_json")"
consumer_secret="$(jq -r '.application.consumerSecret // empty' <<<"$state_json")"
[[ -n "$consumer_key" && -n "$consumer_secret" ]] || {
  echo "Audit SIEM verifier credentials are absent from bootstrap state." >&2
  exit 1
}
curl -ksS -u "${consumer_key}:${consumer_secret}" \
  --data-urlencode grant_type=client_credentials \
  --data-urlencode scope=telco_audit_write \
  "${APIM_TOKEN_URL}" > "$TMP_DIR/audit-token.json"
audit_access_token="$(jq -r '.access_token // empty' "$TMP_DIR/audit-token.json")"
[[ -n "$audit_access_token" ]] || { cat "$TMP_DIR/audit-token.json" >&2; echo "Could not obtain the managed Audit API access token." >&2; exit 1; }
managed_audit_status="$(curl -ksS -o "$TMP_DIR/managed-audit.json" -w '%{http_code}' \
  -X POST "${APIM_GATEWAY_URL}/audit-events/v1/1.0.0/events" \
  -H "Authorization: Bearer ${audit_access_token}" \
  -H 'Content-Type: application/json' \
  -H "X-Correlation-ID: ${CORRELATION_PREFIX}-managed-audit" \
  --data '{"eventType":"ADMINISTRATOR_ACTION","actor":"audit-siem-verifier","country":"BR","resource":"TelcoAuditEventsAPI:1.0.0","action":"VALIDATE_MANAGED_AUDIT_API","result":"SUCCESS","details":{"invocationPath":"APIM_TO_MI","secretMaterialIncluded":false}}')"
[[ "$managed_audit_status" == "202" ]] || { cat "$TMP_DIR/managed-audit.json" >&2; echo "Managed Audit API invocation failed: HTTP ${managed_audit_status}" >&2; exit 1; }
jq -e '.accepted==true and (.auditId|length>0) and (.correlationId|length>0)' "$TMP_DIR/managed-audit.json" >/dev/null
printf '[audit-events] %-32s managed APIM invocation accepted\n' ADMINISTRATOR_ACTION

curl -ksS -u "${consumer_key}:${consumer_secret}" \
  --data-urlencode grant_type=client_credentials \
  --data-urlencode scope=opengateway_sim_swap \
  "${APIM_TOKEN_URL}" > "$TMP_DIR/sim-token.json"
sim_access_token="$(jq -r '.access_token // empty' "$TMP_DIR/sim-token.json")"
[[ -n "$sim_access_token" ]] || { cat "$TMP_DIR/sim-token.json" >&2; echo "Could not obtain the SIM Swap verification access token." >&2; exit 1; }

sim_success=0
sim_throttled=0
sim_total=0

invoke_sim_swap() {
  local request_number="$1"
  local response_file="$TMP_DIR/sim-${request_number}.json"
  local status

  status="$(
    curl -ksS \
      -o "$response_file" \
      -w '%{http_code}' \
      "${APIM_GATEWAY_URL}/open-gateway/sim-swap/v1/1.0.0/api/v1/open-gateway/sim-swap/%2B525512340001/risk?lookbackHours=168" \
      -H 'accept: application/json' \
      -H "Authorization: Bearer ${sim_access_token}" \
      -H 'X-Partner-Id: audit-siem-verifier' \
      -H "X-Correlation-ID: ${CORRELATION_PREFIX}-sim-${request_number}"
  )"

  sim_total=$((sim_total + 1))

  case "$status" in
    200|202)
      sim_success=$((sim_success + 1))
      ;;
    429)
      sim_throttled=$((sim_throttled + 1))
      ;;
    *)
      cat "$response_file" >&2
      echo \
        "Unexpected SIM Swap response on request ${request_number}: HTTP ${status}" \
        >&2
      exit 1
      ;;
  esac

  printf \
    '[audit-events] SIM_SWAP_REQUEST_%02d              HTTP %s\n' \
    "$request_number" \
    "$status"
}

# Fill the configured five-request subscription quota.
for i in $(seq 1 5); do
  invoke_sim_swap "$i"
done

# WSO2 Gateway invocation counters and Traffic Manager decisions are
# propagated asynchronously. Allow the decision to reach the Gateway.
if (( sim_throttled == 0 )); then
  printf \
    '%s\n' \
    '[audit-events] waiting for the Traffic Manager throttle decision...'

  sleep 3
fi

# Probe gradually instead of placing every request in one instantaneous
# burst. Stop immediately after observing the native Gateway 429.
for i in $(seq 6 20); do
  if (( sim_throttled >= 1 )); then
    break
  fi

  invoke_sim_swap "$i"

  if (( sim_throttled == 0 )); then
    sleep 1
  fi
done

if (( sim_throttled < 1 )); then
  printf \
    '[audit-events] SIM Swap summary: total=%s success=%s throttled=%s\n' \
    "$sim_total" \
    "$sim_success" \
    "$sim_throttled" \
    >&2

  echo \
    "TelcoSecurityAuditBurst did not produce HTTP 429 after ${sim_total} authenticated requests and a Traffic Manager propagation wait." \
    >&2

  exit 1
fi

printf \
  '[audit-events] %-32s native Gateway throttling observed; total=%s success=%s throttled=%s\n' \
  EXCESSIVE_SIM_SWAP_REQUESTS \
  "$sim_total" \
  "$sim_success" \
  "$sim_throttled"

post_event \
  EXCESSIVE_SIM_SWAP_REQUESTS \
  audit-siem-verifier \
  MX \
  /open-gateway/sim-swap/v1 \
  DETECT_REQUEST_BURST \
  THROTTLED \
  "$(jq -cn --argjson count "$sim_total" --argjson success "$sim_success" --argjson throttled "$sim_throttled" '{requestCount:$count,successfulResponses:$success,gatewayThrottledResponses:$throttled,windowSeconds:60,threshold:5}')" \
  "${CORRELATION_PREFIX}-sim-burst"

billing_status="$(curl -sS -o "$TMP_DIR/billing.json" -w '%{http_code}' \
  -X POST "${MI_URL}/billing-adjustments/v1/adjustments" \
  -H 'Content-Type: application/json' \
  -H 'X-Country-Code: BR' \
  -H "X-Correlation-ID: ${CORRELATION_PREFIX}-billing" \
  --data "$(jq -cn \
    --arg transactionId "AUDIT-BILL-$(date +%s)" \
    '{transactionId:$transactionId,accountId:"ACC-10001",subscriberId:"SUB-10001",amount:15.50,adjustmentAmount:15.50,currency:"USD",reasonCode:"SERVICE_CREDIT",requestedBy:"audit-siem-verifier",country:"BR"}')")"
case "$billing_status" in
  200|201|202) printf '[audit-events] %-32s business operation succeeded (HTTP %s)\n' BILLING_CORRECTION "$billing_status" ;;
  *) cat "$TMP_DIR/billing.json" >&2; echo "Billing correction failed: HTTP ${billing_status}" >&2; exit 1 ;;
esac

echo "[audit-events] Runtime event generation completed."
