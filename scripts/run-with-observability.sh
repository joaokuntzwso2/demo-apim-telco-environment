#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif docker-compose version >/dev/null 2>&1; then
  DC=(docker-compose)
else
  echo 'Docker Compose is required.' >&2
  exit 1
fi

FILES=(-f docker-compose.yml -f docker-compose.kafka.yml -f docker-compose.mi.yml)
[[ -f docker-compose.mi.soap.yml ]] && FILES+=(-f docker-compose.mi.soap.yml)
FILES+=(-f docker-compose.observability.yml)
COMPOSE=("${DC[@]}" "${FILES[@]}")
printf 'Using: %q ' "${COMPOSE[@]}"; echo

# WSO2 requires APIM to be available before MI performs startup-time Service Catalog publication.
"${COMPOSE[@]}" up -d --build tempo otel-collector prometheus loki redpanda wso2-apim

echo 'Waiting for WSO2 API Manager before starting MI...'
for _ in $(seq 1 150); do
  curl -kfsS https://localhost:9443/services/Version >/dev/null 2>&1 && break
  sleep 2
done
curl -kfsS https://localhost:9443/services/Version >/dev/null || {
  echo 'ERROR: WSO2 API Manager did not become ready.' >&2
  exit 1
}

"${COMPOSE[@]}" up -d --build telco-observability telco-backend-observer wso2-mi

# Start/reconcile every remaining base and observability service.
"${COMPOSE[@]}" up -d --build

for url in \
  http://localhost:8088/health \
  http://localhost:8091/health \
  http://localhost:8288/health \
  http://localhost:9470/health \
  http://localhost:8290/observability/v1/health \
  http://localhost:9090/-/ready \
  http://localhost:3100/ready \
  http://localhost:3200/ready \
  http://localhost:3000/api/health; do
  echo "Waiting for $url"
  for _ in $(seq 1 120); do curl -fsS "$url" >/dev/null 2>&1 && break; sleep 2; done
  curl -fsS "$url" >/dev/null || { echo "ERROR: $url is not ready"; exit 1; }
done

echo
printf '%s\n' \
  'Observability stack is ready:' \
  '  Governed APIM front door with metrics: http://localhost:8288' \
  '  Grafana:                            http://localhost:3000 (admin/admin)' \
  '  Prometheus:                         http://localhost:9090' \
  '  Tempo:                              http://localhost:3200' \
  '  Loki:                               http://localhost:3100' \
  '  Operator API through MI:            http://localhost:8290/observability/v1'
