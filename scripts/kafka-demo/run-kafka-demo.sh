#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

echo "[kafka-demo] Creating topics..."
scripts/kafka-demo/create-topics.sh

echo
echo "[kafka-demo] Producing network SLA incident..."
scripts/kafka-demo/produce-network-incident.sh

echo
echo "[kafka-demo] Consuming events..."
scripts/kafka-demo/consume-network-events.sh
