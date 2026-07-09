#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif docker-compose version >/dev/null 2>&1; then
  DC=(docker-compose)
else
  echo 'Docker Compose is required.' >&2
  exit 1
fi

COMPOSE=(-f docker-compose.yml -f docker-compose.kafka.yml -f docker-compose.mi.yml)
[[ -f docker-compose.mi.soap.yml ]] && COMPOSE+=(-f docker-compose.mi.soap.yml)
COMPOSE+=(-f docker-compose.observability.yml)

APIM_ENV="${APIM_ENV:-am47}"
APIM_URL="${WSO2_APIM_URL:-https://wso2-apim:9443}"
APIM_TOKEN_URL="${WSO2_APIM_TOKEN_URL:-https://wso2-apim:9443/oauth2/token}"
APIM_USERNAME="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"
printf -v Q_APIM_ENV '%q' "$APIM_ENV"
printf -v Q_APIM_URL '%q' "$APIM_URL"
printf -v Q_APIM_TOKEN_URL '%q' "$APIM_TOKEN_URL"
printf -v Q_APIM_USERNAME '%q' "$APIM_USERNAME"
printf -v Q_APIM_PASSWORD '%q' "$APIM_PASSWORD"

printf -v INNER '%s\n' \
  'set -euo pipefail' \
  "ENV_NAME=$Q_APIM_ENV" \
  "APIM_URL=$Q_APIM_URL" \
  "TOKEN_URL=$Q_APIM_TOKEN_URL" \
  "APIM_USER=$Q_APIM_USERNAME" \
  "APIM_PASS=$Q_APIM_PASSWORD" \
  'PROJECT=/tmp/telco-observability-api' \
  'DEFINITION=/tmp/telco-observability-definition.yaml' \
  'SPEC=/workspace/contracts/openapi/telco-observability.openapi.yaml' \
  'rm -rf "$PROJECT" "$DEFINITION"' \
  'test -f "$SPEC"' \
  'apictl add env "$ENV_NAME" --apim "$APIM_URL" --token "$TOKEN_URL" -k >/tmp/apictl-add.log 2>&1 || true' \
  'apictl login "$ENV_NAME" -u "$APIM_USER" -p "$APIM_PASS" -k' \
  'apictl set --http-request-timeout 240000 || true' \
  'cat > "$DEFINITION" <<YAML' \
  'type: api' \
  'version: v4.7.0' \
  'data:' \
  '  name: TelcoObservabilityAPI' \
  '  version: 1.0.0' \
  '  context: /observability/v1' \
  '  lifeCycleStatus: CREATED' \
  '  type: HTTP' \
  '  transport: [http, https]' \
  '  visibility: PRIVATE' \
  '  provider: admin' \
  '  policies: [Unlimited]' \
  '  endpointImplementationType: ENDPOINT' \
  '  endpointConfig:' \
  '    endpoint_type: http' \
  '    production_endpoints:' \
  '      url: http://wso2-mi:8290/observability/v1' \
  '    sandbox_endpoints:' \
  '      url: http://wso2-mi:8290/observability/v1' \
  'YAML' \
  'apictl init "$PROJECT" --oas "$SPEC" --definition "$DEFINITION" --force=true' \
  'cat > "$PROJECT/deployment_environments.yaml" <<YAML' \
  'type: deployment_environments' \
  'version: v4.7.0' \
  'data:' \
  '  - name: Default' \
  '    deploymentEnvironment: Default' \
  '    displayOnDevportal: true' \
  '    deploymentVhost: localhost' \
  'YAML' \
  'apictl import api --rotate-revision --file "$PROJECT" --environment "$ENV_NAME" --update=true -k' \
  'sleep 10' \
  'set +e' \
  'PUBLISH_OUTPUT="$(apictl change-status api -a Publish -n TelcoObservabilityAPI -v 1.0.0 --provider "$APIM_USER" -e "$ENV_NAME" -k 2>&1)"' \
  'PUBLISH_RC=$?' \
  'set -e' \
  'printf "%s\n" "$PUBLISH_OUTPUT"' \
  'if [ "$PUBLISH_RC" -ne 0 ]; then' \
  '  if printf "%s" "$PUBLISH_OUTPUT" | grep -qiE "unsupported state change action|publish is not allowed|already.*published"; then' \
  '    echo "TelcoObservabilityAPI is already published; continuing."' \
  '  else' \
  '    exit "$PUBLISH_RC"' \
  '  fi' \
  'fi' \
  'echo "TelcoObservabilityAPI 1.0.0 imported, deployed, and published."'

"${DC[@]}" "${COMPOSE[@]}" build apim-bootstrapper
"${DC[@]}" "${COMPOSE[@]}" run --rm --no-deps \
  --entrypoint /bin/bash apim-bootstrapper -lc "$INNER"

echo
echo 'Managed API:'
echo '  Publisher: https://localhost:9443/publisher'
echo '  Name:      TelcoObservabilityAPI 1.0.0'
echo '  Context:   /observability/v1'
echo '  Endpoint:  http://wso2-mi:8290/observability/v1'
echo 'The API remains secured by APIM. Use a subscribed application token to invoke it.'
