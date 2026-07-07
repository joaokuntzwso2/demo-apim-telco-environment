#!/usr/bin/env bash
set -euo pipefail

require() { command -v "$1" >/dev/null || { echo "Missing command: $1" >&2; exit 1; }; }
require curl
require jq
require openssl

AUTH_HEADERS=()
if [[ -n "${OBS_ACCESS_TOKEN:-}" ]]; then
  AUTH_HEADERS=(-H "Authorization: Bearer ${OBS_ACCESS_TOKEN}")
elif [[ -n "${OBS_AUTHORIZATION:-}" ]]; then
  AUTH_HEADERS=(-H "Authorization: ${OBS_AUTHORIZATION}")
fi

wait_url() {
  local url="$1"
  for _ in $(seq 1 60); do
    curl -fsS "$url" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "FAIL: endpoint is not ready: $url" >&2
  return 1
}

prom_query() {
  local query="$1"
  curl -fsS http://localhost:9090/api/v1/query --get --data-urlencode "query=${query}"
}

for url in \
  http://localhost:8088/health \
  http://localhost:8091/health \
  http://localhost:8288/health \
  http://localhost:9470/health \
  http://localhost:9090/-/ready \
  http://localhost:3000/api/health \
  http://localhost:3100/ready \
  http://localhost:3200/ready; do
  wait_url "$url"
done

curl -fsS http://localhost:8290/observability/v1/health \
  | jq -e '.status == "UP" or .status == "DEGRADED"' >/dev/null

MANAGED_HEALTH_CODE="$(curl -sk -o /tmp/telco-managed-observability-health.json -w '%{http_code}' \
  "${AUTH_HEADERS[@]}" \
  http://localhost:8288/observability/v1/health || true)"
if [[ -n "${OBS_ACCESS_TOKEN:-}${OBS_AUTHORIZATION:-}" ]]; then
  [[ "$MANAGED_HEALTH_CODE" =~ ^2[0-9][0-9]$ ]] || {
    echo "FAIL: managed TelcoObservabilityAPI health returned HTTP ${MANAGED_HEALTH_CODE}." >&2
    cat /tmp/telco-managed-observability-health.json >&2 || true
    exit 1
  }
else
  [[ "$MANAGED_HEALTH_CODE" =~ ^(2[0-9][0-9]|401|403)$ ]] || {
    echo "FAIL: APIM did not expose the managed observability route; HTTP ${MANAGED_HEALTH_CODE}." >&2
    cat /tmp/telco-managed-observability-health.json >&2 || true
    exit 1
  }
  if [[ "$MANAGED_HEALTH_CODE" =~ ^(401|403)$ ]]; then
    echo 'INFO: managed observability route exists and is secured; provide OBS_ACCESS_TOKEN for an authenticated 2xx proof.'
  fi
fi
rm -f /tmp/telco-managed-observability-health.json

CID="e2e-obs-$(date +%s)-$RANDOM"
TRACE_ID="$(openssl rand -hex 16)"
SPAN_ID="$(openssl rand -hex 8)"
PATH_TO_CALL="${OBS_TEST_PATH:-/secure-transaction-risk/v1/assessments}"
BODY="${OBS_TEST_BODY:-{\"transactionId\":\"TX-OBS-001\",\"subscriberId\":\"SUB-1001\",\"msisdn\":\"+5511999990001\",\"amount\":1250,\"country\":\"BR\",\"partialResponsePolicy\":\"ALLOW_DEGRADED\"}}"
RESPONSE_FILE="$(mktemp)"
TIMELINE_FILE="$(mktemp)"
trap 'rm -f "$RESPONSE_FILE" "$TIMELINE_FILE"' EXIT

HTTP_CODE="$(curl -sk -o "$RESPONSE_FILE" -w '%{http_code}' \
  -X POST "http://localhost:8288${PATH_TO_CALL}" \
  "${AUTH_HEADERS[@]}" \
  -H 'Content-Type: application/json' \
  -H "activityID: ${CID}" \
  -H "X-Correlation-ID: ${CID}" \
  -H "traceparent: 00-${TRACE_ID}-${SPAN_ID}-01" \
  -H 'organization-id: BR' \
  -H 'source-id: partner-billing-fail' \
  -H 'application-id: observability-test' \
  -d "$BODY" || true)"

