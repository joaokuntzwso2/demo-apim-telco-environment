#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

docker-compose down --remove-orphans >/dev/null 2>&1 || true
# Works with both legacy docker-compose and newer compose implementations that honor COMPOSE_PROFILES.
COMPOSE_PROFILES=apim docker-compose up --build
