#!/usr/bin/env bash
set -Eeuo pipefail

APIM_BASE_URL="${APIM_BASE_URL:-https://wso2-apim:9443}"
GATEWAY_URL="${GATEWAY_URL:-http://telco-gateway-observer:8089}"
STATE_FILE="${STATE_FILE:-/state/runtime.json}"

TOKEN_REFRESH_SECONDS="${TOKEN_REFRESH_SECONDS:-900}"
READY_INTERVAL_SECONDS="${READY_INTERVAL_SECONDS:-5}"

TRAFFIC_PHASE_MIN_SECONDS="${TRAFFIC_PHASE_MIN_SECONDS:-45}"
TRAFFIC_PHASE_MAX_SECONDS="${TRAFFIC_PHASE_MAX_SECONDS:-120}"
TRAFFIC_MAX_REQUESTS_PER_MINUTE="${TRAFFIC_MAX_REQUESTS_PER_MINUTE:-45}"

ACCESS_TOKEN=""
TOKEN_ACQUIRED_AT=0
SEQUENCE=0

CURRENT_PHASE=""
PHASE_ENDS_AT=0

RATE_WINDOW_STARTED_AT="$(date +%s)"
RATE_WINDOW_REQUESTS=0

log() {
  printf '[continuous-traffic] %s\n' "$*"
}

random_between() {
  local minimum="$1"
  local maximum="$2"

  printf '%d\n' \
    "$((minimum + RANDOM % (maximum - minimum + 1)))"
}

wait_for_runtime_state() {
  local attempt=0

  until [[ -s "$STATE_FILE" ]] &&
    jq -e '
      .application.consumerKey and
      .application.consumerSecret
    ' "$STATE_FILE" >/dev/null 2>&1
  do
    attempt=$((attempt + 1))

    if (( attempt == 1 || attempt % 12 == 0 )); then
      log "Waiting for application credentials in ${STATE_FILE}"
    fi

    sleep "$READY_INTERVAL_SECONDS"
  done
}

obtain_token() {
  local consumer_key consumer_secret response token

  wait_for_runtime_state

  consumer_key="$(
    jq -r '.application.consumerKey // empty' "$STATE_FILE"
  )"

  consumer_secret="$(
    jq -r '.application.consumerSecret // empty' "$STATE_FILE"
  )"

  response="$(
    curl -ksS \
      --connect-timeout 5 \
      --max-time 15 \
      -u "${consumer_key}:${consumer_secret}" \
      --data-urlencode 'grant_type=client_credentials' \
      "${APIM_BASE_URL}/oauth2/token" \
      2>/dev/null || true
  )"

  token="$(
    jq -r '.access_token // empty' \
      <<<"$response" 2>/dev/null || true
  )"

  if [[ -z "$token" ]]; then
    log "$(
      jq -r '
        .error_description //
        .error //
        "APIM token endpoint is not ready"
      ' <<<"$response" 2>/dev/null ||
      echo "APIM token endpoint is not ready"
    )"

    return 1
  fi

  ACCESS_TOKEN="$token"
  TOKEN_ACQUIRED_AT="$(date +%s)"

  log "Application token obtained"
}

token_needs_refresh() {
  local now

  now="$(date +%s)"

  (( now - TOKEN_ACQUIRED_AT >= TOKEN_REFRESH_SECONDS ))
}

wait_for_managed_route() {
  local code attempt=0

  rm -f /tmp/continuous-traffic-ready

  while true; do
    if [[ -z "$ACCESS_TOKEN" ]] || token_needs_refresh; then
      obtain_token || {
        sleep "$READY_INTERVAL_SECONDS"
        continue
      }
    fi

    code="$(
      curl -sS \
        --connect-timeout 3 \
        --max-time 8 \
        -o /tmp/continuous-traffic-health.json \
        -w '%{http_code}' \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "${GATEWAY_URL}/secure-transaction-risk/v1/health" \
        2>/dev/null || true
    )"

    if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
      touch /tmp/continuous-traffic-ready
      log "Managed APIM route is ready"
      return 0
    fi

    if [[ "$code" == "401" ]]; then
      ACCESS_TOKEN=""
    fi

    attempt=$((attempt + 1))

    if (( attempt == 1 || attempt % 12 == 0 )); then
      log "Waiting for managed APIM route; HTTP ${code:-unavailable}"
    fi

    sleep "$READY_INTERVAL_SECONDS"
  done
}

