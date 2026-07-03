#!/usr/bin/env bash
set -euo pipefail

BROKER_CONTAINER="${BROKER_CONTAINER:-telco-redpanda}"
TOPIC="telco.network.qod.events"

docker exec "$BROKER_CONTAINER" rpk topic consume "$TOPIC" \
  --brokers localhost:9092 \
  --num 5 \
  --offset start
