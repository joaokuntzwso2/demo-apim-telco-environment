#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
./scripts/telco-demo-control.sh reset
./scripts/register-telco-ai-service-catalog.sh
./scripts/bootstrap-telco-ai.sh
./scripts/verify-telco-ai-agent.sh
