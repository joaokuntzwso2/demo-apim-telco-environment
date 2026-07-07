#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif docker-compose version >/dev/null 2>&1; then
  DC=(docker-compose)
else
  echo 'Docker Compose is required.' >&2
  exit 1
fi

COMPOSE=(-f docker-compose.yml -f docker-compose.kafka.yml -f docker-compose.mi.yml)
[[ -f docker-compose.mi.soap.yml ]] && COMPOSE+=(-f docker-compose.mi.soap.yml)
COMPOSE+=(-f docker-compose.observability.yml)

for url in https://localhost:9443/services/Version http://localhost:8290/observability/v1/health; do
  echo "Waiting for ${url}"
  for _ in $(seq 1 120); do
    if [[ "$url" == https:* ]]; then
      curl -kfsS "$url" >/dev/null 2>&1 && break
    else
      curl -fsS "$url" >/dev/null 2>&1 && break
    fi
    sleep 2
  done
  if [[ "$url" == https:* ]]; then curl -kfsS "$url" >/dev/null; else curl -fsS "$url" >/dev/null; fi
 done

LOG_FILE="$(mktemp)"
trap 'rm -f "$LOG_FILE"' EXIT

if [[ -x ./scripts/register-mi-service-catalog.sh ]]; then
  ./scripts/register-mi-service-catalog.sh 2>&1 | tee "$LOG_FILE"
else
  echo 'No deterministic register-mi-service-catalog.sh was found; forcing MI startup registration.'
  "${DC[@]}" "${COMPOSE[@]}" up -d --force-recreate wso2-mi
  for _ in $(seq 1 120); do
    "${DC[@]}" "${COMPOSE[@]}" logs --no-color wso2-mi 2>&1 | tee "$LOG_FILE" \
      | grep -qE 'Successfully (updated|published).*service catalog|TelcoObservabilityAPI' && break
    sleep 2
  done
fi

if ! grep -q 'TelcoObservabilityAPI' "$LOG_FILE"; then
  echo 'ERROR: runtime output did not prove TelcoObservabilityAPI registration.' >&2
  echo 'Review APIM and MI logs:' >&2
  echo "  ${DC[*]} ${COMPOSE[*]} logs wso2-mi wso2-apim" >&2
  exit 1
fi

curl -fsS http://localhost:8290/observability/v1/health | jq .

echo
echo 'PASS: TelcoObservabilityAPI 1.0.0 registration was observed.'
echo 'Verify in Publisher -> Services: https://localhost:9443/publisher'
echo 'Service URL: http://wso2-mi:8290/observability/v1'
