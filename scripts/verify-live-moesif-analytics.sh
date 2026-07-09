#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

log() {
  printf '[verify-live-moesif] %s\n' "$*"
}

die() {
  printf '[verify-live-moesif][ERROR] %s\n' "$*" >&2
  exit 1
}

for command in docker curl jq python3; do
  command -v "$command" >/dev/null 2>&1 || die "Missing command: $command"
done

[[ "${TELCO_ENABLE_MOESIF_ANALYTICS:-false}" == "true" ]] \
  || die "TELCO_ENABLE_MOESIF_ANALYTICS must be true."
[[ -n "${MOESIF_APPLICATION_ID:-}" ]] \
  || die "MOESIF_APPLICATION_ID is required."
[[ -n "${MOESIF_MANAGEMENT_TOKEN:-}" ]] \
  || die "MOESIF_MANAGEMENT_TOKEN is required to prove remote ingestion."
MOESIF_ORG_ID="${MOESIF_ORG_ID:-~}"

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif docker-compose version >/dev/null 2>&1; then
  DC=(docker-compose)
else
  die "Docker Compose is required."
fi

COMPOSE_FILES=(docker-compose.yml)
for file in \
  docker-compose.kafka.yml \
  docker-compose.opa.yml \
  docker-compose.mi.yml \
  docker-compose.commercial.yml \
  docker-compose.mi.soap.yml \
  docker-compose.observability.yml \
  docker-compose.runtime-persistence.yml \
  docker-compose.moesif.yml
do
  [[ -f "$file" ]] && COMPOSE_FILES+=("$file")
done

COMPOSE=("${DC[@]}")
for file in "${COMPOSE_FILES[@]}"; do
  COMPOSE+=(-f "$file")
done

if [[ -z "${OBS_ACCESS_TOKEN:-}${OBS_AUTHORIZATION:-}" ]]; then
  log "Obtaining a Regional Portal client-credentials token from the bootstrap state."
  runtime_state="$(
    "${COMPOSE[@]}" run --rm --no-deps --entrypoint sh apim-bootstrapper \
      -lc 'cat /workspace/state/runtime.json' 2>/dev/null || true
  )"
  consumer_key="$(jq -r '.application.consumerKey // empty' <<<"$runtime_state" 2>/dev/null || true)"
  consumer_secret="$(jq -r '.application.consumerSecret // empty' <<<"$runtime_state" 2>/dev/null || true)"
  [[ -n "$consumer_key" && -n "$consumer_secret" ]] \
    || die "Could not read Regional Portal credentials from /workspace/state/runtime.json. Set OBS_ACCESS_TOKEN or OBS_AUTHORIZATION explicitly."
  OBS_ACCESS_TOKEN="$(
    curl -skS \
      -u "${consumer_key}:${consumer_secret}" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode grant_type=client_credentials \
      https://127.0.0.1:9443/oauth2/token \
      | jq -r '.access_token // empty'
  )"
  [[ -n "$OBS_ACCESS_TOKEN" ]] \
    || die "APIM did not issue a Regional Portal client-credentials token."
  export OBS_ACCESS_TOKEN
fi

log "Checking generated files and configuration."
grep -q 'type = "moesif"' services/wso2-apim/merge-moesif-config.sh
grep -q 'TelcoAnalyticsCustomDataProvider' services/wso2-apim/Dockerfile
grep -q '10 - Live Gateway Analytics' services/apim-bootstrapper/src/developer-experience-setup.js
grep -q '06 - Live Gateway Analytics' services/apim-bootstrapper/src/developer-experience-setup.js
grep -q '"name": "Telco Live Gateway Analytics - Moesif"' artifacts/postman/telco-live-moesif-analytics.postman_collection.json
python3 -m json.tool artifacts/postman/telco-live-moesif-analytics.postman_collection.json >/dev/null
bash -n scripts/generate-moesif-demo-events.sh
bash -n scripts/verify-live-moesif-analytics.sh
bash -n scripts/telco-demo-control.sh

apim_id="$("${COMPOSE[@]}" ps -q wso2-apim)"
[[ -n "$apim_id" ]] || die "wso2-apim is not running."

state="$(docker inspect "$apim_id" --format '{{.State.Status}}')"
health="$(docker inspect "$apim_id" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
[[ "$state" == "running" ]] || die "wso2-apim container state is ${state}."
[[ "$health" == "healthy" ]] || die "wso2-apim health is ${health}."

"${COMPOSE[@]}" exec -T wso2-apim \
  test -f /home/wso2carbon/wso2am-4.7.0/repository/components/lib/telco-analytics-custom-data-provider.jar
"${COMPOSE[@]}" exec -T wso2-apim \
  grep -q 'type = "moesif"' /home/wso2carbon/wso2am-4.7.0/repository/conf/deployment.toml
"${COMPOSE[@]}" exec -T wso2-apim \
  grep -q 'publisher.custom.data.provider.class' /home/wso2carbon/wso2am-4.7.0/repository/conf/deployment.toml

log "Running the repository's authoritative platform checks."
for verifier in \
  scripts/verify-apim-bootstrap.sh \
  scripts/verify-developer-experience.sh \
  scripts/verify-mi-resilience-config.sh \
  scripts/register-mi-service-catalog.sh \
  scripts/test-observability.sh
do
  [[ -x "$verifier" ]] || die "Required verifier is absent or not executable: $verifier"
  log "Running $verifier"
  "$verifier"
done

