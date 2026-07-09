#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"

cd "$ROOT_DIR"

ENV_FILE="${TELCO_AI_ENV_FILE:-.env.ai.local}"

pass() {
  echo "[telco-ai-reset][PASS] $*"
}

fail() {
  echo "[telco-ai-reset][FAIL] $*" >&2
  exit 1
}

if [[ ! -f "$ENV_FILE" ]]; then
  fail "Missing environment file: $ENV_FILE"
fi

OPENAI_KEY_PRESENT="no"

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"

  case "$line" in
    OPENAI_API_KEY=*)
      value="${line#OPENAI_API_KEY=}"

      if [[ -n "$value" && "$value" != "replace-me" ]]; then
        OPENAI_KEY_PRESENT="yes"
      fi

      break
      ;;
  esac
done < "$ENV_FILE"

if [[ "$OPENAI_KEY_PRESENT" != "yes" ]]; then
  fail \
    "OPENAI_API_KEY is missing, empty, or replace-me " \
    "in $ENV_FILE"
fi

COMPOSE_FILES=(
  -f docker-compose.yml
  -f docker-compose.kafka.yml
  -f docker-compose.opa.yml
  -f docker-compose.central-policy.yml
  -f docker-compose.mi.yml
  -f docker-compose.ai.yml
  -f docker-compose.oauth-business-controls.yml
  -f docker-compose.commercial.yml
  -f docker-compose.mi.soap.yml
  -f docker-compose.observability.yml
  -f docker-compose.audit-siem.yml
  -f docker-compose.runtime-persistence.yml
  -f docker-compose.siddhi-runtime.yml
  -f docker-compose.moesif.yml
)

for ((i = 1; i < ${#COMPOSE_FILES[@]}; i += 2)); do
  file="${COMPOSE_FILES[$i]}"

  [[ -f "$file" ]] || fail "Missing Compose file: $file"
done

dc() {
  command docker compose \
    --env-file "$ENV_FILE" \
    "${COMPOSE_FILES[@]}" \
    "$@"
}

wait_for_url() {
  local description="$1"
  local url="$2"
  local attempts="${3:-120}"
  local delay="${4:-5}"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if curl -ksSf \
      --connect-timeout 5 \
      --max-time 10 \
      "$url" \
      >/dev/null 2>&1
    then
      pass "$description"
      return 0
    fi

    echo \
      "[telco-ai-reset] Waiting for $description " \
      "($attempt/$attempts)"

    sleep "$delay"
  done

  fail "$description did not become ready: $url"
}

wait_for_container_health() {
  local container="$1"
  local description="$2"
  local attempts="${3:-120}"
  local delay="${4:-5}"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    status="$(
      docker inspect \
        --format \
        '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$container" \
        2>/dev/null ||
      true
    )"

    if [[ "$status" == "healthy" ]]; then
      pass "$description"
      return 0
    fi

    if [[ "$status" == "exited" || "$status" == "dead" ]]; then
      docker logs --tail 250 "$container" || true
      fail "$description entered state: $status"
    fi

    echo \
      "[telco-ai-reset] Waiting for $description; " \
      "status=${status:-absent} ($attempt/$attempts)"

    sleep "$delay"
  done

  docker logs --tail 250 "$container" || true
  fail "$description did not become healthy"
}

echo "[telco-ai-reset] Validating complete Compose topology."

dc config --quiet
pass "Docker Compose topology"

echo \
  "[telco-ai-reset] Removing the existing environment, " \
  "including persistent volumes."

dc down \
  --remove-orphans \
  --volumes \
  --timeout 30 ||
true

echo "[telco-ai-reset] Building the complete environment."

dc build

pass "Docker images built"

echo "[telco-ai-reset] Starting runtime services."

# apim-bootstrapper must run exactly once, after APIM and MI are ready.
# demo-portal starts afterward, once runtime.json and OAuth keys exist.
START_SERVICES=()

while IFS= read -r service; do
  case "$service" in
    apim-bootstrapper|demo-portal)
      ;;
    *)
      START_SERVICES+=("$service")
      ;;
  esac
done < <(dc config --services)

if [[ "${#START_SERVICES[@]}" -eq 0 ]]; then
  fail "No runtime services resolved from Docker Compose"
fi

printf '%s\n'   "[telco-ai-reset] Runtime services:"   "${START_SERVICES[@]}"

dc up -d   --no-build   "${START_SERVICES[@]}"

pass "Runtime services started"

wait_for_url \
  "API Manager management endpoint" \
  "https://127.0.0.1:9443/services/Version" \
  180 \
  5

wait_for_container_health \
  "wso2-mi-4-6" \
  "WSO2 Integrator: MI" \
  180 \
  5

echo "[telco-ai-reset] Running the complete APIM bootstrap chain."

dc run --rm --no-deps \
  apim-bootstrapper

pass "APIM bootstrap chain"

echo "[telco-ai-reset] Registering AI services in Service Catalog."

WSO2_APIM_PUBLIC_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}" \
APIM_USERNAME="${APIM_USERNAME:-admin}" \
APIM_PASSWORD="${APIM_PASSWORD:-admin}" \
bash scripts/register-telco-ai-service-catalog.sh

pass "AI Service Catalog registration"

echo \
  "[telco-ai-reset] Recreating the portal after runtime " \
  "state and OAuth credentials were generated."

dc up -d \
  --no-deps \
  --force-recreate \
  demo-portal

wait_for_url \
  "Telco demo portal" \
  "http://127.0.0.1:8080/portal-status" \
  60 \
  3

echo "[telco-ai-reset] Running complete AI verification."

TELCO_AI_SKIP_LIVE_CHAT=true bash scripts/verify-telco-ai-agent.sh

pass "Telco AI reset and verification completed"
