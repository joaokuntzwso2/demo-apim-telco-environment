#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/demo-env.sh"

echo
echo "== Containers =="
compose ps

echo
echo "== Backend health =="
curl -s http://localhost:8081/health | python3 -m json.tool || true

echo
echo "== API product bundles =="
curl -s http://localhost:8081/api/v1/api-product-bundles | python3 -m json.tool | head -80 || true

echo
echo "== Moesif export =="
curl -s http://localhost:8081/api/v1/moesif/export | python3 -m json.tool | head -80 || true

echo
echo "== Kafka status =="
curl -s http://localhost:8081/api/v1/kafka/status | python3 -m json.tool || true
