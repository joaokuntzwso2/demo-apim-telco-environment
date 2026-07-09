#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"

cd "$ROOT_DIR"

pass() {
  echo "[telco-ai-wiring][PASS] $*"
}

fail() {
  echo "[telco-ai-wiring][FAIL] $*" >&2
  exit 1
}

require_file() {
  local file="$1"

  [[ -s "$file" ]] ||
    fail "Missing or empty file: $file"
}

require_text() {
  local file="$1"
  local text="$2"

  grep -Fq -- "$text" "$file" ||
    fail "$file does not contain: $text"
}

require_file ".env.ai.local"
require_file "docker-compose.ai.yml"

require_file \
  "services/apim-bootstrapper/src/ensure-telco-ai-policy.js"

require_file \
  "services/apim-bootstrapper/src/check-telco-ai-policy.js"

require_file \
  "services/apim-bootstrapper/src/ensure-telco-ai-docs.js"

require_file \
  "services/apim-bootstrapper/src/ensure-telco-ai-mcp.sh"

require_file \
  "scripts/register-telco-ai-service-catalog.sh"

require_file \
  "services/demo-portal/telco-ai-routes.js"

require_file \
  "services/wso2-mi/synapse-configs/default/sequences/TelcoAiStandardAgent.xml"

require_file \
  "services/wso2-mi/synapse-configs/default/sequences/TelcoAiAdvancedAgent.xml"

require_text \
  "services/apim-bootstrapper/package.json" \
  "node src/ensure-telco-ai-policy.js"

require_text \
  "services/apim-bootstrapper/package.json" \
  "node src/ensure-telco-ai-docs.js"

require_text \
  "services/apim-bootstrapper/package.json" \
  "bash src/ensure-telco-ai-mcp.sh"

require_text \
  "scripts/reset-with-telco-ai.sh" \
  "--env-file"

require_text \
  "scripts/reset-with-telco-ai.sh" \
  "docker-compose.siddhi-runtime.yml"

require_text \
  "scripts/reset-with-telco-ai.sh" \
  "register-telco-ai-service-catalog.sh"

require_text \
  "scripts/reset-with-telco-ai.sh" \
  "verify-telco-ai-agent.sh"

require_text \
  "services/demo-portal/Dockerfile" \
  "telco-ai-routes.js"

require_text \
  "docker-compose.ai.yml" \
  "OPENAI_API_KEY"

if grep -nE \
  'docker[ -]compose|docker-compose|compose up|compose build' \
  scripts/register-telco-ai-service-catalog.sh
then
  fail \
    "Service Catalog script still contains destructive " \
    "Docker Compose commands"
fi

node --check \
  services/apim-bootstrapper/src/bootstrap.js

node --check \
  services/apim-bootstrapper/src/verify-telco-ai.js

node --check \
  services/apim-bootstrapper/src/ensure-telco-ai-policy.js

node --check \
  services/apim-bootstrapper/src/check-telco-ai-policy.js

node --check \
  services/apim-bootstrapper/src/ensure-telco-ai-docs.js

node --check \
  services/demo-portal/server.js

node --check \
  services/demo-portal/telco-ai-routes.js

bash -n \
  services/apim-bootstrapper/src/ensure-telco-ai-mcp.sh \
  scripts/register-telco-ai-service-catalog.sh \
  scripts/reset-with-telco-ai.sh \
  scripts/verify-telco-ai-agent.sh

python3 <<'PY'
from pathlib import Path
import json
import xml.etree.ElementTree as ET

json.loads(
    Path(
        "artifacts/apim-admin/api-product-bundles.json"
    ).read_text(encoding="utf-8")
)

for path in Path(
    "services/wso2-mi/synapse-configs/default"
).rglob("TelcoAi*.xml"):
    ET.parse(path)

print(
    "[telco-ai-wiring][PASS] "
    "AI JSON and XML artifacts are well formed"
)
PY

git check-ignore .env.ai.local >/dev/null ||
  fail ".env.ai.local is not ignored by Git"


require_text \
  "scripts/reset-with-telco-ai.sh" \
  "START_SERVICES"

require_text \
  "scripts/reset-with-telco-ai.sh" \
  "apim-bootstrapper|demo-portal"


require_text \
  "services/apim-bootstrapper/src/ensure-telco-ai-mcp.sh" \
  "APICTL environment already configured"


require_text \
  "scripts/reset-with-telco-ai.sh" \
  "TELCO_AI_SKIP_LIVE_CHAT=true"

require_text \
  "scripts/verify-telco-ai-agent.sh" \
  "TELCO_AI_LIVE_CHAT_SKIP"

pass "All Telco AI reset dependencies are wired"
