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
  COMPOSE+=(-f docker-compose.yml -f docker-compose.mi.yml -f docker-compose.mi.soap.yml)
  echo "Using Docker Compose: ${COMPOSE[*]}"
}

detect_compose

wait_http() {
  local name="$1"
  local url="$2"
  local attempts="${3:-120}"
  local sleep_seconds="${4:-5}"

  echo "Waiting for ${name}: ${url}"
  for ((i=1; i<=attempts; i++)); do
    if curl -ksSf --max-time 5 "$url" >/dev/null 2>&1; then
      echo "${name} is ready."
      return 0
    fi
    echo "  ${name} not ready (${i}/${attempts})"
    sleep "$sleep_seconds"
  done

  echo "${name} did not become ready." >&2
  return 1
}

# Build the shared SOAP backend image once before creating PRIMARY and DR.
"${COMPOSE[@]}" build legacy-billing-primary
"${COMPOSE[@]}" up -d --no-build legacy-billing-primary legacy-billing-dr

# Build/start foundational services first. APIM is intentionally started before
# MI because MI publishes its integration services to APIM's Service Catalog
# during runtime startup.
"${COMPOSE[@]}" up -d --build \
  telco-backend \
  subscriber-crm \
  sim-swap-service \
  device-location-service \
  oss-network-service \
  wso2-apim

wait_http "WSO2 API Manager" "https://localhost:9443/services/Version" 120 5

"${COMPOSE[@]}" up -d --build wso2-mi
wait_http "WSO2 Integrator: MI risk service" \
  "http://localhost:8290/secure-transaction-risk/v1/health" 80 5



echo "Registering the original MI services in the APIM Service Catalog..."
"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/register-mi-service-catalog.sh"

echo "Registering the Legacy SOAP Modernization services in the APIM Service Catalog..."
"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/register-soap-modernization-service-catalog.sh"

# Recreate the one-shot bootstrapper only after MI is healthy. It imports,
# deploys, publishes and subscribes the managed APIM façade whose endpoint is MI.
"${COMPOSE[@]}" rm -sf apim-bootstrapper >/dev/null 2>&1 || true

# BEGIN APIM BOOTSTRAPPER COMPLETION CHECK
echo "Waiting for the APIM bootstrapper to finish..."

for bootstrap_attempt in $(seq 1 180); do
  if ! docker inspect telco-apim-bootstrapper >/dev/null 2>&1; then
    echo \
      "  APIM bootstrapper container not created yet " \
      "(${bootstrap_attempt}/180)"
    sleep 2
    continue
  fi

  bootstrap_running="$(
    docker inspect telco-apim-bootstrapper \
      --format '{{.State.Running}}'
  )"

  bootstrap_status="$(
    docker inspect telco-apim-bootstrapper \
      --format '{{.State.Status}}'
  )"

  bootstrap_exit_code="$(
    docker inspect telco-apim-bootstrapper \
      --format '{{.State.ExitCode}}'
  )"

  echo \
    "  APIM bootstrapper: status=${bootstrap_status} " \
    "running=${bootstrap_running} " \
    "exit=${bootstrap_exit_code}"

  if [[ "$bootstrap_running" == "false" ]]; then
    if [[ "$bootstrap_exit_code" != "0" ]]; then
      echo \
        "ERROR: APIM bootstrapper failed with exit code " \
        "${bootstrap_exit_code}." >&2

      docker logs telco-apim-bootstrapper >&2 || true
      exit 1
    fi

    echo "APIM APIs, policies and governance artifacts were bootstrapped."
    break
  fi

  sleep 2
done

if [[ "${bootstrap_running:-true}" != "false" ]]; then
  echo "ERROR: APIM bootstrapper did not finish." >&2
  docker logs --tail=300 telco-apim-bootstrapper >&2 || true
  exit 1
fi
# END APIM BOOTSTRAPPER COMPLETION CHECK

"${COMPOSE[@]}" up -d --build --force-recreate apim-bootstrapper

echo "Waiting for APIM bootstrapper to finish..."
bootstrap_exit=""
for ((i=1; i<=120; i++)); do
  bootstrap_exit="$(docker inspect -f '{{.State.ExitCode}}' telco-apim-bootstrapper 2>/dev/null || true)"
  bootstrap_running="$(docker inspect -f '{{.State.Running}}' telco-apim-bootstrapper 2>/dev/null || true)"
  if [[ "$bootstrap_running" == "false" && -n "$bootstrap_exit" ]]; then
    break
  fi
  sleep 5
done

if [[ "$bootstrap_exit" != "0" ]]; then
  echo "APIM bootstrapper failed or did not finish. Recent logs:" >&2
  "${COMPOSE[@]}" logs --tail=200 apim-bootstrapper >&2 || true
  exit 1
fi

"${COMPOSE[@]}" up -d --build --no-deps demo-portal pipeline-portal

echo
echo "Environment is ready:"
echo "  APIM Publisher:       https://localhost:9443/publisher"
echo "  APIM Developer Portal:https://localhost:9443/devportal"
echo "  MI direct endpoint:   http://localhost:8290/secure-transaction-risk/v1"
echo "  MI Management API:    https://localhost:9164"
echo "  Legacy SOAP primary:  http://localhost:18091/LegacyBillingAdjustmentService?wsdl"
echo "  Legacy SOAP DR:       http://localhost:18092/LegacyBillingAdjustmentService?wsdl"
echo "  Modernized REST API:  http://localhost:8290/billing-adjustments/v1"
echo "  CRM mock:             http://localhost:18081/health"
echo "  SIM Swap mock:        http://localhost:18082/health"
echo "  Device Location mock: http://localhost:18083/health"
echo "  OSS mock:             http://localhost:18084/health"
echo
echo "Run: ./scripts/test-mi-risk.sh"
