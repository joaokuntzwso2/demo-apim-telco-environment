#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."

echo "Stopping and removing containers, networks and volumes..."
docker-compose down --remove-orphans --volumes

echo "Building all services..."
docker-compose build --no-cache

echo "Starting APIM and backend..."
docker-compose up -d wso2-apim telco-backend

echo "Waiting for APIM Version service..."
until curl -k -s https://localhost:9443/services/Version | grep -q "WSO2 API Manager-4.7.0"; do
  echo "APIM Version service not ready yet..."
  sleep 10
done

echo "Giving APIM Publisher/DevPortal services extra time to finish startup..."
sleep 45

echo "Running APIM bootstrapper..."
docker-compose up apim-bootstrapper

echo "Checking bootstrapper exit code..."
BOOTSTRAP_EXIT="$(docker inspect telco-apim-bootstrapper --format='{{.State.ExitCode}}')"
if [ "$BOOTSTRAP_EXIT" != "0" ]; then
  echo "ERROR: bootstrapper failed with exit code $BOOTSTRAP_EXIT"
  docker-compose logs --tail=300 apim-bootstrapper
  exit 1
fi

echo "Starting portals..."
docker-compose up -d demo-portal pipeline-portal

echo "Waiting for main portal runtime state..."
READY="no"

for i in $(seq 1 90); do
  STATUS="$(curl -s http://localhost:8080/portal-status || true)"

  if echo "$STATUS" | grep -q '"status"[[:space:]]*:[[:space:]]*"READY"'; then
    READY="yes"
    break
  fi

  echo "Portal not ready yet ($i/90)..."

  if [ "$i" = "10" ] || [ "$i" = "30" ] || [ "$i" = "60" ] || [ "$i" = "90" ]; then
    echo
    echo "Current portal-status response:"
    echo "$STATUS" || true

    echo
    echo "Container status:"
    docker-compose ps demo-portal pipeline-portal || true

    echo
    echo "Demo portal logs:"
    docker-compose logs --tail=80 demo-portal || true

    echo
  fi

  sleep 2
done

if [ "$READY" != "yes" ]; then
  echo "ERROR: main portal did not become READY."

  echo
  echo "Final docker-compose ps:"
  docker-compose ps || true

  echo
  echo "Demo portal logs:"
  docker-compose logs --tail=200 demo-portal || true

  echo
  echo "Checking runtime state file inside demo portal:"
  docker-compose exec -T demo-portal sh -lc '
    echo "STATE FILE:"
    ls -l /workspace/apim-portal-state/runtime.json || true
    echo
    echo "CONTENT:"
    cat /workspace/apim-portal-state/runtime.json 2>/dev/null | head -80 || true
  ' || true

  exit 1
}

echo "Verifying APIM-backed runtime APIs..."
./scripts/verify-apim-bootstrap.sh

echo
echo "Testing APIM-backed portal call..."
HTTP_CODE="$(curl -s -o /tmp/portal-metadata.json -w "%{http_code}" http://localhost:8080/metadata || true)"

if [ "$HTTP_CODE" != "200" ]; then
  echo "ERROR: portal /metadata did not return 200 through APIM proxy. HTTP $HTTP_CODE"
  cat /tmp/portal-metadata.json || true
  exit 1
fi

echo "Portal /metadata returned 200."
cat /tmp/portal-metadata.json | python3 -m json.tool || true

echo
echo "Done."
echo "Main portal:      http://localhost:8080"
echo "Pipeline portal:  http://localhost:8090"
echo "Publisher:        https://localhost:9443/publisher"
echo "DevPortal:        https://localhost:9443/devportal"
echo "Admin:            https://localhost:9443/admin"


echo "Patching SOAP Try Out definitions..."

if [ -f scripts/patch-soap-tryout-final.sh ]; then
  docker-compose exec -T pipeline-portal sh -lc 'cat > /tmp/patch-soap-tryout-final.sh' < scripts/patch-soap-tryout-final.sh

  docker-compose exec -T pipeline-portal sh -lc '
  chmod +x /tmp/patch-soap-tryout-final.sh

  /tmp/patch-soap-tryout-final.sh \
    BillingAdjustmentSOAP \
    1.0.0 \
    CreateBillingAdjustment \
    /workspace/artifacts/contracts/soap/examples/billing-adjustment-create-request.xml || true

  /tmp/patch-soap-tryout-final.sh \
    CandidateFieldWorkOrderSOAPAPI \
    0.9.0 \
    CreateWorkOrder \
    /workspace/artifacts/contracts/soap/examples/candidate-field-workorder-create-request.xml || true
  '
else
  echo "WARNING: scripts/patch-soap-tryout-final.sh not found; skipping SOAP Try Out patch."
fi

