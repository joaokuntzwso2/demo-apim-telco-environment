#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/demo-env.sh"

echo "[fresh] Removing containers, volumes and orphan services..."
compose down -v --remove-orphans || true

echo "[fresh] Building everything from scratch..."
BUILD=true BOOTSTRAP=false scripts/start.sh

echo "[fresh] Running APIM bootstrapper after clean platform startup..."
run_bootstrapper

verify_demo
print_urls
