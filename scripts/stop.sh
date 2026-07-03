#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/demo-env.sh"

echo "[stop] Stopping Telco WSO2 demo..."
compose down --remove-orphans
echo "[stop] Stopped. Volumes were kept."