select_new_phase() {
  local roll duration now

  roll="$(random_between 1 100)"
  now="$(date +%s)"

  # Approximately:
  #   quiet  = 25%
  #   normal = 55%
  #   busy   = 20%
  if (( roll <= 25 )); then
    CURRENT_PHASE="quiet"
  elif (( roll <= 80 )); then
    CURRENT_PHASE="normal"
  else
    CURRENT_PHASE="busy"
  fi

  duration="$(
    random_between \
      "$TRAFFIC_PHASE_MIN_SECONDS" \
      "$TRAFFIC_PHASE_MAX_SECONDS"
  )"

  PHASE_ENDS_AT=$((now + duration))

  log "New phase=${CURRENT_PHASE}; duration=${duration}s"
}

ensure_current_phase() {
  local now

  now="$(date +%s)"

  if [[ -z "$CURRENT_PHASE" ]] ||
    (( now >= PHASE_ENDS_AT ))
  then
    select_new_phase
  fi
}

select_cycle_pattern() {
  local roll

  roll="$(random_between 1 100)"

  case "$CURRENT_PHASE" in
    quiet)
      # Average: approximately 0.8 requests per cycle.
      if (( roll <= 35 )); then
        CYCLE_REQUESTS=0
      elif (( roll <= 85 )); then
        CYCLE_REQUESTS=1
      else
        CYCLE_REQUESTS=2
      fi

      CYCLE_DELAY="$(random_between 5 10)"
      ;;

    normal)
      # Average: approximately 1.4 requests per cycle.
      if (( roll <= 10 )); then
        CYCLE_REQUESTS=0
      elif (( roll <= 60 )); then
        CYCLE_REQUESTS=1
      elif (( roll <= 90 )); then
        CYCLE_REQUESTS=2
      else
        CYCLE_REQUESTS=3
      fi

      CYCLE_DELAY="$(random_between 2 6)"
      ;;

    busy)
      # Small, bounded peaks—never more than four requests.
      if (( roll <= 15 )); then
        CYCLE_REQUESTS=1
      elif (( roll <= 60 )); then
        CYCLE_REQUESTS=2
      elif (( roll <= 90 )); then
        CYCLE_REQUESTS=3
      else
        CYCLE_REQUESTS=4
      fi

      CYCLE_DELAY="$(random_between 2 4)"
      ;;

    *)
      CYCLE_REQUESTS=1
      CYCLE_DELAY=5
      ;;
  esac
}

enforce_rate_limit() {
  local now elapsed remaining

  now="$(date +%s)"
  elapsed=$((now - RATE_WINDOW_STARTED_AT))

  if (( elapsed >= 60 )); then
    RATE_WINDOW_STARTED_AT="$now"
    RATE_WINDOW_REQUESTS=0
    return 0
  fi

  if (( RATE_WINDOW_REQUESTS < TRAFFIC_MAX_REQUESTS_PER_MINUTE )); then
    return 0
  fi

  remaining=$((60 - elapsed))

  if (( remaining > 0 )); then
    log \
      "Rate ceiling reached: " \
      "${TRAFFIC_MAX_REQUESTS_PER_MINUTE}/min; " \
      "pausing ${remaining}s"

    sleep "$remaining"
  fi

  RATE_WINDOW_STARTED_AT="$(date +%s)"
  RATE_WINDOW_REQUESTS=0
}

