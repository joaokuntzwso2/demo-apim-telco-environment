#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

docker-compose down --remove-orphans >/dev/null 2>&1 || true
docker-compose up -d --build

echo
echo "Open:"
echo "  Telco demo portal:     http://localhost:8080"
echo "  Pipeline portal:       http://localhost:8090"
echo "  Mock backend health:   http://localhost:8081/health"
echo
echo "Logs: docker-compose logs -f"
