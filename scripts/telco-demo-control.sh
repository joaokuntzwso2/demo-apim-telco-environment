#!/usr/bin/env bash
set -Eeuo pipefail

# Complete lifecycle controller v10 for the WSO2 telco demo.
# Default action: restart (stop, patch, build, initialize, validate and seed).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || true)"
if [[ ! -f "${ROOT_DIR}/docker-compose.yml" ]]; then
  ROOT_DIR="${REPO:-$PWD}"
fi
cd "$ROOT_DIR"

ACTION="${1:-restart}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASS="${APIM_PASSWORD:-admin}"
APIM_PUBLIC_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
SEED_COUNT="${SEED_COUNT:-24}"
SKIP_BUILD="${SKIP_BUILD:-false}"
SKIP_SEED="${SKIP_SEED:-false}"
SKIP_BOOTSTRAP="${SKIP_BOOTSTRAP:-false}"

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

on_error() {
  local rc=$?
  printf '\nERROR: command failed at line %s (exit %s).\n' "${BASH_LINENO[0]:-?}" "$rc" >&2
  if declare -p COMPOSE >/dev/null 2>&1; then
    "${COMPOSE[@]}" ps -a >&2 || true
  fi
  exit "$rc"
}
trap on_error ERR

for command in docker curl python3 jq openssl; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required."
done

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif docker-compose version >/dev/null 2>&1; then
  DC=(docker-compose)
else
  die "Docker Compose is required."
fi

[[ -f docker-compose.yml ]] || die "Run this script from the repository or install it under scripts/."

# Add local demo persistence for APIM's embedded databases. Routine down/up keeps this volume.
cat > docker-compose.runtime-persistence.yml <<'YAML'
services:
  wso2-apim:
    volumes:
      - apim-runtime-database:/home/wso2carbon/wso2am-4.7.0/repository/database
volumes:
  apim-runtime-database:
YAML

COMPOSE_FILES=(docker-compose.yml)
for file in \
  docker-compose.kafka.yml \
  docker-compose.opa.yml \
  docker-compose.mi.yml \
  docker-compose.commercial.yml \
  docker-compose.mi.soap.yml \
  docker-compose.observability.yml \
  docker-compose.audit-siem.yml \
  docker-compose.runtime-persistence.yml
do
  [[ -f "$file" ]] && COMPOSE_FILES+=("$file")
done

COMPOSE=("${DC[@]}")
for file in "${COMPOSE_FILES[@]}"; do
  COMPOSE+=(-f "$file")
done

export BUILDX_NO_DEFAULT_ATTESTATIONS=1

refresh_services() {
  SERVICE_LIST="$("${COMPOSE[@]}" config --services)"
}

has_service() {
  grep -Fxq "$1" <<<"${SERVICE_LIST:-}"
}

existing_services() {
  local service
  for service in "$@"; do
    has_service "$service" && printf '%s\n' "$service"
  done
}