if [[ -x scripts/verify-oauth-consent-risk-controls.sh ]]; then
  log "Running scripts/verify-oauth-consent-risk-controls.sh"
  scripts/verify-oauth-consent-risk-controls.sh
fi

log "Generating unique successful, failed and rejected Gateway events."
scripts/generate-moesif-demo-events.sh

STATE_FILE="${MOESIF_DEMO_STATE_FILE:-.runtime/moesif-demo-events.json}"
[[ -s "$STATE_FILE" ]] || die "Moesif demo-event state was not written."

SEARCH_BASE="${MOESIF_MANAGEMENT_BASE_URL:-https://api.moesif.com/v1}"
SEARCH_WINDOW="${MOESIF_SEARCH_WINDOW:--15m}"
MAX_ATTEMPTS="${MOESIF_VERIFY_ATTEMPTS:-12}"
SLEEP_SECONDS="${MOESIF_VERIFY_INTERVAL_SECONDS:-5}"
SEARCH_RESULT=".runtime/moesif-search-result.json"
SEARCH_BODY=".runtime/moesif-search-body.json"

cat > "$SEARCH_BODY" <<'JSON'
{
  "size": 250,
  "sort": [
    {
      "request.time": "desc"
    }
  ]
}
JSON

urlencode() {
  jq -rn --arg value "$1" '$value|@uri'
}

org_encoded="$(urlencode "$MOESIF_ORG_ID")"
query_moesif() {
  local primary="${SEARCH_BASE%/}/search/${org_encoded}/search/events?from=${SEARCH_WINDOW}&to=now"
  local fallback="${SEARCH_BASE%/v1}/search/${org_encoded}/search/events?from=${SEARCH_WINDOW}&to=now"
  local code

  code="$(
    curl -sS \
      -o "$SEARCH_RESULT" \
      -w '%{http_code}' \
      -X POST "$primary" \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer ${MOESIF_MANAGEMENT_TOKEN}" \
      --data-binary "@${SEARCH_BODY}" || true
  )"
  if [[ "$code" == "200" ]]; then
    return 0
  fi

  code="$(
    curl -sS \
      -o "$SEARCH_RESULT" \
      -w '%{http_code}' \
      -X POST "$fallback" \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer ${MOESIF_MANAGEMENT_TOKEN}" \
      --data-binary "@${SEARCH_BODY}" || true
  )"
  [[ "$code" == "200" ]] || {
    log "Moesif Management API returned HTTP ${code}."
    cat "$SEARCH_RESULT" >&2 || true
    return 1
  }
}

validate_result() {
  python3 - "$STATE_FILE" "$SEARCH_RESULT" <<'PY'
import json
import sys

state = json.load(open(sys.argv[1]))
search = json.load(open(sys.argv[2]))

def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

all_dicts = list(walk(search))

common_required = [
    "telcoSchemaVersion",
    "telcoApi",
    "telcoOperation",
    "telcoHttpMethod",
    "telcoPartner",
    "telcoApplication",
    "telcoApiProduct",
    "telcoCountry",
    "telcoGateway",
    "telcoGatewayRegion",
    "telcoSubscriptionPolicy",
    "telcoCommercialPlan",
    "telcoCorrelationId",
    "telcoBillableUnits",
    "telcoTransactionOutcome",
]

native_required = [
    "apiName",
    "apiMethod",
    "apiResourceTemplate",
    "correlationId",
    "proxyResponseCode",
    "responseLatency",
]

def event_candidates(correlation_id):
    candidates = []
    for item in all_dicts:
        rendered = json.dumps(item, sort_keys=True)
        if correlation_id in rendered and "telcoSchemaVersion" in rendered:
            candidates.append((len(rendered), item, rendered))
    return sorted(candidates, key=lambda value: value[0], reverse=True)

missing = []
for expected in state["events"]:
    cid = expected["correlationId"]
    outcome = expected["outcome"]
    candidates = event_candidates(cid)
    if not candidates:
        missing.append(f"{outcome}: event with correlation ID {cid}")
        continue

    rendered = candidates[0][2]
    for key in common_required:
        if key not in rendered:
            missing.append(f"{outcome}: {key}")
    for key in native_required:
        if key not in rendered:
            missing.append(f"{outcome}: native {key}")
    if outcome in ("SUCCESS", "FAILED") and "backendLatency" not in rendered:
        missing.append(f"{outcome}: native backendLatency")
    if outcome not in rendered:
        missing.append(f"{outcome}: expected outcome value")
    if "SecureMobileTransactionsProduct" not in rendered:
        missing.append(f"{outcome}: API Product attribution")
    if "BR" not in rendered:
        missing.append(f"{outcome}: country attribution")

if missing:
    print("\n".join(missing))
    sys.exit(1)
PY
}

started="$(date +%s)"
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  log "Querying Moesif (${attempt}/${MAX_ATTEMPTS})."
  if query_moesif && validate_result; then
    elapsed="$(( $(date +%s) - started ))"
    log "PASS: successful, failed and rejected Gateway events are queryable in Moesif after ${elapsed}s."
    jq -r '.events[] | "  \(.outcome): \(.correlationId)"' "$STATE_FILE"
    exit 0
  fi
  sleep "$SLEEP_SECONDS"
done

die "Moesif did not expose all required event dimensions within $((MAX_ATTEMPTS * SLEEP_SECONDS)) seconds. Inspect ${SEARCH_RESULT} and the APIM container logs."
