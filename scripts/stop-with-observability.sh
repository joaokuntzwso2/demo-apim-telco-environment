#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if docker compose version >/dev/null 2>&1; then DC=(docker compose); else DC=(docker-compose); fi
FILES=(-f docker-compose.yml -f docker-compose.kafka.yml -f docker-compose.mi.yml)
[[ -f docker-compose.mi.soap.yml ]] && FILES+=(-f docker-compose.mi.soap.yml)
FILES+=(-f docker-compose.observability.yml)
"${DC[@]}" "${FILES[@]}" down --remove-orphans