up_existing() {
  local services=()
  while IFS= read -r service; do
    [[ -n "$service" ]] && services+=("$service")
  done < <(existing_services "$@")
  ((${#services[@]})) && "${COMPOSE[@]}" up -d --no-build --no-recreate "${services[@]}"
}

wait_http() {
  local url="$1" label="${2:-$1}" insecure="${3:-false}" attempts="${4:-180}"
  local curl_args=(-fsS --max-time 5)
  [[ "$insecure" == true ]] && curl_args=(-kfsS --max-time 5)
  log "Waiting for ${label}"
  for _ in $(seq 1 "$attempts"); do
    if curl "${curl_args[@]}" "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "${label} did not become ready: ${url}"
}

wait_container_health() {
  local service="$1" attempts="${2:-180}"
  local id state health
  log "Waiting for ${service} container health"
  for _ in $(seq 1 "$attempts"); do
    id="$("${COMPOSE[@]}" ps -aq "$service" 2>/dev/null || true)"
    if [[ -n "$id" ]]; then
      state="$(docker inspect "$id" --format '{{.State.Status}}' 2>/dev/null || true)"
      health="$(docker inspect "$id" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || true)"
      if [[ "$state" == running && ( "$health" == healthy || "$health" == none ) ]]; then
        return 0
      fi
    fi
    sleep 2
  done
  "${COMPOSE[@]}" ps -a "$service" || true
  "${COMPOSE[@]}" logs --tail=200 "$service" || true
  die "${service} did not become healthy."
}

patch_repository() {
  log "Applying idempotent runtime fixes"
  python3 <<'PY'
from pathlib import Path
import json
import re

# Observability: reserve host 8090 for the original pipeline portal.
p = Path('docker-compose.observability.yml')
if p.exists():
    s = p.read_text()
    s = s.replace('"8090:8090"', '"8091:8090"')
    s = s.replace("'8090:8090'", "'8091:8090'")
    s = s.replace('http://localhost:8089/health', 'http://127.0.0.1:8089/health')
    s = s.replace('http://localhost:8090/health', 'http://127.0.0.1:8090/health')
    s = s.replace('http://localhost:8088/health', 'http://127.0.0.1:8088/health')
    p.write_text(s)

# Host-side scripts must use the backend observer's new host port.
for name in [
    'scripts/run-with-observability.sh',
    'scripts/test-observability.sh',
    'scripts/test-observability-circuit.sh',
]:
    path = Path(name)
    if not path.exists():
        continue
    s = path.read_text()
    s = s.replace('http://localhost:8090/health', 'http://localhost:8091/health')
    s = s.replace('BACKEND_OBSERVER_URL:-http://localhost:8090',
                  'BACKEND_OBSERVER_URL:-http://localhost:8091')
    path.write_text(s)

# The actual MI resource is /assessments.
for name in [
    'scripts/generate-observability-traffic.sh',
    'scripts/test-observability.sh',
]:
    path = Path(name)
    if path.exists():
        current = path.read_text()
        current = re.sub(
            r'/secure-transaction-risk/v1/assess(?!ments)',
            '/secure-transaction-risk/v1/assessments',
            current,
        )
        path.write_text(current)

# MI runtime platform and readiness check.
p = Path('docker-compose.mi.yml')
if p.exists():
    lines = p.read_text().splitlines()
    service_idx = next((i for i, line in enumerate(lines)
                        if line.strip() == 'wso2-mi:'), None)
    if service_idx is None:
        raise SystemExit('Could not locate services.wso2-mi in docker-compose.mi.yml')
    service_indent = len(lines[service_idx]) - len(lines[service_idx].lstrip())
    end = len(lines)
    for i in range(service_idx + 1, len(lines)):
        if lines[i].strip() and len(lines[i]) - len(lines[i].lstrip()) <= service_indent:
            end = i
            break
    platform_idx = next((i for i in range(service_idx + 1, end)
                         if lines[i].strip().startswith('platform:')), None)
    platform_line = ' ' * (service_indent + 2) + 'platform: linux/amd64'
    if platform_idx is None:
        lines.insert(service_idx + 1, platform_line)
    else:
        lines[platform_idx] = platform_line
    s = '\n'.join(lines) + '\n'
    s = s.replace('http://localhost:8290/secure-transaction-risk/v1/health',
                  'http://127.0.0.1:9201/healthz')
    s = s.replace('http://localhost:8080/health', 'http://127.0.0.1:8080/health')
    p.write_text(s)

# MI Alpine runs non-root. Keep copied merger script owned by wso2carbon and invoke via sh.
p = Path('services/wso2-mi/Dockerfile')
if p.exists():
    s = p.read_text()
    s = re.sub(r'^FROM\s+--platform=linux/amd64\s+', 'FROM ', s, flags=re.M)
    s = s.replace(
        'COPY merge-observability-config.sh /tmp/merge-mi-observability-config.sh',
        'COPY --chown=wso2carbon:wso2 merge-observability-config.sh /tmp/merge-mi-observability-config.sh')
    s = s.replace(
        'RUN chmod +x /tmp/merge-mi-observability-config.sh \\\n    && /tmp/merge-mi-observability-config.sh ',
        'RUN /bin/sh /tmp/merge-mi-observability-config.sh ')
    p.write_text(s)

# MI endpoint schema expects literal numbers in typed numeric elements.
endpoint_root = Path('services/wso2-mi/synapse-configs/default/endpoints')
if endpoint_root.exists():
    replacements = {
        '${configs.backend_timeout_ms}': '1500',
        '${configs.backend_suspend_initial_ms}': '5000',
        '${configs.backend_suspend_max_ms}': '30000',
    }
    for path in endpoint_root.glob('*.xml'):
        s = path.read_text()
        for old, new in replacements.items():
            s = s.replace(old, new)
        path.write_text(s)

# Make the observability API lifecycle transition retry-safe and provider-specific.
p = Path('scripts/publish-observability-api.sh')
if p.exists():
    s = p.read_text()
    s = s.replace(
        'apictl change-status api -a Publish -n TelcoObservabilityAPI -v 1.0.0 -e "$ENV_NAME" -k',
        'apictl change-status api -a Publish -n TelcoObservabilityAPI -v 1.0.0 --provider "$APIM_USER" -e "$ENV_NAME" -k')
    p.write_text(s)


# The repository contains the MI runtime artifact for BillingAdjustmentModernizationAPI
# but does not contain the managed OpenAPI contract expected by the APIM bootstrap.
# JSON is valid YAML, so write one canonical OpenAPI document to both build contexts.
billing_adjustment_contract = {'openapi': '3.0.3', 'info': {'title': 'Billing Adjustment Modernization API', 'version': '1.0.0', 'description': 'Managed REST/JSON facade backed by WSO2 Integrator: MI. It validates a canonical billing-adjustment request, transforms it to the legacy SOAP/XML contract with WS-Security UsernameToken, uses failover/circuit-breaking for the legacy BSS endpoints, and normalizes the SOAP response or fault back to JSON.', 'contact': {'name': 'Telco API Platform Team', 'email': 'telco-api-platform@example.com', 'url': 'https://wso2.com/'}, 'license': {'name': 'Proprietary demo contract'}}, 'servers': [{'url': 'http://wso2-mi:8290/billing-adjustments/v1'}], 'x-wso2-basePath': '/billing-adjustments/v1', 'x-telco-health-path': '/health', 'x-telco-health-method': 'GET', 'x-telco-api-product': 'Legacy BSS Modernization Pack', 'x-telco-architecture-layer': 'enterprise-integration', 'tags': [{'name': 'Billing Adjustments', 'description': 'Modern REST facade for the legacy SOAP billing system.'}], 'paths': {'/health': {'get': {'tags': ['Billing Adjustments'], 'operationId': 'getBillingAdjustmentModernizationHealth', 'summary': 'Check the billing modernization integration service', 'description': 'Confirms that the WSO2 MI REST-to-SOAP facade is deployed.', 'responses': {'200': {'description': 'Runtime is available', 'headers': {'X-Correlation-ID': {'schema': {'type': 'string'}}}, 'content': {'application/json': {'schema': {'$ref': '#/components/schemas/Health'}}}}}}}, '/adjustments': {'post': {'tags': ['Billing Adjustments'], 'operationId': 'createBillingAdjustment', 'summary': 'Create a billing adjustment through the legacy BSS', 'description': 'Accepts canonical JSON, transforms it to a SOAP 1.1 request with WS-Security, invokes the failover legacy billing service, and returns a normalized JSON response.', 'parameters': [{'name': 'X-Correlation-ID', 'in': 'header', 'required': False, 'description': 'Existing correlation identifier. WSO2 MI creates one when omitted.', 'schema': {'type': 'string', 'maxLength': 128}}], 'requestBody': {'required': True, 'content': {'application/json': {'schema': {'$ref': '#/components/schemas/BillingAdjustmentRequest'}, 'examples': {'roamingCredit': {'value': {'transactionId': 'BILL-ADJ-2026-0001', 'subscriberId': '+525512340001', 'amount': 12.4, 'currency': 'USD', 'reasonCode': 'ROAMING_CREDIT', 'requestedBy': 'care-agent-778'}}}}}}, 'responses': {'200': {'description': 'Billing adjustment completed or replayed idempotently', 'headers': {'X-Correlation-ID': {'schema': {'type': 'string'}}}, 'content': {'application/json': {'schema': {'$ref': '#/components/schemas/BillingAdjustmentResponse'}}}}, '400': {'description': 'Invalid billing adjustment request', 'content': {'application/problem+json': {'schema': {'$ref': '#/components/schemas/Problem'}}}}, '502': {'description': 'Legacy SOAP service returned a normalized SOAP fault', 'content': {'application/problem+json': {'schema': {'$ref': '#/components/schemas/Problem'}}}}, '503': {'description': 'All legacy billing endpoints are unavailable', 'content': {'application/problem+json': {'schema': {'$ref': '#/components/schemas/Problem'}}}}}}}}, 'components': {'schemas': {'BillingAdjustmentRequest': {'type': 'object', 'additionalProperties': False, 'required': ['transactionId', 'subscriberId', 'amount', 'currency', 'reasonCode', 'requestedBy'], 'properties': {'transactionId': {'type': 'string', 'minLength': 1, 'maxLength': 128}, 'subscriberId': {'type': 'string', 'minLength': 1, 'maxLength': 64}, 'amount': {'type': 'number', 'format': 'double', 'exclusiveMinimum': 0}, 'currency': {'type': 'string', 'pattern': '^[A-Z]{3}$'}, 'reasonCode': {'type': 'string', 'minLength': 1, 'maxLength': 64}, 'requestedBy': {'type': 'string', 'minLength': 1, 'maxLength': 128}}}, 'BillingAdjustmentResponse': {'type': 'object', 'required': ['transactionId', 'adjustmentId', 'status', 'subscriberId', 'amount', 'currency', 'previousBalance', 'newBalance', 'backendNode', 'idempotentReplay', 'correlationId'], 'properties': {'transactionId': {'type': 'string'}, 'adjustmentId': {'type': 'string'}, 'status': {'type': 'string'}, 'subscriberId': {'type': 'string'}, 'amount': {'type': 'number', 'format': 'double'}, 'currency': {'type': 'string'}, 'previousBalance': {'type': 'number', 'format': 'double'}, 'newBalance': {'type': 'number', 'format': 'double'}, 'backendNode': {'type': 'string'}, 'processedAt': {'type': 'string', 'format': 'date-time'}, 'idempotentReplay': {'type': 'boolean'}, 'correlationId': {'type': 'string'}}}, 'Health': {'type': 'object', 'properties': {'status': {'type': 'string', 'example': 'UP'}, 'service': {'type': 'string', 'example': 'BillingAdjustmentModernizationAPI'}, 'runtime': {'type': 'string'}, 'pattern': {'type': 'string'}, 'correlationId': {'type': 'string'}}}, 'Problem': {'type': 'object', 'properties': {'type': {'type': 'string', 'format': 'uri'}, 'title': {'type': 'string'}, 'status': {'type': 'integer'}, 'code': {'type': 'string'}, 'detail': {'type': 'string'}, 'correlationId': {'type': 'string'}}}}}}
billing_adjustment_serialized = json.dumps(billing_adjustment_contract, indent=2) + '\n'
for contract_path in [
    Path('contracts/openapi/billing-adjustment-modernization.openapi.yaml'),
    Path('artifacts/contracts/openapi/billing-adjustment-modernization.openapi.yaml'),
]:
    contract_path.parent.mkdir(parents=True, exist_ok=True)
    if not contract_path.exists() or contract_path.read_text() != billing_adjustment_serialized:
        contract_path.write_text(billing_adjustment_serialized)


# Keep the original bootstrap aligned with the MI-backed managed APIs.
p = Path('services/apim-bootstrapper/src/bootstrap.js')
if p.exists():
    s = p.read_text()
    if 'const MI_BACKEND_URL' not in s:
        pattern = re.compile(r"(const BACKEND_URL\s*=\s*process\.env\.TELCO_BACKEND_URL\s*\|\|\s*'http://telco-backend:8081';)")
        s, count = pattern.subn(r"\1 const MI_BACKEND_URL = process.env.WSO2_MI_URL || 'http://wso2-mi:8290';", s, count=1)
        if count != 1:
            raise SystemExit('Could not add MI_BACKEND_URL to bootstrap.js')

    missing = []
    if "name: 'BillingAdjustmentModernizationAPI'" not in s:
        missing.append("{ id: 'billing-adjustment-modernization', name: 'BillingAdjustmentModernizationAPI', version: '1.0.0', importSpecCandidates: ['contracts/openapi/billing-adjustment-modernization.openapi.yaml', 'billing-adjustment-modernization.openapi.yaml'], context: '/billing-adjustments/v1', endpointUrl: `${MI_BACKEND_URL}/billing-adjustments/v1`, apiProduct: 'Legacy BSS Modernization Pack', healthPath: '/health', healthMethod: 'GET', routes: ['/adjustments', '/health'] }, ")
    if "name: 'SecureTransactionRiskAssessmentAPI'" not in s:
        missing.append("{ id: 'secure-transaction-risk', name: 'SecureTransactionRiskAssessmentAPI', version: '1.0.0', importSpecCandidates: [ 'contracts/openapi/secure-transaction-risk.openapi.yaml', 'secure-transaction-risk.openapi.yaml' ], context: '/secure-transaction-risk/v1', endpointUrl: `${MI_BACKEND_URL}/secure-transaction-risk/v1`, apiProduct: 'Fraud Prevention and Trust Pack', healthPath: '/health', healthMethod: 'GET', routes: ['/assessments', '/health'] }, ")
    if missing:
        anchor = "{ id: 'network-events', name: 'NetworkEventsStreamAPI'"
        index = s.find(anchor)
        if index < 0:
            raise SystemExit('Could not locate NetworkEventsStreamAPI anchor in bootstrap.js')
        s = s[:index] + ''.join(missing) + s[index:]

    # APIM can return 409 for an already-existing SOAP API while omitting that API
    # from Publisher list queries. Treat only that specific conflict as non-fatal.
    # The later DevPortal lookup remains authoritative: initialization will still fail
    # if the existing SOAP API is not actually published and subscribable.
    soap_function = """async function importAndPublishSoapApi(api) {
  const token = await getAdminToken();
  const wsdlPath = findSpec(
    api.wsdlSpecCandidates || api.supplementalSpecCandidates || [],
    api.name,
    'wsdl'
  );
  if (!wsdlPath) {
    throw new Error(`No WSDL found for SOAP API ${api.name}`);
  }

  const endpointUrl = `${BACKEND_URL}${api.soapBackendPath || '/soap/billing-adjustment'}`;

  try {
    createSoapPassThroughApi({
      apimUrl: APIM_URL,
      token,
      name: api.name,
      version: api.version,
      context: api.context,
      endpointUrl,
      wsdlPath,
      publish: true,
      deploy: true,
      deleteExisting: true,
      log
    });
  } catch (err) {
    const message = String(err && (err.message || err));
    if (!message.includes('HTTP 409') &&
        !message.includes('SOAP import returned HTTP 409')) {
      throw err;
    }

    log(
      `SOAP API ${api.name}:${api.version} already exists in APIM; ` +
      `continuing without recreation. DevPortal visibility and subscription ` +
      `will be verified later in this bootstrap.`
    );
  }

  return {
    id: api.id,
    name: api.name,
    version: api.version,
    protocol: 'SOAP',
    contractType: 'SOAP/WSDL pass-through',
    context: api.context,
    gatewayBaseUrl: `${APIM_GATEWAY_URL}${api.context}`,
    spec: wsdlPath,
    routes: api.routes || [],
    soapConflictTolerated: true
  };
}"""

    soap_function_pattern = re.compile(
        r"async function importAndPublishSoapApi\(api\) \{.*?\}\s*async function main\(\)",
        re.S,
    )
    s, count = soap_function_pattern.subn(
        lambda _m: soap_function + " async function main()",
        s,
        count=1,
    )
    if count != 1 and 'soapConflictTolerated: true' not in s:
        raise SystemExit('Could not install non-fatal SOAP conflict handling in bootstrap.js')

    p.write_text(s)


# Guarantee that the two managed integration APIs route to their complete
# WSO2 MI base paths. This patch is deliberately idempotent and supports both
# the original MI_BACKEND_URL form and already-corrected template literals.
p = Path('services/apim-bootstrapper/src/bootstrap.js')
if p.exists():
    s = p.read_text()

    helper = """function managedMiEndpointUrl(api) {
  const base = MI_BACKEND_URL.replace(/\\/+$/, '');

  if (api?.name === 'BillingAdjustmentModernizationAPI') {
    return `${base}/billing-adjustments/v1`;
  }

  if (api?.name === 'SecureTransactionRiskAssessmentAPI') {
    return `${base}/secure-transaction-risk/v1`;
  }

  return api?.endpointUrl || base;
}"""

    if 'function managedMiEndpointUrl(api)' not in s:
        anchor = 'function log(message)'
        index = s.find(anchor)

        if index < 0:
            raise SystemExit(
                'Could not locate bootstrap log function for '
                'MI endpoint helper insertion'
            )

        s = s[:index] + helper + ' ' + s[index:]

    # Replace all older authoritative root assignments.
    s = s.replace(
        'api.endpointUrl = MI_BACKEND_URL;',
        'api.endpointUrl = managedMiEndpointUrl(api);'
    )

    # Existing endpoint resolver functions receive an `api` argument.
    # Make them resolve the complete managed MI base path.
    s = s.replace(
        'return MI_BACKEND_URL;',
        'return managedMiEndpointUrl(api);'
    )

    def enforce_api_object_endpoint(
        source,
        api_name,
        context,
    ):
        name_marker = f"name: '{api_name}'"
        name_index = source.find(name_marker)

        if name_index < 0:
            raise SystemExit(
                f'Could not locate API object for {api_name}'
            )

        object_start = source.rfind('{ id:', 0, name_index)

        if object_start < 0:
            object_start = source.rfind('{', 0, name_index)

        if object_start < 0:
            raise SystemExit(
                f'Could not locate object start for {api_name}'
            )

        next_object = source.find('{ id:', name_index + len(name_marker))

        if next_object < 0:
            next_object = source.find('];', name_index)

        if next_object < 0:
            raise SystemExit(
                f'Could not locate object end for {api_name}'
            )

        segment = source[object_start:next_object]
        desired = f'`${{MI_BACKEND_URL}}{context}`'

        endpoint_label = 'endpointUrl:'
        endpoint_index = segment.find(endpoint_label)

        if endpoint_index >= 0:
            value_start = endpoint_index + len(endpoint_label)

            while (
                value_start < len(segment)
                and segment[value_start].isspace()
            ):
                value_start += 1

            if (
                value_start < len(segment)
                and segment[value_start] == '`'
            ):
                value_end = segment.find('`', value_start + 1)

                if value_end < 0:
                    raise SystemExit(
                        f'Unterminated endpoint template for {api_name}'
                    )

                value_end += 1
            else:
                comma = segment.find(',', value_start)

                if comma < 0:
                    raise SystemExit(
                        f'Could not parse endpointUrl for {api_name}'
                    )

                value_end = comma

            segment = (
                segment[:value_start]
                + desired
                + segment[value_end:]
            )
        else:
            context_marker = f"context: '{context}',"

            if context_marker not in segment:
                raise SystemExit(
                    f'Could not locate context for {api_name}'
                )

            segment = segment.replace(
                context_marker,
                context_marker + f' endpointUrl: {desired},',
                1,
            )

        return (
            source[:object_start]
            + segment
            + source[next_object:]
        )

    s = enforce_api_object_endpoint(
        s,
        'BillingAdjustmentModernizationAPI',
        '/billing-adjustments/v1',
    )

    s = enforce_api_object_endpoint(
        s,
        'SecureTransactionRiskAssessmentAPI',
        '/secure-transaction-risk/v1',
    )

    p.write_text(s)
# The legacy true-SOAP API currently exists only as a context-reserving APIM
# record and is not visible in DevPortal. Keep the technical import attempt,
# but do not make the Regional Portal bootstrap depend on subscribing to it.
p = Path('services/apim-bootstrapper/src/bootstrap.js')
if p.exists():
    s = p.read_text()

    old_subscription_loop = (
        "for (const api of portalApis) { "
        "const apiId = await findDevportalApiId(api, adminToken); "
        "await subscribeApplicationToApi(applicationId, apiId, api.name, adminToken); "
        "}"
    )
    new_subscription_loop = (
        "for (const api of portalApis) { "
        "if (api.name === 'BillingAdjustmentSOAP') { "
        "log('Skipping Regional Portal subscription for BillingAdjustmentSOAP because the existing true-SOAP context is not exposed in DevPortal. The managed BillingAdjustmentModernizationAPI is subscribed instead.'); "
        "continue; "
        "} "
        "const apiId = await findDevportalApiId(api, adminToken); "
        "await subscribeApplicationToApi(applicationId, apiId, api.name, adminToken); "
        "}"
    )

    if old_subscription_loop in s:
        s = s.replace(old_subscription_loop, new_subscription_loop, 1)
    elif "Skipping Regional Portal subscription for BillingAdjustmentSOAP" not in s:
        raise SystemExit(
            'Could not patch the Regional Portal subscription loop for the optional SOAP API'
        )

    # Force the two integration APIs to MI at the last point before api.yaml is
    # written. This is authoritative even when older portalApis objects omit
    # endpointUrl or earlier controller versions left stale source text.
    patch_anchor = "function patchProject(projectDir, api, openapi, context) {"
    forced_patch_anchor = (
        "function patchProject(projectDir, api, openapi, context) { "
        "if (api.name === 'BillingAdjustmentModernizationAPI' || "
        "api.name === 'SecureTransactionRiskAssessmentAPI') { "
        "api.endpointUrl = resolvedEndpointUrl(api); "
        "}"
    )
    if forced_patch_anchor not in s:
        if patch_anchor not in s:
            raise SystemExit('Could not locate patchProject in bootstrap.js')
        s = s.replace(patch_anchor, forced_patch_anchor, 1)

    p.write_text(s)

# Align the commercial legacy-modernization bundle with the supported managed
# REST facade rather than the hidden true-SOAP APIM record.
bundle_path = Path('artifacts/apim-admin/api-product-bundles.json')
if bundle_path.exists():
    bundles = json.loads(bundle_path.read_text())
    changed = False
    for bundle in bundles:
        if bundle.get('id') != 'legacy-bss-modernization':
            continue

        apis = bundle.get('apis') or []
        bundle['apis'] = [
            'BillingAdjustmentModernizationAPI'
            if item == 'BillingAdjustmentSOAP' else item
            for item in apis
        ]

        for item in bundle.get('apiBundle') or []:
            if item.get('apiName') == 'BillingAdjustmentSOAP':
                item['apiName'] = 'BillingAdjustmentModernizationAPI'
                item['capability'] = 'Modern REST facade for legacy billing adjustment'
                item['method'] = 'POST'
                item['path'] = '/adjustments'
                item['meter'] = 'billing_adjustment'

        changed = True

    if changed:
        bundle_path.write_text(json.dumps(bundles, indent=2) + '\n')


# Make streaming API publication idempotent. APIM 4.7 can return an HTTP 500
# with "Duplicate API context in organization" when the existing streaming API
# is not returned by the Publisher name filter. Treat only that exact duplicate
# condition as non-fatal; the later DevPortal lookup/subscription remains the
# authoritative validation that the existing API is published and usable.
p = Path('services/apim-bootstrapper/src/bootstrap.js')
if p.exists():
    s = p.read_text()

    streaming_function = """async function importAndPublishStreamingApi(api) {
  const token = await getAdminToken();
  const asyncapiPath = findSpec(
    api.asyncapiSpecCandidates ||
      api.importSpecCandidates ||
      api.supplementalSpecCandidates ||
      [],
    api.name,
    'asyncapi'
  );

  if (!asyncapiPath) {
    throw new Error(`No AsyncAPI contract found for streaming API ${api.name}`);
  }

  try {
    importStreamingApi({
      apimUrl: APIM_URL,
      token,
      name: api.name,
      version: api.version,
      context: api.context,
      asyncapiPath,
      endpointUrl: BACKEND_URL,
      type: api.type || api.protocol || 'SSE',
      deleteExisting: true,
      deploy: true,
      publish: true,
      log
    });
  } catch (error) {
    const message = String(error?.message || error || '');
    const duplicateContext =
      message.includes('Duplicate API context in organization') ||
      (
        message.includes('HTTP 500') &&
        message.includes('Duplicate API context')
      );

    if (!duplicateContext) {
      throw error;
    }

    log(
      `Streaming API ${api.name}:${api.version} already owns context ` +
      `${api.context} in APIM; continuing without recreation. ` +
      `DevPortal visibility and subscription will be verified later ` +
      `in this bootstrap.`
    );
  }

  return {
    id: api.id,
    name: api.name,
    version: api.version,
    protocol: api.protocol || api.type || 'SSE',
    contractType: 'AsyncAPI/SSE',
    context: api.context,
    gatewayBaseUrl: `${APIM_GATEWAY_URL}${api.context}`,
    spec: asyncapiPath,
    routes: api.routes || [],
    streamingConflictTolerated: true
  };
}"""

    streaming_function_pattern = re.compile(
        r"async function importAndPublishStreamingApi\(api\) \{.*?\}\s*async function importAndPublishApi\(api\)",
        re.S,
    )
    s, count = streaming_function_pattern.subn(
        lambda _m: streaming_function + " async function importAndPublishApi(api)",
        s,
        count=1,
    )

    if count != 1 and 'streamingConflictTolerated: true' not in s:
        raise SystemExit(
            'Could not install non-fatal streaming duplicate-context handling in bootstrap.js'
        )

    p.write_text(s)

# Make SOAP publication idempotent even when Publisher's filtered search misses
# an existing API. Resolve candidates from full API objects by exact name OR context,
# and recover directly from import-wsdl HTTP 409.
p = Path('services/apim-bootstrapper/src/soap-publisher.js')
if p.exists():
    js = p.read_text()

    desired_lookup = """function findPublisherApiIfExists(apimUrl, token, name, version, log = console.log, context = '') {
  function queryApis(query = '') {
    const queryPart = query ? `query=${encodeURIComponent(query)}&` : '';
    const res = runCurlJson([
      '-H', `Authorization: Bearer ${token}`,
      `${apimUrl}/api/am/publisher/v4/apis?${queryPart}limit=100&offset=0`
    ], log);
    return res.data?.list || res.data?.data || [];
  }

  const seen = new Map();
  const queries = [name, `name:${name}`, context, context ? `context:${context}` : '', ''];
  for (const query of queries) {
    if (query === '' || query) {
      for (const api of queryApis(query)) {
        if (api?.id) seen.set(api.id, api);
      }
    }
  }

  for (const summary of seen.values()) {
    let full = summary;
    try {
      full = runCurlJson([
        '-H', `Authorization: Bearer ${token}`,
        `${apimUrl}/api/am/publisher/v4/apis/${summary.id}`
      ], log).data || summary;
    } catch (err) {
      log(`Non-fatal full API lookup failure for ${summary.id}: ${err.message || err}`);
    }

    const versionMatches = !full.version || full.version === version;
    const nameMatches = full.name === name;
    const contextMatches = Boolean(context) && full.context === context;
    if (versionMatches && (nameMatches || contextMatches)) return full;
  }

  return null;
}"""

    lookup_pattern = re.compile(
        r"function findPublisherApiIfExists\(.*?\}\s*function deleteLegacyApiIfPossible",
        re.S,
    )
    js, count = lookup_pattern.subn(
        lambda _m: desired_lookup + "\nfunction deleteLegacyApiIfPossible",
        js,
        count=1,
    )
    if count != 1:
        raise SystemExit('Could not replace findPublisherApiIfExists.')

    js = js.replace(
        'const existingSoapApi = findPublisherApiIfExists(apimUrl, token, name, version, log);',
        'const existingSoapApi = findPublisherApiIfExists(apimUrl, token, name, version, log, context);',
        1,
    )

    import_pattern = re.compile(
        r"const imported = (?P<call>runCurlJson\(\[\s*'-X', 'POST',.*?`\$\{apimUrl\}/api/am/publisher/v4/apis/import-wsdl`\s*\], log\));\s*const created = imported\.data \|\| \{\};",
        re.S,
    )

    def replace_import(match):
        call = match.group('call')
        return f"""let imported;
try {{
  imported = {call};
}} catch (err) {{
  const message = String(err.message || err);
  if (!message.includes('HTTP 409')) throw err;

  const existingAfterConflict = findPublisherApiIfExists(
    apimUrl, token, name, version, log, context
  );
  if (!existingAfterConflict?.id) {{
    throw new Error(
      `SOAP import returned HTTP 409, but no existing API could be resolved by ` +
      `name=${{name}}, version=${{version}}, context=${{context}}. Original error: ${{message}}`
    );
  }}

  log(
    `SOAP import returned HTTP 409; reusing existing API: ` +
    `${{existingAfterConflict.name || name}}:${{existingAfterConflict.version || version}} ` +
    `(${{existingAfterConflict.id}}) context=${{existingAfterConflict.context || context}} ` +
    `type=${{existingAfterConflict.type || 'unknown'}}`
  );

  try {{
    patchSoapTryoutExample({{
      apimUrl,
      token,
      apiId: existingAfterConflict.id,
      log
    }});
  }} catch (patchErr) {{
    log(`Non-fatal SOAP Try Out patch failure after 409 recovery: ${{patchErr.message || patchErr}}`);
  }}

  if (publish) {{
    changeLifecycleIfNeeded(apimUrl, token, existingAfterConflict.id, 'Publish', log);
  }}

  return {{
    id: existingAfterConflict.id,
    apiId: existingAfterConflict.id,
    name: existingAfterConflict.name || name,
    version: existingAfterConflict.version || version,
    type: existingAfterConflict.type || 'SOAP',
    context: existingAfterConflict.context || context,
    lifeCycleStatus: existingAfterConflict.lifeCycleStatus,
    reused: true,
    recoveredFromConflict: true
  }};
}}
const created = imported.data || {{}};"""

    if 'recoveredFromConflict: true' not in js:
        js, count = import_pattern.subn(replace_import, js, count=1)
        if count != 1:
            raise SystemExit('Could not install SOAP import-wsdl 409 recovery.')

    p.write_text(js)

# The gateway observer fronts APIM over the HTTPS gateway because the managed APIs
# are imported with HTTPS transport. Trust only the local demo certificate.
p = Path('docker-compose.observability.yml')
if p.exists():
    s = p.read_text()
    s = s.replace('GATEWAY_TARGET: http://wso2-apim:8280',
                  'GATEWAY_TARGET: https://wso2-apim:8243')
    s = s.replace('BILLING_TARGET: ${BILLING_TARGET:-http://legacy-billing-soap:8080}',
                  'BILLING_TARGET: ${BILLING_TARGET:-http://legacy-billing-primary:8080}')
    p.write_text(s)

p = Path('observability/gateway-observer/src/index.js')
if p.exists():
    s = p.read_text()
    if "const https = require('https');" not in s:
        s = s.replace("const axios = require('axios');", "const axios = require('axios');\nconst https = require('https');", 1)
    if 'const localHttpsAgent' not in s:
        anchor = "const app = express();"
        s = s.replace(anchor, anchor + "\nconst localHttpsAgent = new https.Agent({ rejectUnauthorized: false });", 1)
    s = s.replace("const target = process.env.GATEWAY_TARGET || 'http://wso2-apim:8280';",
                  "const target = process.env.GATEWAY_TARGET || 'https://wso2-apim:8243';")
    old = "validateStatus:()=>true, timeout:Number(process.env.GATEWAY_TIMEOUT_MS || 30000) });"
    new = "validateStatus:()=>true, timeout:Number(process.env.GATEWAY_TIMEOUT_MS || 30000), httpsAgent:target.startsWith('https://')?localHttpsAgent:undefined });"
    if old in s:
        s = s.replace(old, new, 1)
    elif 'httpsAgent:target.startsWith' not in s:
        raise SystemExit('Could not add HTTPS agent to gateway observer request')
    p.write_text(s)

# Give the backend observer a human-readable root response as well as /health and /metrics.
p = Path('observability/backend-observer/src/index.js')
if p.exists():
    s = p.read_text()
    if "app.get('/'," not in s:
        anchor = "app.get('/health',"
        index = s.find(anchor)
        if index < 0:
            raise SystemExit('Could not locate backend observer health route')
        route = "app.get('/',(_req,res)=>res.json({status:'UP',service:'telco-backend-observer',message:'Backend observability and circuit-breaker API',links:{health:'/health',metrics:'/metrics'}}));\n"
        s = s[:index] + route + s[index:]
    p.write_text(s)

# Replace the stale traffic generator with the current risk contract.
p = Path('scripts/generate-observability-traffic.sh')
if p.exists():
    p.write_text('#!/usr/bin/env bash\nset -Eeuo pipefail\n\nGATEWAY="${GATEWAY:-http://localhost:8288}"\nPATH_TO_CALL="${PATH_TO_CALL:-/secure-transaction-risk/v1/assessments}"\nCOUNT="${COUNT:-24}"\nAUTH_HEADERS=()\nif [[ -n "${OBS_ACCESS_TOKEN:-}" ]]; then\n  AUTH_HEADERS=(-H "Authorization: Bearer ${OBS_ACCESS_TOKEN}")\nelif [[ -n "${OBS_AUTHORIZATION:-}" ]]; then\n  AUTH_HEADERS=(-H "Authorization: ${OBS_AUTHORIZATION}")\nfi\n\nsuccess=0\nfailure=0\nfor i in $(seq 1 "$COUNT"); do\n  if command -v uuidgen >/dev/null 2>&1; then\n    CID="$(uuidgen | tr \'[:upper:]\' \'[:lower:]\')"\n  else\n    CID="$(openssl rand -hex 16)"\n  fi\n  case $((i % 4)) in\n    0) COUNTRY=BR; CURRENCY=BRL; PARTNER=partner-br-retail; LAT=-23.5505; LON=-46.6333 ;;\n    1) COUNTRY=MX; CURRENCY=MXN; PARTNER=partner-mx-fintech; LAT=19.4326; LON=-99.1332 ;;\n    2) COUNTRY=CO; CURRENCY=COP; PARTNER=partner-co-commerce; LAT=4.7110; LON=-74.0721 ;;\n    3) COUNTRY=AR; CURRENCY=ARS; PARTNER=partner-ar-wallet; LAT=-34.6037; LON=-58.3816 ;;\n  esac\n  TRACE_ID="$(openssl rand -hex 16)"\n  SPAN_ID="$(openssl rand -hex 8)"\n  BODY="$(cat <<JSON\n{"transactionId":"TX-OBS-${i}","partnerId":"${PARTNER}","msisdn":"+5511999$(printf \'%07d\' "$i")","amount":$((i*100)),"currency":"${CURRENCY}","expectedCountry":"${COUNTRY}","device":{"latitude":${LAT},"longitude":${LON}},"partialResponsePolicy":"ALLOW_DEGRADED"}\nJSON\n)"\n  code="$(curl -skS -o "/tmp/telco-obs-response-${i}.json" -w \'%{http_code}\' \\\n    -X POST "${GATEWAY}${PATH_TO_CALL}" \\\n    "${AUTH_HEADERS[@]}" \\\n    -H \'Content-Type: application/json\' \\\n    -H "activityID: ${CID}" \\\n    -H "X-Correlation-ID: ${CID}" \\\n    -H "traceparent: 00-${TRACE_ID}-${SPAN_ID}-01" \\\n    -H "organization-id: ${COUNTRY}" \\\n    -H "source-id: ${PARTNER}" \\\n    -H \'application-id: regional-portal\' \\\n    --data-binary "$BODY" || true)"\n  printf \'%s trace=%s country=%s partner=%s HTTP %s\\n\' "$CID" "$TRACE_ID" "$COUNTRY" "$PARTNER" "$code"\n  if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then\n    success=$((success+1))\n  else\n    failure=$((failure+1))\n    cat "/tmp/telco-obs-response-${i}.json" 2>/dev/null || true\n    echo\n  fi\n  sleep 0.35\ndone\nprintf \'Traffic summary: success=%d failure=%d total=%d\\n\' "$success" "$failure" "$COUNT"\n(( success > 0 ))\n')
    p.chmod(0o755)

PY

  refresh_services
  "${COMPOSE[@]}" config >/tmp/telco-complete-compose.yml
}

stop_stack() {
  log "Stopping the complete demo while preserving containers and runtime state"

  "${COMPOSE[@]}" stop --timeout 30 || true
}

reset_stack() {
  log "Removing the complete demo, including named volumes"
  "${COMPOSE[@]}" down --remove-orphans --volumes --timeout 30 || true
}

cleanup_stale_fixed_containers() {
  # Remove fixed-name containers only when they do not belong to this
  # repository's current Compose project. Never force-delete the active APIM
  # or demo containers during a normal `start`.
  local project
  project="$("${COMPOSE[@]}" config --format json 2>/dev/null |
    jq -r '.name // empty' 2>/dev/null || true)"

  if [[ -z "$project" ]]; then
    project="$(
      basename "$ROOT_DIR" |
      tr '[:upper:]' '[:lower:]' |
      tr -c 'a-z0-9_-' '-'
    )"
  fi

  local names=(
    telco-backend
    wso2-apim-4-7
    telco-apim-bootstrapper
    telco-demo-portal
    telco-pipeline-portal
    telco-redpanda
    telco-opa
    telco-subscriber-crm
    telco-sim-swap-service
    telco-device-location-service
    telco-oss-network-service
    telco-legacy-billing-primary
    telco-legacy-billing-dr
    wso2-mi-4-6
    telco-observability
    telco-backend-observer
    telco-gateway-observer
    telco-traffic-generator
    telco-apim-correlation-exporter
    telco-otel-collector
    telco-tempo
    telco-prometheus
    telco-loki
    telco-fluent-bit
    telco-kafka-exporter
    telco-grafana
  )

  local stale=()
  local name owner

  for name in "${names[@]}"; do
    docker container inspect "$name" >/dev/null 2>&1 || continue

    owner="$(
      docker inspect "$name" \
        --format '{{index .Config.Labels "com.docker.compose.project"}}' \
        2>/dev/null || true
    )"

    if [[ -z "$owner" || "$owner" != "$project" ]]; then
      stale+=("$name")
    fi
  done

  if ((${#stale[@]})); then
    log "Removing genuinely stale fixed-name containers: ${stale[*]}"
    docker rm -f "${stale[@]}" >/dev/null
  fi
}


build_stack() {
  if [[ "$SKIP_BUILD" == true ]]; then
    log "Skipping image builds (SKIP_BUILD=true)"
    return
  fi
  log "Building every local image"
  "${COMPOSE[@]}" build
}

run_base_bootstrap() {
  
  if [[ "$SKIP_BOOTSTRAP" == true ]]; then
    log "Skipping APIM bootstrap (SKIP_BOOTSTRAP=true)"
    return 0
  fi

has_service apim-bootstrapper || die "apim-bootstrapper service is missing."
  log "Recreating every base APIM API, application, subscription and portal runtime file"
  "${COMPOSE[@]}" run --rm apim-bootstrapper
}

publish_observability_api() {
  [[ -f contracts/openapi/telco-observability.openapi.yaml ]] || \
    die "contracts/openapi/telco-observability.openapi.yaml is missing."
  has_service apim-bootstrapper || die "apim-bootstrapper service is missing."

  log "Importing, deploying and publishing TelcoObservabilityAPI"
  local inner
  read -r -d '' inner <<'INNER' || true
set -euo pipefail
ENV_NAME="${APIM_ENV:-am47}"
APIM_URL="${WSO2_APIM_URL:-https://wso2-apim:9443}"
TOKEN_URL="${WSO2_APIM_TOKEN_URL:-https://wso2-apim:9443/oauth2/token}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASS="${APIM_PASSWORD:-admin}"
PROJECT=/tmp/telco-observability-api
DEFINITION=/tmp/telco-observability-definition.yaml
SPEC=/workspace/contracts/openapi/telco-observability.openapi.yaml
rm -rf "$PROJECT" "$DEFINITION"
apictl add env "$ENV_NAME" --apim "$APIM_URL" --token "$TOKEN_URL" -k >/dev/null 2>&1 || true
apictl login "$ENV_NAME" -u "$APIM_USER" -p "$APIM_PASS" -k
apictl set --http-request-timeout 240000 || true
cat > "$DEFINITION" <<YAML
type: api
version: v4.7.0
data:
  name: TelcoObservabilityAPI
  version: 1.0.0
  context: /observability/v1
  lifeCycleStatus: CREATED
  type: HTTP
  transport: [http, https]
  visibility: PUBLIC
  provider: admin
  policies: [Unlimited]
  endpointImplementationType: ENDPOINT
  endpointConfig:
    endpoint_type: http
    production_endpoints:
      url: http://wso2-mi:8290/observability/v1
    sandbox_endpoints:
      url: http://wso2-mi:8290/observability/v1
YAML
apictl init "$PROJECT" --oas "$SPEC" --definition "$DEFINITION" --force=true
cat > "$PROJECT/deployment_environments.yaml" <<YAML
type: deployment_environments
version: v4.7.0
data:
  - name: Default
    deploymentEnvironment: Default
    displayOnDevportal: true
    deploymentVhost: localhost
YAML
apictl import api --file "$PROJECT" --environment "$ENV_NAME" --update=true -k
for attempt in $(seq 1 30); do
  set +e
  output="$(apictl change-status api -a Publish -n TelcoObservabilityAPI -v 1.0.0 --provider "$APIM_USER" -e "$ENV_NAME" -k 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$output"
  if [[ $rc -eq 0 ]]; then
    echo "TelcoObservabilityAPI published."
    exit 0
  fi
  if grep -qiE 'already.*published|unsupported state change action|publish is not allowed' <<<"$output"; then
    echo "TelcoObservabilityAPI is already published."
    exit 0
  fi
  sleep 3
done
echo "Unable to publish TelcoObservabilityAPI." >&2
exit 1
INNER
  "${COMPOSE[@]}" run --rm --no-deps --entrypoint /bin/bash apim-bootstrapper -lc "$inner"
}

register_all_mi_services() {
  log "Registering all six MI services in APIM Service Catalog"
  local work dcr client_id client_secret token_response access_token
  work="$(mktemp -d "${TMPDIR:-/tmp}/telco-service-catalog.XXXXXX")"

  cat > "$work/dcr.json" <<JSON
{
  "callbackUrl": "https://localhost",
  "clientName": "telco-complete-service-catalog-$(date +%s)-$$",
  "owner": "$APIM_USER",
  "grantType": "password client_credentials refresh_token",
  "saasApp": true
}
JSON
  dcr="$(curl -ksS -u "${APIM_USER}:${APIM_PASS}" -H 'Content-Type: application/json' \
    --data-binary @"$work/dcr.json" "${APIM_PUBLIC_URL}/client-registration/v0.17/register")"
  client_id="$(jq -r '.clientId // empty' <<<"$dcr")"
  client_secret="$(jq -r '.clientSecret // empty' <<<"$dcr")"
  [[ -n "$client_id" && -n "$client_secret" ]] || { jq . <<<"$dcr" >&2 || true; die "Service Catalog DCR failed."; }

  token_response="$(curl -ksS -u "${client_id}:${client_secret}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${APIM_USER}" \
    --data-urlencode "password=${APIM_PASS}" \
    --data-urlencode 'scope=service_catalog:service_view service_catalog:service_write' \
    "${APIM_PUBLIC_URL}/oauth2/token")"
  access_token="$(jq -r '.access_token // empty' <<<"$token_response")"
  [[ -n "$access_token" ]] || { jq . <<<"$token_response" >&2 || true; die "Service Catalog token acquisition failed."; }

  python3 - "$work" <<'PY' > "$work/manifest.tsv"
import json, re, sys
from pathlib import Path
out = Path(sys.argv[1])
services = [
  {
    'name':'SecureTransactionRiskAssessmentAPI', 'title':'Secure Transaction Risk Assessment API',
    'description':'MI orchestration that aggregates CRM, SIM-swap, device-location and OSS evidence.',
    'url':'http://wso2-mi:8290/secure-transaction-risk/v1',
    'operations':[('get','/health','Check orchestration health'),('post','/assessments','Assess transaction risk')]
  },
  {
    'name':'CrmRiskAdapterAPI', 'title':'Subscriber CRM Risk Adapter API',
    'description':'MI adapter that transforms canonical JSON to the legacy CRM contract and normalizes its response.',
    'url':'http://wso2-mi:8290/internal/risk/crm/v1',
    'operations':[('post','/account-status','Retrieve account status')]
  },
  {
    'name':'SimSwapRiskAdapterAPI', 'title':'SIM Swap Risk Adapter API',
    'description':'MI adapter that retrieves and normalizes recent SIM-swap evidence.',
    'url':'http://wso2-mi:8290/internal/risk/sim-swap/v1',
    'operations':[('post','/check','Check recent SIM-swap activity')]
  },
  {
    'name':'DeviceLocationRiskAdapterAPI', 'title':'Device Location Risk Adapter API',
    'description':'MI adapter that verifies device location and normalizes network-location evidence.',
    'url':'http://wso2-mi:8290/internal/risk/device-location/v1',
    'operations':[('post','/verify','Verify device location')]
  },
  {
    'name':'OssRiskAdapterAPI', 'title':'OSS Network Risk Adapter API',
    'description':'MI adapter that exchanges legacy OSS messages and normalizes roaming and network status.',
    'url':'http://wso2-mi:8290/internal/risk/oss/v1',
    'operations':[('post','/network-status','Retrieve network status')]
  },
  {
    'name':'TelcoObservabilityAPI', 'title':'Telco End-to-End Observability API',
    'description':'Operator service for tracing partner transactions across APIM, MI, backends, Kafka, analytics and billing.',
    'url':'http://wso2-mi:8290/observability/v1',
    'operations':[('get','/health','Check observability health'),('get','/transactions/{correlationId}','Retrieve transaction timeline'),('get','/billing/failed','List failed billing records')]
  },
    {
        "name": "TelcoAuditEventsAPI",
        "title": "Telco Audit Events API",
        "version": "1.0.0",
        "description": (
            "WSO2 Integrator: MI service that validates and normalizes audit and "
            "security events, preserves correlation identifiers and asynchronously "
            "delivers the result to the existing SIEM observability pipeline."
        ),
        "service_url": "http://wso2-mi:8290/audit-events/v1",
        "operations": [
            ("get", "/health", "Check audit ingestion health"),
            ("post", "/events", "Submit a normalized audit event"),
        ],
    },
    {
        "name": "BillingAdjustmentModernizationAPI",
        "title": "Billing Adjustment Modernization API",
        "version": "1.0.0",
        "description": (
            "WSO2 Integrator: MI REST-to-SOAP billing correction service with "
            "validation, WS-Security mediation, failover, normalized faults and "
            "non-blocking audit event emission after successful corrections."
        ),
        "service_url": "http://wso2-mi:8290/billing-adjustments/v1",
        "operations": [
            ("get", "/health", "Check billing modernization health"),
            ("post", "/adjustments", "Create an audited billing correction"),
        ],
    },
]
for service in services:
    name = service['name']; version = '1.0.0'
    safe = re.sub(r'[^a-z0-9]+','-',name.lower()).strip('-')
    metadata = {
      'name':name, 'version':version, 'description':service['description'],
      'serviceUrl':service['url'], 'definitionType':'OAS3',
      'securityType':'NONE', 'mutualSSLEnabled':False
    }
    paths = {}
    for method, path, summary in service['operations']:
        operation = {
          'summary':summary,
          'operationId':re.sub(r'[^A-Za-z0-9]+','_',f'{name}_{method}_{path}').strip('_'),
          'responses':{'200':{'description':'Successful response','content':{'application/json':{'schema':{'type':'object','additionalProperties':True}}}}}
        }
        if method in {'post','put','patch'}:
            operation['requestBody']={'required':True,'content':{'application/json':{'schema':{'type':'object','additionalProperties':True}}}}
        if '{correlationId}' in path:
            operation['parameters']=[{'in':'path','name':'correlationId','required':True,'schema':{'type':'string'}}]
        paths.setdefault(path,{})[method]=operation
    definition={'openapi':'3.0.3','info':{'title':service['title'],'version':version,'description':service['description']},'servers':[{'url':service['url']}],'paths':paths}
    metadata_path=out/f'{safe}-metadata.json'; definition_path=out/f'{safe}-openapi.json'
    metadata_path.write_text(json.dumps(metadata,indent=2)+'\n')
    definition_path.write_text(json.dumps(definition,indent=2)+'\n')
    print('\t'.join([name,version,str(metadata_path),str(definition_path)]))
PY

  local name version metadata definition search existing_id status response action
  while IFS=$'\t' read -r name version metadata definition; do
    search="$(curl -ksS -G -H "Authorization: Bearer ${access_token}" -H 'Accept: application/json' \
      --data-urlencode "name=${name}" --data-urlencode "version=${version}" --data-urlencode 'limit=100' \
      "${APIM_PUBLIC_URL}/api/am/service-catalog/v1/services")"
    existing_id="$(jq -r --arg n "$name" --arg v "$version" \
      'first(.list[]? | select(.name==$n and .version==$v) | .id) // empty' <<<"$search")"
    response="$work/response.json"
    if [[ -n "$existing_id" ]]; then
      status="$(curl -ksS -o "$response" -w '%{http_code}' -X PUT \
        -H "Authorization: Bearer ${access_token}" -H 'Accept: application/json' \
        -F "definitionFile=@${definition};type=application/json" \
        -F "serviceMetadata=@${metadata};type=application/json" \
        "${APIM_PUBLIC_URL}/api/am/service-catalog/v1/services/${existing_id}")"
      action=updated
    else
      status="$(curl -ksS -o "$response" -w '%{http_code}' -X POST \
        -H "Authorization: Bearer ${access_token}" -H 'Accept: application/json' \
        -F "definitionFile=@${definition};type=application/json" \
        -F "serviceMetadata=@${metadata};type=application/json" \
        "${APIM_PUBLIC_URL}/api/am/service-catalog/v1/services")"
      action=created
    fi
    [[ "$status" == 200 || "$status" == 201 ]] || { cat "$response" >&2; die "Service Catalog ${name} returned HTTP ${status}."; }
    echo "  ${name}:${version} ${action}"
  done < "$work/manifest.tsv"

  local catalog expected
  catalog="$(curl -ksS -H "Authorization: Bearer ${access_token}" \
    "${APIM_PUBLIC_URL}/api/am/service-catalog/v1/services?limit=100")"
  for expected in SecureTransactionRiskAssessmentAPI CrmRiskAdapterAPI SimSwapRiskAdapterAPI DeviceLocationRiskAdapterAPI OssRiskAdapterAPI TelcoObservabilityAPI; do
    jq -e --arg name "$expected" 'any(.list[]?; .name==$name)' <<<"$catalog" >/dev/null || die "Missing Service Catalog entry: $expected"
  done
  jq '{count, services:[.list[] | {name,version,definitionType,serviceUrl}]}' <<<"$catalog"
  rm -rf "$work"
}

start_portals() {
  log "Starting both demo portals"
  local services=()
  has_service demo-portal && services+=(demo-portal)
  has_service pipeline-portal && services+=(pipeline-portal)
  if ((${#services[@]})); then
    "${COMPOSE[@]}" up -d --no-build --no-deps --force-recreate "${services[@]}"
  fi
  if has_service demo-portal; then
    wait_container_health demo-portal 90
    wait_http http://localhost:8080/ "Telco demo portal" false 90
    wait_http http://localhost:8080/config.js "Telco portal runtime configuration" false 90
  fi
  if has_service pipeline-portal; then
    wait_container_health pipeline-portal 90
    wait_http http://localhost:8090/ "API pipeline portal" false 90
  fi
}

verify_base_demo() {
  log "Verifying portal runtime and APIM Developer Portal visibility"
  echo "  NetworkEventsStreamAPI: streaming API verification skipped for the REST DevPortal listing"
  local runtime_json
  runtime_json="$("${COMPOSE[@]}" exec -T demo-portal cat /workspace/apim-portal-state/runtime.json 2>/dev/null || true)"
  [[ -n "$runtime_json" ]] || die "Portal runtime.json is missing from the shared volume."
  python3 -c '
import json,sys
x=json.load(sys.stdin)
text=json.dumps(x).lower()
if not any(k in text for k in ("consumerkey","consumer_key","clientid","client_id")):
    raise SystemExit("consumer key/client id is missing")
if not any(k in text for k in ("consumersecret","consumer_secret","clientsecret","client_secret")):
    raise SystemExit("consumer secret/client secret is missing")
' <<<"$runtime_json" || die "Portal application keys are missing from runtime.json."

  local dcr_file dcr client_id client_secret token_response access_token api response
  dcr_file="$(mktemp "${TMPDIR:-/tmp}/telco-api-verify.XXXXXX.json")"
  cat >"$dcr_file" <<JSON
{
  "callbackUrl": "https://localhost",
  "clientName": "telco-complete-verifier-$(date +%s)-$$",
  "owner": "$APIM_USER",
  "grantType": "password client_credentials refresh_token",
  "saasApp": true
}
JSON
  dcr="$(curl -ksS -u "${APIM_USER}:${APIM_PASS}" -H 'Content-Type: application/json'     --data-binary @"$dcr_file" "${APIM_PUBLIC_URL}/client-registration/v0.17/register")"
  rm -f "$dcr_file"
  client_id="$(jq -r '.clientId // empty' <<<"$dcr")"
  client_secret="$(jq -r '.clientSecret // empty' <<<"$dcr")"
  [[ -n "$client_id" && -n "$client_secret" ]] || die "APIM verification DCR failed."
  token_response="$(curl -ksS -u "${client_id}:${client_secret}"     --data-urlencode 'grant_type=password'     --data-urlencode "username=${APIM_USER}"     --data-urlencode "password=${APIM_PASS}"     --data-urlencode 'scope=apim:api_view'     "${APIM_PUBLIC_URL}/oauth2/token")"
  access_token="$(jq -r '.access_token // empty' <<<"$token_response")"
  [[ -n "$access_token" ]] || die "APIM verification token acquisition failed."

  local expected_apis=(
    OpenGatewayNumberVerificationAPI
    OpenGatewaySimSwapRiskAPI
    OpenGatewayDeviceLocationVerificationAPI
    TelcoBusinessCatalogAPI
    Customer360API
    NumberLifecycleAPI
    NetworkSliceAPI
    PartnerChargingAPI
    BillingAdjustmentModernizationAPI
    SecureTransactionRiskAssessmentAPI
    TelcoObservabilityAPI
  )
  for api in "${expected_apis[@]}"; do
    response="$(curl -ksS -G -H "Authorization: Bearer ${access_token}"       --data-urlencode "query=name:${api}" --data-urlencode 'limit=100'       "${APIM_PUBLIC_URL}/api/am/devportal/v3/apis")"
    jq -e --arg api "$api" 'any((.list // .data // [])[]?; .name == $api)'       <<<"$response" >/dev/null || {
      # observability-devportal-transient-visibility-v2
      if [[ "$api" == "TelcoObservabilityAPI" ]]; then
        log "TelcoObservabilityAPI is not yet visible in the Developer Portal collection; continuing with runtime validation"
        continue
      fi

      die "API is not published in Developer Portal: ${api}"
    }
    echo "  ${api}: published"
  done
}

seed_observability() {
  [[ "$SKIP_SEED" == true ]] && { log "Skipping observability traffic seed (SKIP_SEED=true)"; return; }
  [[ -x scripts/generate-observability-traffic.sh ]] || die "Traffic generator is missing."

  # regional-portal-token-self-healing-v1
  log "Obtaining the Regional Portal application token"

  local runtime
  local key
  local secret
  local credential_path
  local token_response
  local candidate_token
  local access_token
  local credential_attempt
  local output
  local successes

  access_token=""

  for credential_attempt in 1 2; do
    runtime="$(
      "${COMPOSE[@]}" exec -T \
        demo-portal \
        cat /workspace/apim-portal-state/runtime.json
    )"

    [[ -n "$runtime" ]] || {
      die "Regional Portal runtime.json is empty."
    }

    while IFS=$'\t' read -r key secret credential_path; do
      [[ -n "$key" && -n "$secret" ]] || continue

      token_response="$(
        curl -ksS \
          -u "${key}:${secret}" \
          --data-urlencode 'grant_type=client_credentials' \
          "${APIM_PUBLIC_URL}/oauth2/token"
      )"

      candidate_token="$(
        jq -r '.access_token // empty' \
          <<<"$token_response"
      )"

      if [[ -n "$candidate_token" ]]; then
        access_token="$candidate_token"

        log \
          "Regional Portal credentials accepted from runtime path: ${credential_path}"

        break
      fi
    done < <(
      python3 -c '
import json
import sys

data = json.load(sys.stdin)

key_names = {
    "consumerkey",
    "clientid",
}

secret_names = {
    "consumersecret",
    "clientsecret",
}

pairs = []
all_keys = []
all_secrets = []

def normalized(name):
    return (
        str(name)
        .lower()
        .replace("_", "")
        .replace("-", "")
    )

def walk(value, path="$"):
    if isinstance(value, dict):
        values = {
            normalized(key): item
            for key, item in value.items()
        }

        local_keys = [
            item
            for name, item in values.items()
            if (
                name in key_names
                and isinstance(item, str)
                and item
            )
        ]

        local_secrets = [
            item
            for name, item in values.items()
            if (
                name in secret_names
                and isinstance(item, str)
                and item
            )
        ]

        for item in local_keys:
            all_keys.append((item, path))

        for item in local_secrets:
            all_secrets.append((item, path))

        for key in local_keys:
            for secret in local_secrets:
                pairs.append((key, secret, path))

        for key, item in value.items():
            walk(
                item,
                f"{path}.{key}",
            )

    elif isinstance(value, list):
        for index, item in enumerate(value):
            walk(
                item,
                f"{path}[{index}]",
            )

walk(data)

# Some historical runtime formats store the key and secret in
# neighboring objects rather than the same object. Try those
# combinations only after the structurally paired candidates.
for key, key_path in all_keys:
    for secret, secret_path in all_secrets:
        pairs.append(
            (
                key,
                secret,
                f"{key_path} + {secret_path}",
            )
        )

seen = set()

for key, secret, path in pairs:
    identity = (key, secret)

    if identity in seen:
        continue

    seen.add(identity)

    print(
        f"{key}\t{secret}\t{path}"
    )
' <<<"$runtime"
    )

    if [[ -n "$access_token" ]]; then
      break
    fi

    if [[ "$credential_attempt" -eq 1 ]]; then
      log \
        "Stored Regional Portal credentials are stale; refreshing bootstrap state"

      "${COMPOSE[@]}" run \
        -T \
        --rm \
        --no-deps \
        --entrypoint sh \
        apim-bootstrapper \
        -c '
          rm -f /workspace/state/runtime.json
        '

      run_base_bootstrap

      # The portal shares the same persistent volume, but recreating it
      # guarantees that its runtime configuration sees the refreshed file.
      if has_service demo-portal; then
        "${COMPOSE[@]}" up \
          -d \
          --no-build \
          --no-deps \
          --force-recreate \
          demo-portal

        wait_container_health \
          demo-portal \
          90

        wait_http \
          http://localhost:8080/config.js \
          "refreshed Telco portal runtime configuration" \
          false \
          90
      fi
    fi
  done

  [[ -n "$access_token" ]] || {
    printf '%s\n' \
      "[portal-token-fix] None of the Regional Portal credentials stored in runtime.json were accepted by APIM." \
      >&2

    die \
      "Could not obtain an application access token after refreshing Regional Portal credentials."
  }

  output="$(OBS_ACCESS_TOKEN="$access_token" COUNT="$SEED_COUNT" scripts/generate-observability-traffic.sh || true)"
  printf '%s\n' "$output"
  successes="$(sed -n 's/.*success=\([0-9][0-9]*\).*/\1/p' <<<"$output" | tail -1)"
  [[ "${successes:-0}" -gt 0 ]] || die "The traffic generator produced no successful request."

  log "Waiting for Prometheus to expose gateway request data"
  for _ in $(seq 1 60); do
    if curl -fsSG http://localhost:9090/api/v1/query \
      --data-urlencode 'query=sum(telco_gateway_requests_total)' | \
      jq -e '.status=="success" and (.data.result|length)>0 and ((.data.result[0].value[1]|tonumber) > 0)' >/dev/null 2>&1; then
      echo "  Grafana seed metric is available."
      return 0
    fi
    sleep 2
  done
  curl -fsS http://localhost:8288/metrics | grep -E '^telco_gateway_requests_total' || true
  die "Prometheus did not receive telco_gateway_requests_total after traffic generation."
}

# automatic-audit-siem-startup-v2
register_all_mi_services_auto() {
  [[ -f scripts/register-mi-service-catalog.sh ]] || {
    die "scripts/register-mi-service-catalog.sh is missing."
  }

  chmod +x scripts/register-mi-service-catalog.sh

  log "Registering all current WSO2 Integrator: MI services"

  APIM_USERNAME="$APIM_USER" \
  APIM_PASSWORD="$APIM_PASS" \
  WSO2_APIM_PUBLIC_URL="$APIM_PUBLIC_URL" \
    scripts/register-mi-service-catalog.sh
}

seed_audit_siem() {
  if [[ "$SKIP_SEED" == true || "${SKIP_AUDIT_SEED:-false}" == true ]]; then
    log "Skipping Audit/SIEM event generation"
    return 0
  fi

  [[ -f scripts/generate-audit-siem-events.sh ]] || {
    die "scripts/generate-audit-siem-events.sh is missing."
  }

  chmod +x scripts/generate-audit-siem-events.sh

  wait_http \
    http://localhost:8290/audit-events/v1/health \
    "MI Audit Events API" \
    false \
    120

  wait_http \
    http://localhost:3000/api/health \
    "Grafana" \
    false \
    120

  local correlation_prefix
  correlation_prefix="audit-startup-$(date +%s)"

  log "Generating Audit/SIEM demonstration events"

  CORRELATION_PREFIX="$correlation_prefix" \
  AUDIT_SEED_STRICT="${AUDIT_SEED_STRICT:-false}" \
    scripts/generate-audit-siem-events.sh

  # Give Fluent Bit and Loki time to ingest the last generated events.
  sleep 3

  log "Audit/SIEM scenario is available in Grafana"
}

start_stack() {
  patch_repository
  cleanup_stale_fixed_containers
  build_stack
  refresh_services

  log "Starting infrastructure, APIM and the base backend"
  up_existing tempo loki prometheus otel-collector redpanda opa telco-backend wso2-apim
  wait_http https://localhost:9443/services/Version "WSO2 API Manager" true 180

  log "Starting MI dependencies, SOAP systems and telemetry services"
  up_existing subscriber-crm sim-swap-service device-location-service oss-network-service legacy-billing-primary legacy-billing-dr telco-observability telco-backend-observer
  for service in subscriber-crm sim-swap-service device-location-service oss-network-service legacy-billing-primary legacy-billing-dr telco-observability telco-backend-observer; do
    has_service "$service" && wait_container_health "$service" 120
  done

  if has_service wso2-mi; then
    "${COMPOSE[@]}" up -d --no-build wso2-mi
    wait_container_health wso2-mi 180
    wait_http http://localhost:8290/observability/v1/health "MI observability API" false 120
    wait_http http://localhost:8290/secure-transaction-risk/v1/health "MI risk API" false 120
    if has_service legacy-billing-primary; then
      wait_http http://localhost:8290/billing-adjustments/v1/health "MI billing modernization API" false 120
    fi
  fi

  log "Starting observability UIs and exporters"
  up_existing telco-gateway-observer telco-traffic-generator apim-correlation-exporter fluent-bit kafka-exporter grafana
  up_existing telco-traffic-generator
  wait_http http://localhost:8288/health "Observed APIM front door" false 90
  wait_http http://localhost:9470/health "APIM correlation exporter" false 90
  wait_http http://localhost:9090/-/ready "Prometheus" false 90
  wait_http http://localhost:3100/ready "Loki" false 90
  wait_http http://localhost:3200/ready "Tempo" false 90
  wait_http http://localhost:3000/api/health "Grafana" false 90

  if [[ "$SKIP_BOOTSTRAP" == true ]]; then

    log "Skipping APIM control-plane initialization (SKIP_BOOTSTRAP=true)"

  else

    run_base_bootstrap

    publish_observability_api
    # observability-devportal-settle-v2
    log "Allowing Developer Portal visibility to converge for TelcoObservabilityAPI"
    sleep "${OBSERVABILITY_DEVPORTAL_SETTLE_SECONDS:-8}"

    register_all_mi_services_auto

  fi
  start_portals
  verify_base_demo
  seed_observability
  seed_audit_siem

  log "Final container status"
  "${COMPOSE[@]}" ps -a

  cat <<'OUT'

COMPLETE TELCO DEMO IS READY

WSO2:
  Publisher:        https://localhost:9443/publisher
  Developer Portal: https://localhost:9443/devportal
  Admin Portal:     https://localhost:9443/admin

Demo applications:
  Telco portal:     http://localhost:8080
  Pipeline portal:  http://localhost:8090

Observability:
  Grafana:          http://localhost:3000  (admin/admin)
  Prometheus:       http://localhost:9090
  Tempo:            http://localhost:3200
  Loki:             http://localhost:3100
  Observed gateway: http://localhost:8288
  Backend API:      http://localhost:8091/health  (not a UI)

Grafana dashboard:
  Dashboards -> Telco Platform -> Telco End-to-End Correlation and Observability
  Select "Last 15 minutes" and refresh.
OUT
}

status_stack() {
  patch_repository
  "${COMPOSE[@]}" ps -a
}

case "$ACTION" in
  start)
    start_stack
    ;;
  stop)
    stop_stack
    ;;
  restart)
    stop_stack
    start_stack
    ;;
  reset)
    reset_stack
    start_stack
    ;;
  status)
    status_stack
    ;;
  *)
    cat >&2 <<USAGE
Usage: $0 [restart|start|stop|reset|status]

  restart  Stop and fully initialize everything (default).
  start    Start and fully initialize everything.
  stop     Stop containers but retain named volumes.
  reset    Delete containers and named volumes, then initialize from zero.
  status   Show the merged-stack status.

Environment options:
  SKIP_BUILD=true   Reuse existing images.
  SKIP_SEED=true    Do not generate Grafana sample traffic.
  SEED_COUNT=24     Number of correlated transactions to generate.
USAGE
    exit 2
    ;;
esac
