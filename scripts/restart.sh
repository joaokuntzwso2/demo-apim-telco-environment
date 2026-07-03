#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/demo-env.sh"

BUILD="${BUILD:-true}"
BOOTSTRAP="${BOOTSTRAP:-true}"

echo "[restart] Restarting Telco WSO2 demo..."

if [ "$BUILD" = "true" ]; then
  echo "[restart] Rebuilding images..."
  compose build
fi

echo "[restart] Recreating containers..."
compose up -d --force-recreate

wait_for_http "Telco backend" "http://localhost:8081/health" 80 5
wait_for_redpanda
create_kafka_topics

wait_for_http "WSO2 APIM" "https://localhost:9443/services/Version" 100 10

if [ "$BOOTSTRAP" = "true" ]; then
  run_bootstrapper
fi

verify_demo
print_urls
