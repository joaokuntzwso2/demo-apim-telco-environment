#!/usr/bin/env bash
set -Eeuo pipefail

GATEWAY_URL="${MOESIF_DEMO_GATEWAY_URL:-http://localhost:8288}"
API_PATH="${MOESIF_DEMO_API_PATH:-/secure-transaction-risk/v1/assessments}"
OUTPUT_FILE="${MOESIF_DEMO_STATE_FILE:-.runtime/moesif-demo-events.json}"

for command in curl jq openssl; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "[moesif-events][ERROR] Missing command: $command" >&2
    exit 1
  }
done

AUTH_HEADERS=()
if [[ -n "${OBS_ACCESS_TOKEN:-}" ]]; then
  AUTH_HEADERS=(-H "Authorization: Bearer ${OBS_ACCESS_TOKEN}")
elif [[ -n "${OBS_AUTHORIZATION:-}" ]]; then
  AUTH_HEADERS=(-H "Authorization: ${OBS_AUTHORIZATION}")
else
  echo "[moesif-events][ERROR] Set OBS_ACCESS_TOKEN or OBS_AUTHORIZATION so successful and downstream-failure calls can pass APIM authentication." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/telco-moesif-events.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

new_id() {
  local prefix="$1"
  printf '%s-%s-%s\n' "$prefix" "$(date +%s)" "$(openssl rand -hex 8)"
}

invoke() {
  local outcome="$1"
  local cid="$2"
  local auth_mode="$3"
  local source="$4"
  local billable_units="$5"
  local response="$TMP_DIR/${outcome,,}.json"
  local trace_id span_id code
  trace_id="$(openssl rand -hex 16)"
  span_id="$(openssl rand -hex 8)"

  local headers=(
    -H 'Content-Type: application/json'
    -H "X-Correlation-ID: ${cid}"
    -H "activityID: ${cid}"
    -H "traceparent: 00-${trace_id}-${span_id}-01"
    -H 'X-Partner-ID: partner-br-fintech'
    -H 'X-Country-Code: BR'
    -H 'organization-id: BR'
    -H "source-id: ${source}"
    -H 'application-id: regional-portal'
    -H 'X-Application-UUID: regional-portal-demo'
    -H 'X-Subscription-ID: regional-portal-secure-risk'
    -H 'X-Subscription-Policy: TelcoOpenGatewayTrustPremium'
    -H 'X-Commercial-Plan: Open Gateway Trust Premium'
    -H "X-Billable-Units: ${billable_units}"
    -H 'X-Partial-Response-Policy: ALLOW_DEGRADED'
  )

  if [[ "$auth_mode" == "authenticated" ]]; then
    headers+=("${AUTH_HEADERS[@]}")
  fi

  code="$(
    curl -skS \
      -o "$response" \
      -w '%{http_code}' \
      -X POST "${GATEWAY_URL}${API_PATH}" \
      "${headers[@]}" \
      -d "{
        \"transactionId\":\"TX-${outcome}-$(date +%s)-$RANDOM\",
        \"subscriberId\":\"SUB-1001\",
        \"msisdn\":\"+5511999990001\",
        \"amount\":1250,
        \"country\":\"BR\",
        \"partialResponsePolicy\":\"ALLOW_DEGRADED\"
      }" || true
  )"

  case "$outcome" in
    SUCCESS|FAILED)
      [[ "$code" =~ ^[23][0-9][0-9]$ ]] || {
        echo "[moesif-events][ERROR] ${outcome} invocation was expected to complete through the authenticated APIM/MI flow; HTTP ${code}." >&2
        cat "$response" >&2 || true
        exit 1
      }
      ;;
    REJECTED)
      [[ "$code" =~ ^(400|401|403|404|405|406|415|429)$ ]] || {
        echo "[moesif-events][ERROR] Expected a Gateway rejection, received HTTP ${code}." >&2
        cat "$response" >&2 || true
        exit 1
      }
      ;;
  esac

  jq -n \
    --arg outcome "$outcome" \
    --arg correlationId "$cid" \
    --arg traceId "$trace_id" \
    --arg httpStatus "$code" \
    --arg responseFile "$response" \
    '{
      outcome: $outcome,
      correlationId: $correlationId,
      traceId: $traceId,
      httpStatus: ($httpStatus | tonumber),
      responseFile: $responseFile
    }'
}

SUCCESS_CID="$(new_id moesif-success)"
FAILED_CID="$(new_id moesif-failed)"
REJECTED_CID="$(new_id moesif-rejected)"

success_event="$(invoke SUCCESS "$SUCCESS_CID" authenticated partner-success 1)"
failed_event="$(invoke FAILED "$FAILED_CID" authenticated partner-billing-fail 0)"
rejected_event="$(invoke REJECTED "$REJECTED_CID" rejected partner-rejected 0)"

jq -n \
  --arg generatedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg gatewayUrl "$GATEWAY_URL" \
  --arg apiPath "$API_PATH" \
  --argjson success "$success_event" \
  --argjson failed "$failed_event" \
  --argjson rejected "$rejected_event" \
  '{
    generatedAt: $generatedAt,
    gatewayUrl: $gatewayUrl,
    apiPath: $apiPath,
    events: [$success, $failed, $rejected]
  }' > "$OUTPUT_FILE"

echo "[moesif-events] Generated:"
jq -r '.events[] | "  \(.outcome): HTTP \(.httpStatus), correlationId=\(.correlationId)"' "$OUTPUT_FILE"
echo "[moesif-events] State: $OUTPUT_FILE"
