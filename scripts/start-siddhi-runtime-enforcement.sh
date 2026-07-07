#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

files=(
  docker-compose.yml
  docker-compose.kafka.yml
  docker-compose.opa.yml
  docker-compose.mi.yml
  docker-compose.mi.soap.yml
  docker-compose.observability.yml
  docker-compose.runtime-persistence.yml
  docker-compose.siddhi-runtime.yml
)
compose=(docker compose)
for file in "${files[@]}"; do
  [[ -f "$file" ]] && compose+=( -f "$file" )
done

wait_url() {
  local label="$1" url="$2" attempts="${3:-120}"
  local i
  for ((i=1; i<=attempts; i++)); do
    if curl -ksSf "$url" >/dev/null 2>&1; then
      printf '[start-siddhi-runtime] %s is ready.\n' "$label"
      return 0
    fi
    sleep 3
  done
  printf '[start-siddhi-runtime] ERROR: %s did not become ready: %s\n' "$label" "$url" >&2
  return 1
}

wait_bootstrapper() {
  local i cid status exit_code
  for ((i=1; i<=240; i++)); do
    cid="$("${compose[@]}" ps -aq apim-bootstrapper 2>/dev/null | head -n1)"
    if [[ -n "$cid" ]]; then
      read -r status exit_code < <(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$cid")
      if [[ "$status" == 'exited' ]]; then
        if [[ "$exit_code" == '0' ]]; then
          printf '[start-siddhi-runtime] APIM bootstrapper completed successfully.\n'
          return 0
        fi
        "${compose[@]}" logs --no-color apim-bootstrapper >&2 || true
        printf '[start-siddhi-runtime] ERROR: APIM bootstrapper exited with code %s.\n' "$exit_code" >&2
        return 1
      fi
      if [[ "$status" == 'dead' ]]; then
        "${compose[@]}" logs --no-color apim-bootstrapper >&2 || true
        printf '[start-siddhi-runtime] ERROR: APIM bootstrapper container is dead.\n' >&2
        return 1
      fi
    fi
    sleep 3
  done
  "${compose[@]}" logs --no-color apim-bootstrapper >&2 || true
  printf '[start-siddhi-runtime] ERROR: APIM bootstrapper did not complete.\n' >&2
  return 1
}

if [[ "${NO_CACHE:-0}" == '1' ]]; then
  "${compose[@]}" build --no-cache wso2-apim wso2-mi telco-backend apim-bootstrapper
else
  "${compose[@]}" build wso2-apim wso2-mi telco-backend apim-bootstrapper
fi
# Start the complete topology once. Compose dependency conditions keep the
# one-shot bootstrapper behind APIM/MI/backend/Kafka health and allow any portal
# services that depend on successful bootstrap completion to start normally.
"${compose[@]}" up -d --remove-orphans
wait_url 'Telco backend' 'http://127.0.0.1:8081/health' 80
wait_url 'WSO2 API Manager' 'https://127.0.0.1:9443/services/Version' 160
wait_url 'RuntimePolicyAlertAPI' 'http://127.0.0.1:8290/internal/runtime-policy-alerts/v1/health' 160
wait_bootstrapper
./scripts/register-mi-service-catalog.sh
"${compose[@]}" up -d --remove-orphans
printf '\n[start-siddhi-runtime] Environment started and bootstrapped.\n'
printf '[start-siddhi-runtime] Run ./scripts/verify-siddhi-runtime-enforcement.sh\n'
