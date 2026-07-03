#!/usr/bin/env bash
set -euo pipefail

BROKER_CONTAINER="${BROKER_CONTAINER:-telco-redpanda}"

topics=(
  "telco.network.qod.events"
  "telco.fraud.sim-swap.events"
  "telco.partner.settlement.events"
)

for topic in "${topics[@]}"; do
  docker exec "$BROKER_CONTAINER" rpk topic create "$topic" --brokers localhost:9092 || true
done

docker exec "$BROKER_CONTAINER" rpk topic list --brokers localhost:9092
