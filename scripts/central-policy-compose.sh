#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose)
else
  echo "[central-policy-compose] Docker Compose was not found." >&2
  exit 1
fi

files=(docker-compose.yml)
for file in \
  docker-compose.kafka.yml \
  docker-compose.opa.yml \
  docker-compose.mi.yml \
  docker-compose.commercial.yml \
  docker-compose.mi.soap.yml \
  docker-compose.observability.yml \
  docker-compose.runtime-persistence.yml \
  docker-compose.central-policy.yml
do
  [[ -f "$file" ]] && files+=("$file")
done

command=("${DC[@]}")
for file in "${files[@]}"; do
  command+=(-f "$file")
done

exec "${command[@]}" "$@"
