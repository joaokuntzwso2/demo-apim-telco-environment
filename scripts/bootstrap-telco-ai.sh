#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
if docker compose version >/dev/null 2>&1; then DC=(docker compose); else DC=(docker-compose); fi
FILES=(-f docker-compose.yml)
for f in docker-compose.kafka.yml docker-compose.opa.yml docker-compose.mi.yml docker-compose.ai.yml docker-compose.mi.soap.yml docker-compose.observability.yml docker-compose.runtime-persistence.yml; do [[ -f "$f" ]] && FILES+=(-f "$f"); done
"${DC[@]}" "${FILES[@]}" run --rm --no-deps apim-bootstrapper node src/bootstrap-telco-ai.js
