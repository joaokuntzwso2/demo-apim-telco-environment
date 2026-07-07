#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "${CONFIRM_RESET:-}" != "YES" ]]; then
  echo "This script deletes all Docker containers, volumes, and generated state"
  echo "belonging to this demo project."
  echo
  echo "Run it with:"
  echo "  CONFIRM_RESET=YES ./scripts/reset-and-validate-from-scratch.sh"
  exit 1
fi

if [[ "${ALLOW_DIRTY:-0}" != "1" ]] && [[ -n "$(git status --porcelain)" ]]; then
  echo "[FAIL] The Git working tree contains uncommitted changes."
  echo
  git status --short
  echo
  echo "Commit/stash them first, or run with ALLOW_DIRTY=1."
  exit 1
fi

COMPOSE_FILES=(
  docker-compose.yml
  docker-compose.kafka.yml
  docker-compose.opa.yml
  docker-compose.mi.yml
  docker-compose.mi.soap.yml
  docker-compose.observability.yml
  docker-compose.runtime-persistence.yml
  docker-compose.siddhi-runtime.yml
  docker-compose.mi-runtime-memory.yml
)

for file in "${COMPOSE_FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "[FAIL] Required Compose file not found: $file"
    exit 1
  fi
done

COMPOSE=(docker compose)

for file in "${COMPOSE_FILES[@]}"; do
  COMPOSE+=(-f "$file")
done

PROJECT="$(
  "${COMPOSE[@]}" config --format json |
    jq -r '.name // empty'
)"

if [[ -z "$PROJECT" ]]; then
  PROJECT="${COMPOSE_PROJECT_NAME:-demo-apim-telco-environment}"
fi

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_DIR=".reset-validation-logs/${TIMESTAMP}"
mkdir -p "$LOG_DIR"

service_exists() {
  "${COMPOSE[@]}" config --services | grep -qx "$1"
}

wait_for_http() {
  local name="$1"
  local url="$2"
  local insecure="${3:-0}"
  local attempt
  local curl_args=(
    --silent
    --show-error
    --fail
    --connect-timeout 3
    --max-time 10
  )

  if [[ "$insecure" == "1" ]]; then
    curl_args+=(-k)
  fi

  echo "[wait] Waiting for ${name}: ${url}"

  for attempt in $(seq 1 180); do
    if curl "${curl_args[@]}" "$url" >/dev/null 2>&1; then
      echo "[PASS] ${name} is reachable."
      return 0
    fi

    printf '.'
    sleep 5
  done

  echo
  echo "[FAIL] ${name} did not become reachable."
  return 1
}

wait_for_healthy_container() {
  local container="$1"
  local attempt
  local status

  echo "[wait] Waiting for ${container} health..."

  for attempt in $(seq 1 180); do
    status="$(
      docker inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$container" 2>/dev/null || true
    )"

    case "$status" in
      healthy|running)
        echo "[PASS] ${container} status: ${status}"
        return 0
        ;;
      exited|dead)
        echo
        echo "[FAIL] ${container} status: ${status}"
        docker logs --tail 150 "$container" 2>&1 || true
        return 1
        ;;
    esac

    printf '.'
    sleep 5
  done

  echo
  echo "[FAIL] ${container} did not become healthy."
  return 1
}

show_failure_diagnostics() {
  local exit_code=$?

  trap - ERR
  set +e

  echo
  echo "============================================================"
  echo "RESET/VALIDATION FAILED"
  echo "Logs: ${LOG_DIR}"
  echo "============================================================"

  "${COMPOSE[@]}" ps

  for container in \
    wso2-apim-4-7 \
    wso2-mi-4-6 \
    telco-redpanda \
    telco-backend; do
    if docker inspect "$container" >/dev/null 2>&1; then
      echo
      echo "---- ${container} ----"
      docker logs --tail 120 "$container" 2>&1
    fi
  done

  exit "$exit_code"
}

trap show_failure_diagnostics ERR

echo
echo "============================================================"
echo "1. Removing the complete existing environment"
echo "Project: ${PROJECT}"
echo "============================================================"

"${COMPOSE[@]}" down \
  --volumes \
  --remove-orphans \
  --rmi local || true

# Remove leftover one-off containers, such as compose-run bootstrap containers.
LEFTOVER_CONTAINERS="$(
  docker ps -aq \
    --filter "label=com.docker.compose.project=${PROJECT}"
)"

if [[ -n "$LEFTOVER_CONTAINERS" ]]; then
  echo "$LEFTOVER_CONTAINERS" | xargs docker rm -f
