#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
if docker compose version >/dev/null 2>&1; then DC=(docker compose); else DC=(docker-compose); fi
FILES=(-f docker-compose.yml)
for f in docker-compose.mi.yml docker-compose.ai.yml docker-compose.runtime-persistence.yml; do [[ -f "$f" ]] && FILES+=(-f "$f"); done
# MI's configured service-catalog publisher registers newly deployed APIs. A restart is
# intentionally used so deployment and registration remain native and idempotent.
"${DC[@]}" "${FILES[@]}" up -d --build wso2-mi
for _ in $(seq 1 90); do
  curl -fsS http://localhost:8290/telco-support/v1/health >/dev/null 2>&1 &&
  curl -fsS http://localhost:8290/telco-agent-tools/v1/health >/dev/null 2>&1 && exit 0
  sleep 2
done
echo "[service-catalog][FAIL] MI APIs did not become ready" >&2; exit 1
