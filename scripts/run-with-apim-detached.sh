#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

docker-compose down --remove-orphans >/dev/null 2>&1 || true
COMPOSE_PROFILES=apim docker-compose up -d --build

echo
echo "Open after APIM is healthy:"
echo "  Telco demo portal:     http://localhost:8080"
echo "  Pipeline portal:       http://localhost:8090"
echo "  APIM Publisher:        https://localhost:9443/publisher"
echo "  APIM DevPortal:        https://localhost:9443/devportal"
echo
echo "Default credentials: admin/admin"
echo "Logs: docker-compose logs -f"
