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


echo
echo "== Regional gateway dashboard =="
curl -s http://localhost:8081/api/v1/regional-gateways/dashboard | python3 -m json.tool | head -120 || true


echo
echo "== OPA governance =="
curl -s http://localhost:8081/api/v1/opa/governance/evaluate | python3 -m json.tool | head -160 || true


echo
echo "== Siddhi governance =="
curl -s http://localhost:8081/api/v1/siddhi/governance/evaluate | python3 -m json.tool | head -180 || true


echo
echo "== APIM Admin Siddhi Custom Policies =="
docker-compose -f docker-compose.yml -f docker-compose.kafka.yml -f docker-compose.opa.yml run --rm apim-bootstrapper node src/siddhi-custom-throttling-policies-upload.js --validate-only || true
