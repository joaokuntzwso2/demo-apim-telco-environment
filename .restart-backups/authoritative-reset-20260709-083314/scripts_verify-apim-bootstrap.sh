#!/usr/bin/env bash
set -eu

APIM_URL="${APIM_URL:-https://localhost:9443}"
PORTAL_URL="${PORTAL_URL:-http://localhost:8080}"

echo "Checking portal runtime state..."

STATUS="$(curl -s "$PORTAL_URL/portal-status" || true)"
echo "$STATUS" | python3 -m json.tool || true

echo "$STATUS" | grep -q '"status"[[:space:]]*:[[:space:]]*"READY"' || {
  echo "ERROR: portal runtime state is not READY."
  exit 1
}

echo "$STATUS" | grep -q '"hasConsumerKey"[[:space:]]*:[[:space:]]*true' || {
  echo "ERROR: Regional Portal consumer key is missing."
  exit 1
}

echo "$STATUS" | grep -q '"hasConsumerSecret"[[:space:]]*:[[:space:]]*true' || {
  echo "ERROR: Regional Portal consumer secret is missing."
  exit 1
}

echo "Checking that runtime APIs are listed in runtime.json..."

for API in \
  TelcoBusinessCatalogAPI \
  Customer360API \
  NumberLifecycleAPI \
  NetworkSliceAPI \
  PartnerChargingAPI \
  BillingAdjustmentSOAP \
  NetworkEventsStreamAPI
do
  echo "$STATUS" | grep -q "$API" || {
    echo "ERROR: $API is missing from portal runtime state."
    exit 1
  }
done


echo "Resolving the base Compose project for read-only verification."

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"

COMPOSE_PROJECT="$(
  docker inspect \
    wso2-apim-4-7 \
    --format \
    '{{ index .Config.Labels "com.docker.compose.project" }}' \
    2>/dev/null ||
    true
)"

if [[ -z "${COMPOSE_PROJECT}" ]]; then
  echo "ERROR: Could not resolve the running APIM Compose project."
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  BASE_COMPOSE=(
    docker compose
    -p "${COMPOSE_PROJECT}"
    -f "${ROOT_DIR}/docker-compose.yml"
  )
elif docker-compose version >/dev/null 2>&1; then
  BASE_COMPOSE=(
    docker-compose
    -p "${COMPOSE_PROJECT}"
    -f "${ROOT_DIR}/docker-compose.yml"
  )
else
  echo "ERROR: Docker Compose is unavailable."
  exit 1
fi

if ! "${BASE_COMPOSE[@]}" config --services |
    grep -Fxq 'apim-bootstrapper'
then
  echo "ERROR: apim-bootstrapper is absent from docker-compose.yml."
  exit 1
fi

echo "Using Compose project: ${COMPOSE_PROJECT}"
echo "Using Compose file: ${ROOT_DIR}/docker-compose.yml"

echo "Waiting for WSO2 API Manager to become ready."

apim_ready=false

for attempt in $(seq 1 120); do
  if curl -kfsS \
      --connect-timeout 2 \
      --max-time 5 \
      "${APIM_URL}/services/Version" \
      >/dev/null 2>&1
  then
    echo "WSO2 API Manager is ready."
    apim_ready=true
    break
  fi

  printf \
    'Waiting for APIM: attempt %d/120\n' \
    "${attempt}"

  sleep 2
done

if [[ "${apim_ready}" != "true" ]]; then
  echo "ERROR: WSO2 API Manager did not become ready."

  docker ps -a \
    --filter name=wso2-apim-4-7

  docker logs \
    --tail=200 \
    wso2-apim-4-7 \
    2>/dev/null ||
    true

  exit 1
fi

echo "Checking APIM DevPortal API visibility..."

"${BASE_COMPOSE[@]}" run --rm --no-deps apim-bootstrapper sh -lc '
set -eu

APIM_URL="https://wso2-apim:9443"

DCR=$(curl -k -sS -u admin:admin \
  -H "Content-Type: application/json" \
  -d "{\"callbackUrl\":\"http://localhost:8080/callback\",\"clientName\":\"verify-devportal-$(date +%s)\",\"owner\":\"admin\",\"grantType\":\"password refresh_token client_credentials\",\"saasApp\":true}" \
  "$APIM_URL/client-registration/v0.17/register")

CID=$(node -e "console.log(JSON.parse(process.argv[1]).clientId)" "$DCR")
SEC=$(node -e "console.log(JSON.parse(process.argv[1]).clientSecret)" "$DCR")

TOKEN=$(curl -k -sS -u "$CID:$SEC" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode grant_type=password \
  --data-urlencode username=admin \
  --data-urlencode password=admin \
  --data-urlencode "scope=apim:api_view apim:subscribe apim:app_manage apim:sub_manage" \
  "$APIM_URL/oauth2/token" \
  | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d);process.stdin.on(\"end\",()=>console.log(JSON.parse(s).access_token))")

for API in \
  TelcoBusinessCatalogAPI \
  Customer360API \
  NumberLifecycleAPI \
  NetworkSliceAPI \
  PartnerChargingAPI \
  BillingAdjustmentSOAP \
  NetworkEventsStreamAPI
do
  echo "Checking $API in DevPortal..."
  FOUND=$(curl -k -sS \
    -H "Authorization: Bearer $TOKEN" \
    "$APIM_URL/api/am/devportal/v3/apis?query=name:$API&limit=100" \
    | node -e "
      let s=\"\";process.stdin.on(\"data\",d=>s+=d);
      process.stdin.on(\"end\",()=> {
        const data=JSON.parse(s);
        const list=data.list||data.data||[];
        const ok=list.some(api => api.name === process.argv[1]);
        console.log(ok ? \"yes\" : \"no\");
      })
    " "$API")

  if [ "$FOUND" != "yes" ]; then
    echo "ERROR: $API is not visible in DevPortal."
    exit 1
  fi
done

echo "All runtime APIs are visible in DevPortal."
'

echo "APIM bootstrap verification passed."
