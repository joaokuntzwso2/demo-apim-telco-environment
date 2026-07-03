#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/demo-env.sh"

BUILD="${BUILD:-true}"
BOOTSTRAP="${BOOTSTRAP:-true}"

echo "[start] Starting Telco WSO2 demo..."
echo "[start] Compose files: ${COMPOSE_FILES[*]}"

if [ "$BUILD" = "true" ]; then
  echo "[start] Building images..."
  compose build
fi

echo "[start] Starting containers..."
compose up -d

wait_for_http "Telco backend" "http://localhost:8081/health" 80 5
wait_for_redpanda
create_kafka_topics

wait_for_http "WSO2 APIM" "https://localhost:9443/services/Version" 100 10

if [ "$BOOTSTRAP" = "true" ]; then
  run_bootstrapper
fi

verify_demo
print_urls
