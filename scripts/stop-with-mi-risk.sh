#!/usr/bin/env bash
set -euo pipefail

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
  else
    echo "Docker Compose was not found." >&2
    echo "Install/update Docker Desktop, or install a compatible docker-compose executable." >&2
    exit 1
  fi
  COMPOSE+=(-f docker-compose.yml -f docker-compose.mi.yml -f docker-compose.mi.soap.yml)
  echo "Using Docker Compose: ${COMPOSE[*]}"
}

detect_compose
"${COMPOSE[@]}" down