send_transaction() {
  local country currency partner latitude longitude
  local correlation_id trace_id span_id amount body code

  enforce_rate_limit

  SEQUENCE=$((SEQUENCE + 1))
  RATE_WINDOW_REQUESTS=$((RATE_WINDOW_REQUESTS + 1))

  case $((SEQUENCE % 4)) in
    0)
      country="BR"
      currency="BRL"
      partner="partner-br-retail"
      latitude="-23.5505"
      longitude="-46.6333"
      ;;
    1)
      country="MX"
      currency="MXN"
      partner="partner-mx-fintech"
      latitude="19.4326"
      longitude="-99.1332"
      ;;
    2)
      country="CO"
      currency="COP"
      partner="partner-co-commerce"
      latitude="4.7110"
      longitude="-74.0721"
      ;;
    3)
      country="AR"
      currency="ARS"
      partner="partner-ar-wallet"
      latitude="-34.6037"
      longitude="-58.3816"
      ;;
  esac

  correlation_id="$(cat /proc/sys/kernel/random/uuid)"
  trace_id="$(openssl rand -hex 16)"
  span_id="$(openssl rand -hex 8)"

  amount="$(
    printf '%d.%02d' \
      "$((50 + RANDOM % 450))" \
      "$((RANDOM % 100))"
  )"

  body="$(
    jq -nc \
      --arg transactionId \
        "TX-LIVE-${SEQUENCE}-${correlation_id}" \
      --arg partnerId "$partner" \
      --arg msisdn \
        "+5511999$(printf '%04d' "$((RANDOM % 10000))")" \
      --arg currency "$currency" \
      --arg expectedCountry "$country" \
      --argjson amount "$amount" \
      --argjson latitude "$latitude" \
      --argjson longitude "$longitude" \
      '{
        transactionId: $transactionId,
        partnerId: $partnerId,
        msisdn: $msisdn,
        amount: $amount,
        currency: $currency,
        expectedCountry: $expectedCountry,
        device: {
          latitude: $latitude,
          longitude: $longitude
        },
        partialResponsePolicy: "ALLOW_DEGRADED"
      }'
  )"

  code="$(
    curl -sS \
      --connect-timeout 3 \
      --max-time 20 \
      -o /tmp/continuous-traffic-response.json \
      -w '%{http_code}' \
      -X POST \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "activityid: ${correlation_id}" \
      -H "traceparent: 00-${trace_id}-${span_id}-01" \
      -H "x-country-code: ${country}" \
      -H "x-partner-id: ${partner}" \
      -H 'x-application-name: regional-portal' \
      --data "$body" \
      "${GATEWAY_URL}/secure-transaction-risk/v1/assessments" \
      2>/dev/null || true
  )"

  if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    log \
      "phase=${CURRENT_PHASE}" \
      "transaction=${SEQUENCE}" \
      "country=${country}" \
      "HTTP ${code}"

    return 0
  fi

  log \
    "phase=${CURRENT_PHASE}" \
    "transaction=${SEQUENCE}" \
    "country=${country}" \
    "HTTP ${code:-unavailable}"

  if [[ "$code" == "401" ]]; then
    ACCESS_TOKEN=""
  elif [[ "$code" == "404" ]]; then
    wait_for_managed_route
  fi

  return 1
}

log \
  "Starting bounded natural demo traffic;" \
  "maximum=${TRAFFIC_MAX_REQUESTS_PER_MINUTE}/min"

wait_for_managed_route
select_new_phase

while true; do
  if [[ -z "$ACCESS_TOKEN" ]] || token_needs_refresh; then
    obtain_token || {
      sleep "$READY_INTERVAL_SECONDS"
      continue
    }
  fi

  ensure_current_phase
  select_cycle_pattern

  if (( CYCLE_REQUESTS == 0 )); then
    log \
      "phase=${CURRENT_PHASE}" \
      "quiet cycle; next cycle in ${CYCLE_DELAY}s"
  else
    log \
      "phase=${CURRENT_PHASE}" \
      "cycle=${CYCLE_REQUESTS} transactions;" \
      "next cycle in ${CYCLE_DELAY}s"

    for ((index = 1; index <= CYCLE_REQUESTS; index++)); do
      send_transaction || true

      # Small spacing inside a cycle avoids a perfectly vertical burst.
      if (( index < CYCLE_REQUESTS )); then
        jitter_ms="$(random_between 150 650)"
        sleep "0.$(printf '%03d' "$jitter_ms")"
      fi
    done
  fi

  sleep "$CYCLE_DELAY"
done
