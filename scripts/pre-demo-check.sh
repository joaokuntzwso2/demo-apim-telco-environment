#!/usr/bin/env bash
set -uo pipefail

PASS=0
WARN=0
FAIL=0

pass() {
  printf 'PASS  %s\n' "$1"
  PASS=$((PASS + 1))
}

warn() {
  printf 'WARN  %s\n' "$1"
  WARN=$((WARN + 1))
}

fail() {
  printf 'FAIL  %s\n' "$1"
  FAIL=$((FAIL + 1))
}

check_http() {
  local label="$1"
  local url="$2"
  local insecure="${3:-false}"

  local args=(-fsS --max-time 10)

  if [[ "$insecure" == true ]]; then
    args=(-kfsS --max-time 10)
  fi

  if curl "${args[@]}" "$url" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label — $url"
  fi
}

echo
echo "=== Docker services ==="

COMPOSE=(
  docker compose
  -f docker-compose.yml
)

for file in \
  docker-compose.kafka.yml \
  docker-compose.opa.yml \
  docker-compose.mi.yml \
  docker-compose.mi.soap.yml \
  docker-compose.observability.yml \
  docker-compose.runtime-persistence.yml
do
  [[ -f "$file" ]] && COMPOSE+=(-f "$file")
done

IDS=()

while IFS= read -r id; do
  [[ -n "$id" ]] && IDS+=("$id")
done < <("${COMPOSE[@]}" ps -aq)

for id in "${IDS[@]}"; do
  [[ -z "$id" ]] && continue

  name="$(docker inspect "$id" --format '{{.Name}}' | sed 's#^/##')"
  state="$(docker inspect "$id" --format '{{.State.Status}}')"
  health="$(docker inspect "$id" \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"

  if [[ "$state" != running ]]; then
    fail "$name is $state"
  elif [[ "$health" == unhealthy ]]; then
    fail "$name is unhealthy"
  elif [[ "$health" == starting ]]; then
    warn "$name health check is still starting"
  else
    pass "$name is running"
  fi
done

echo
echo "=== Platform endpoints ==="

check_http "WSO2 API Manager" \
  "https://localhost:9443/services/Version" true

check_http "Telco backend" \
  "http://localhost:8081/health"

check_http "WSO2 MI risk service" \
  "http://localhost:8290/secure-transaction-risk/v1/health"

check_http "WSO2 MI billing modernization service" \
  "http://localhost:8290/billing-adjustments/v1/health"

check_http "WSO2 MI observability service" \
  "http://localhost:8290/observability/v1/health"

check_http "Gateway observer" \
  "http://localhost:8288/health"

check_http "Backend observer" \
  "http://localhost:8091/health"

check_http "Telco portal" \
  "http://localhost:8080"

check_http "Pipeline portal" \
  "http://localhost:8090"

check_http "Grafana" \
  "http://localhost:3000/api/health"

check_http "Prometheus" \
  "http://localhost:9090/-/ready"

check_http "Loki" \
  "http://localhost:3100/ready"

check_http "Tempo" \
  "http://localhost:3200/ready"

check_http "OPA" \
  "http://localhost:8181/health"

check_http "Redpanda" \
  "http://localhost:9644/v1/status/ready"

echo
echo "=== APIM application credentials ==="

RUNTIME_JSON="$(
  "${COMPOSE[@]}" run --rm --no-deps \
    --entrypoint cat \
    apim-bootstrapper \
    /workspace/state/runtime.json 2>/dev/null
)"

CONSUMER_KEY="$(jq -r '.application.consumerKey // empty' <<<"$RUNTIME_JSON")"
CONSUMER_SECRET="$(jq -r '.application.consumerSecret // empty' <<<"$RUNTIME_JSON")"

if [[ -z "$CONSUMER_KEY" || -z "$CONSUMER_SECRET" ]]; then
  fail "Regional Portal credentials are missing"
  ACCESS_TOKEN=""
else
  TOKEN_RESPONSE="$(
    curl -ksS \
      -u "${CONSUMER_KEY}:${CONSUMER_SECRET}" \
      --data-urlencode 'grant_type=client_credentials' \
      https://localhost:9443/oauth2/token
  )"

  ACCESS_TOKEN="$(jq -r '.access_token // empty' <<<"$TOKEN_RESPONSE")"

  if [[ -n "$ACCESS_TOKEN" ]]; then
    pass "Regional Portal access token"
  else
    fail "Regional Portal access token"
    jq . <<<"$TOKEN_RESPONSE"
  fi
fi

echo
echo "=== Managed API route ==="

if [[ -n "${ACCESS_TOKEN:-}" ]]; then
  CODE="$(
    curl -ksS \
      -o /tmp/pre-demo-risk-response.json \
      -w '%{http_code}' \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      https://localhost:8243/secure-transaction-risk/v1/health
  )"

  if [[ "$CODE" =~ ^2[0-9][0-9]$ ]]; then
    pass "APIM-managed risk API — HTTP $CODE"
  else
    warn "APIM-managed risk API — HTTP $CODE"
    cat /tmp/pre-demo-risk-response.json 2>/dev/null || true
    echo
  fi
fi

echo
echo "=== Observability data ==="

PROM_RESULT="$(
  curl -fsSG \
    http://localhost:9090/api/v1/query \
    --data-urlencode 'query=sum(telco_gateway_requests_total)' \
    2>/dev/null || true
)"

PROM_VALUE="$(
  jq -r '.data.result[0].value[1] // "0"' <<<"$PROM_RESULT" 2>/dev/null
)"

if awk "BEGIN { exit !(${PROM_VALUE:-0} > 0) }"; then
  pass "Prometheus contains gateway request metrics: ${PROM_VALUE}"
else
  warn "Prometheus has no gateway request metrics yet"
fi

echo
printf 'SUMMARY: PASS=%d WARN=%d FAIL=%d\n' "$PASS" "$WARN" "$FAIL"

if (( FAIL > 0 )); then
  exit 1
fi
