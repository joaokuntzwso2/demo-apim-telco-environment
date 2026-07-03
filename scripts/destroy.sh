#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/demo-env.sh"

echo "[destroy] Removing containers, volumes and orphan services..."
compose down -v --remove-orphans
echo "[destroy] Removed containers and volumes."
