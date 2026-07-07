#!/usr/bin/env bash
set -euo pipefail
CID="${1:?Usage: $0 <correlation-id>}"
TIMELINE="$(mktemp)"
trap 'rm -f "$TIMELINE"' EXIT

echo '=== MI operator API ==='
curl -fsS "http://localhost:8290/observability/v1/transactions/${CID}" | tee "$TIMELINE" | jq .
TRACE_ID="$(jq -r '.traceId // empty' "$TIMELINE")"

echo
echo '=== Native APIM correlation log ==='
if docker compose version >/dev/null 2>&1; then DC=(docker compose); else DC=(docker-compose); fi
COMPOSE=("${DC[@]}" -f docker-compose.yml -f docker-compose.kafka.yml -f docker-compose.mi.yml)
[[ -f docker-compose.mi.soap.yml ]] && COMPOSE+=(-f docker-compose.mi.soap.yml)
COMPOSE+=(-f docker-compose.observability.yml)
APIM_ID="$("${COMPOSE[@]}" ps -q wso2-apim 2>/dev/null || true)"
if [[ -n "$APIM_ID" ]]; then
  docker exec "$APIM_ID" sh -lc "grep -F '$CID' /home/wso2carbon/wso2am-4.7.0/repository/logs/correlation.log 2>/dev/null || true"
else
  echo 'WSO2 API Manager container not found.'
fi

if [[ -n "$TRACE_ID" ]]; then
  echo
echo "=== Tempo trace ${TRACE_ID} ==="
  curl -fsS "http://localhost:3200/api/traces/${TRACE_ID}" \
    | jq '{batches: [.batches[] | {resource: .resource, scopes: [.scopeSpans[]? | {scope: .scope, spans: [.spans[]? | {name, spanId, parentSpanId, startTimeUnixNano, endTimeUnixNano, status, attributes}]}]}]}'
fi

echo
echo '=== Loki structured logs ==='
NOW_NS="$(( $(date +%s) * 1000000000 ))"
START_NS="$(( NOW_NS - 3600000000000 ))"
curl -G -fsS http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode "query={job=\"telco.structured\"} | json | correlationId=\"${CID}\"" \
  --data-urlencode "start=${START_NS}" \
  --data-urlencode "end=${NOW_NS}" \
  --data-urlencode 'limit=500' \
  | jq -r '.data.result[].values[]?[1]' | while IFS= read -r line; do echo "$line" | jq . 2>/dev/null || echo "$line"; done

echo
echo 'Grafana: http://localhost:3000/d/telco-e2e-observability'
echo "Dashboard variable: ${CID}"