echo "Managed call returned HTTP ${HTTP_CODE}"
cat "$RESPONSE_FILE" | jq . 2>/dev/null || cat "$RESPONSE_FILE"
if [[ ! "$HTTP_CODE" =~ ^[1-3][0-9][0-9]$ ]]; then
  echo "FAIL: managed APIM invocation failed with HTTP ${HTTP_CODE}." >&2
  echo "Provide OBS_ACCESS_TOKEN when the API is secured, or adjust OBS_TEST_PATH/OBS_TEST_BODY." >&2
  exit 1
fi

required_stages='["gateway","apim","mi","backend","kafka","analytics","billing"]'
for _ in $(seq 1 90); do
  if curl -fsS "http://localhost:8088/v1/transactions/${CID}" >"$TIMELINE_FILE" 2>/dev/null; then
    if jq -e --argjson required "$required_stages" '
      ([.events[].stage] | unique) as $actual
      | all($required[]; $actual | index(.) != null)
      and ([.events[] | select(.stage == "billing" and .billingStatus == "FAILED")] | length > 0)
      and (.traceId != null)
    ' "$TIMELINE_FILE" >/dev/null; then
      break
    fi
  fi
  sleep 1
done

jq . "$TIMELINE_FILE"
jq -e --argjson required "$required_stages" '
  ([.events[].stage] | unique) as $actual
  | all($required[]; $actual | index(.) != null)
' "$TIMELINE_FILE" >/dev/null || {
  echo "FAIL: the transaction timeline did not reach every required stage." >&2
  exit 1
}

OBSERVED_TRACE_ID="$(jq -r '.traceId // empty' "$TIMELINE_FILE")"
[[ "$OBSERVED_TRACE_ID" == "$TRACE_ID" ]] || {
  echo "FAIL: expected W3C trace ID ${TRACE_ID}, observed ${OBSERVED_TRACE_ID:-<none>}." >&2
  exit 1
}

for job in telco-gateway-observer wso2-apim-correlation wso2-mi telco-backend-observer telco-observability kafka-exporter otel-collector; do
  prom_query "up{job=\"${job}\"}" | jq -e '.status == "success" and ([.data.result[].value[1] | tonumber] | any(. == 1))' >/dev/null || {
    echo "FAIL: Prometheus target ${job} is not UP." >&2
    exit 1
  }
done

for metric in \
  telco_gateway_requests_total \
  telco_apim_requests_total \
  telco_backend_request_duration_seconds_count \
  telco_billing_records_total \
  kafka_consumergroup_lag; do
  prom_query "$metric" | jq -e '.status == "success" and (.data.result | length > 0)' >/dev/null || {
    echo "FAIL: metric ${metric} has no series." >&2
    exit 1
  }
done

for _ in $(seq 1 30); do
  TEMPO_CODE="$(curl -sS -o /tmp/telco-tempo-trace.json -w '%{http_code}' "http://localhost:3200/api/traces/${TRACE_ID}" || true)"
  [[ "$TEMPO_CODE" == "200" ]] && break
  sleep 1
done
[[ "${TEMPO_CODE:-}" == "200" ]] || { echo "FAIL: Tempo has no trace ${TRACE_ID}." >&2; exit 1; }
jq -e '.batches | length > 0' /tmp/telco-tempo-trace.json >/dev/null
rm -f /tmp/telco-tempo-trace.json

NOW_NS="$(( $(date +%s) * 1000000000 ))"
START_NS="$(( NOW_NS - 600000000000 ))"
LOKI_QUERY="{job=\"telco.structured\"} | json | correlationId=\"${CID}\""
for _ in $(seq 1 30); do
  LOKI_COUNT="$(curl -G -fsS http://localhost:3100/loki/api/v1/query_range \
    --data-urlencode "query=${LOKI_QUERY}" \
    --data-urlencode "start=${START_NS}" \
    --data-urlencode "end=${NOW_NS}" \
    --data-urlencode 'limit=100' \
    | jq '[.data.result[].values[]] | length' 2>/dev/null || echo 0)"
  (( LOKI_COUNT > 0 )) && break
  sleep 1
done
(( ${LOKI_COUNT:-0} > 0 )) || { echo "FAIL: Loki has no structured log for ${CID}." >&2; exit 1; }

./scripts/test-observability-circuit.sh

echo "PASS: ${CID} reached Gateway, APIM, MI, BSS/OSS backend, Kafka, analytics and failed billing."
echo "PASS: Prometheus targets/metrics, Tempo trace ${TRACE_ID}, and Loki structured logs are queryable."
echo "Trace it again with: ./scripts/trace-transaction.sh ${CID}"