fi

# Remove any remaining project volumes, including portal state volumes that
# may have remained attached to one-off or previously removed services.
LEFTOVER_VOLUMES="$(
  docker volume ls -q \
    --filter "label=com.docker.compose.project=${PROJECT}"
)"

if [[ -n "$LEFTOVER_VOLUMES" ]]; then
  echo "$LEFTOVER_VOLUMES" | xargs docker volume rm
fi

LEFTOVER_NETWORKS="$(
  docker network ls -q \
    --filter "label=com.docker.compose.project=${PROJECT}"
)"

if [[ -n "$LEFTOVER_NETWORKS" ]]; then
  echo "$LEFTOVER_NETWORKS" | xargs docker network rm || true
fi

echo "[PASS] Previous project containers and volumes removed."

echo
echo "============================================================"
echo "2. Validating the merged Compose configuration"
echo "============================================================"

"${COMPOSE[@]}" config \
  > "${LOG_DIR}/merged-compose.yml"

echo "[PASS] Compose configuration is valid."

echo
echo "============================================================"
echo "3. Rebuilding every local image without cache"
echo "============================================================"

"${COMPOSE[@]}" build --no-cache \
  2>&1 | tee "${LOG_DIR}/build.log"

echo
echo "============================================================"
echo "4. Starting infrastructure and runtime services"
echo "============================================================"

START_SERVICES=()

while IFS= read -r service; do
  case "$service" in
    apim-bootstrapper|demo-portal|pipeline-portal|telco-traffic-generator)
      ;;
    *)
      START_SERVICES+=("$service")
      ;;
  esac
done < <("${COMPOSE[@]}" config --services)

"${COMPOSE[@]}" up -d \
  --remove-orphans \
  "${START_SERVICES[@]}"

wait_for_healthy_container "telco-redpanda"

wait_for_http \
  "WSO2 API Manager" \
  "https://127.0.0.1:9443/services/Version" \
  1

# Allow APIM Gateway artifacts and indexing services to finish initializing.
sleep 20

wait_for_http \
  "WSO2 Integrator RuntimePolicyAlertAPI" \
  "http://127.0.0.1:8290/internal/runtime-policy-alerts/v1/health"

echo
echo "============================================================"
echo "5. Running the APIM bootstrapper"
echo "============================================================"

"${COMPOSE[@]}" run \
  --rm \
  --no-deps \
  apim-bootstrapper \
  2>&1 | tee "${LOG_DIR}/bootstrap.log"

echo
echo "============================================================"
echo "6. Registering MI services in APIM Service Catalog"
echo "============================================================"

./scripts/register-mi-service-catalog.sh \
  2>&1 | tee "${LOG_DIR}/service-catalog.log"

echo
echo "============================================================"
echo "7. Starting the consumer and pipeline portals"
echo "============================================================"

PORTAL_SERVICES=()

for portal in demo-portal pipeline-portal; do
  if service_exists "$portal"; then
    PORTAL_SERVICES+=("$portal")
  fi
done

if [[ "${#PORTAL_SERVICES[@]}" -gt 0 ]]; then
  "${COMPOSE[@]}" up -d "${PORTAL_SERVICES[@]}"
fi

echo "[wait] Allowing API revisions, products, indexing, and portals to settle..."
sleep 45

echo
echo "============================================================"
echo "8. Running complete Siddhi runtime verification"
echo "============================================================"

./scripts/verify-siddhi-runtime-enforcement.sh \
  2>&1 | tee "${LOG_DIR}/verification.log"

echo
echo "============================================================"
echo "9. Starting the traffic generator after validation"
echo "============================================================"

if service_exists "telco-traffic-generator"; then
  "${COMPOSE[@]}" up -d telco-traffic-generator
else
  echo "[INFO] telco-traffic-generator service is not defined."
fi

echo
echo "============================================================"
echo "RESET AND VALIDATION COMPLETED SUCCESSFULLY"
echo "============================================================"
echo
echo "Logs:"
echo "  ${LOG_DIR}"
echo
echo "Main interfaces:"
echo "  Admin:             https://localhost:9443/admin"
echo "  Publisher:         https://localhost:9443/publisher"
echo "  Developer Portal:  https://localhost:9443/devportal"
echo "  Gateway:           https://localhost:8243"
echo
echo "For browser-based API Try Out, open https://localhost:8243 once"
echo "and accept the local certificate warning."
echo

"${COMPOSE[@]}" ps
