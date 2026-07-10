#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHOW_JSON=true exec "$ROOT_DIR/scripts/verify-prepaid-reconciliation.sh" "$@"
