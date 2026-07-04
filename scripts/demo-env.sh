#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

COMPOSE_FILES=(-f docker-compose.yml)

if [ -f docker-compose.kafka.yml ]; then
  COMPOSE_FILES+=(-f docker-compose.kafka.yml)
fi

if [ -f docker-compose.opa.yml ]; then
  COMPOSE_FILES+=(-f docker-compose.opa.yml)
fi

compose() {
  docker-compose "${COMPOSE_FILES[@]}" "$@"
}

wait_for_http() {
  local name="$1"
  local url="$2"
  local max_attempts="${3:-80}"
  local delay="${4:-5}"

  echo "[wait] Waiting for ${name}: ${url}"

  for attempt in $(seq 1 "$max_attempts"); do
    if curl -k -s "$url" >/dev/null; then
      echo "[wait] ${name} is ready."
      return 0
    fi

    echo "[wait] ${name} not ready yet (${attempt}/${max_attempts})..."
    sleep "$delay"
  done

  echo "[wait] ERROR: ${name} did not become ready."
  return 1
}


wait_for_opa() {
  if ! docker ps --format '{{.Names}}' | grep -qx 'telco-opa'; then
    echo "[opa] OPA container not running. Skipping OPA readiness."
    return 0
  fi

  echo "[opa] Waiting for OPA policy engine..."

  for attempt in $(seq 1 60); do
    if curl -s http://localhost:8181/health >/dev/null 2>&1; then
      echo "[opa] OPA is ready."
      return 0
    fi

    echo "[opa] OPA not ready yet (${attempt}/60)..."
    sleep 3
  done

  echo "[opa] WARNING: OPA did not become ready. Continuing demo startup."
  return 0
}

wait_for_redpanda() {
  if ! docker ps --format '{{.Names}}' | grep -qx 'telco-redpanda'; then
    echo "[kafka] Redpanda container not running. Skipping Kafka readiness."
    return 0
  fi

  echo "[kafka] Waiting for Redpanda..."

  for attempt in $(seq 1 60); do
    if docker exec telco-redpanda rpk cluster info --brokers localhost:9092 >/dev/null 2>&1; then
      echo "[kafka] Redpanda is ready."
      return 0
    fi

    echo "[kafka] Redpanda not ready yet (${attempt}/60)..."
    sleep 3
  done

  echo "[kafka] WARNING: Redpanda did not become ready. Continuing demo startup."
  return 0
}

create_kafka_topics() {
  if [ -x scripts/kafka-demo/create-topics.sh ]; then
    echo "[kafka] Creating demo topics..."
    scripts/kafka-demo/create-topics.sh || true
  else
    echo "[kafka] No Kafka topic script found. Skipping."
  fi
}

run_bootstrapper() {
  echo "[bootstrap] Running APIM bootstrapper..."
  compose run --rm apim-bootstrapper
}

verify_demo() {
  echo "[verify] Backend health..."
  curl -s http://localhost:8081/health >/dev/null

  echo "[verify] API product bundles..."
  curl -s http://localhost:8081/api/v1/api-product-bundles >/dev/null || true

  echo "[verify] Moesif export..."
  curl -s http://localhost:8081/api/v1/moesif/export >/dev/null || true

  if docker ps --format '{{.Names}}' | grep -qx 'telco-redpanda'; then
    echo "[verify] Kafka status..."
    curl -s http://localhost:8081/api/v1/kafka/status >/dev/null || true
  fi

  echo "[verify] Done."
}

print_urls() {
  echo
  echo "[ready] Demo is ready."
  echo
  echo "Demo Portal:      http://localhost:8080"
  echo "Pipeline Portal:  http://localhost:8090"
  echo "APIM Publisher:   https://localhost:9443/publisher"
  echo "APIM DevPortal:   https://localhost:9443/devportal"
  echo "Credentials:      admin / admin"
  echo
  echo "Useful backend endpoints:"
  echo "  http://localhost:8081/health"
  echo "  http://localhost:8081/api/v1/api-product-bundles"
  echo "  http://localhost:8081/api/v1/moesif/export"
  echo "  http://localhost:8081/api/v1/event-broker/simulation"
  echo "  http://localhost:8081/api/v1/kafka/status"
  echo
}
