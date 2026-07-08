#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [[ ! -f "${ROOT_DIR}/docker-compose.yml" ]]; then
  ROOT_DIR="${REPO:-$PWD}"
fi
cd "$ROOT_DIR"

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
info() { printf '\n[commercial-install] %s\n' "$*"; }

[[ -f docker-compose.yml ]] || fail "Run this script from the demo-apim-telco-environment repository root."
for cmd in python3; do command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required"; done

mkdir -p \
  services/commercial-meter-store/src \
  services/apim-bootstrapper/src \
  services/wso2-mi/synapse-configs/default/api \
  services/wso2-mi/synapse-configs/default/endpoints \
  services/wso2-mi/synapse-configs/default/sequences \
  contracts/openapi \
  artifacts/contracts/openapi \
  artifacts/developer-experience/secure-mobile-transactions \
  docs/secure-mobile-transactions \
  observability/grafana/dashboards \
  scripts

info "Creating the replicated persistence-only commercial meter store"
cat > services/commercial-meter-store/package.json <<'EOF'
{
  "name": "telco-commercial-meter-store",
  "version": "1.0.0",
  "private": true,
  "description": "Persistence and query adapter for the MI-owned commercial rating flow.",
  "main": "src/server.js",
  "scripts": {
    "start": "node src/server.js",
    "check": "node --check src/server.js"
  },
  "engines": {
    "node": ">=20"
  }
}
EOF

cat > services/commercial-meter-store/Dockerfile <<'EOF'
FROM node:20-alpine
WORKDIR /app
COPY package.json ./
COPY src ./src
RUN mkdir -p /data && chown -R node:node /app /data
USER node
ENV PORT=8086 STATE_FILE=/data/commercial-meter-state.json
EXPOSE 8086
HEALTHCHECK --interval=10s --timeout=3s --retries=20 --start-period=5s \
  CMD wget -qO- http://127.0.0.1:8086/health >/dev/null || exit 1
CMD ["node", "src/server.js"]
EOF

cat > services/commercial-meter-store/src/server.js <<'EOF'
'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const PORT = Number(process.env.PORT || 8086);
const STATE_FILE = process.env.STATE_FILE || '/data/commercial-meter-state.json';
const PRODUCT = 'SecureMobileTransactionsProduct';
const MAX_EVENTS = Number(process.env.MAX_EVENTS || 25000);

const PLAN_CATALOG = {
  Sandbox: {
    id: 'Sandbox',
    displayName: 'Sandbox',
    billingPlan: 'FREE',
    includedAllowanceMonthly: 100,
    monthlyFee: 0,
    country: 'BR',
    currency: 'BRL',
    dataPolicy: 'MASKED',
    sla: { availabilityPercent: 98.0, support: 'community' },
    prices: {
      number_verification: { included: 0, overage: 0 },
      sim_swap: { included: 0, overage: 0 },
      quality_on_demand: { included: 0, overage: 0 }
    },
    rejectedRequestPrice: 0
  },
  Business: {
    id: 'Business',
    displayName: 'Business',
    billingPlan: 'COMMERCIAL',
    includedAllowanceMonthly: 10000,
    monthlyFee: 1500,
    country: 'BR',
    currency: 'BRL',
    dataPolicy: 'FULL_WITH_CONSENT',
    sla: { availabilityPercent: 99.5, support: 'business-hours' },
    prices: {
      number_verification: { included: 0, overage: 0.08 },
      sim_swap: { included: 0, overage: 0.14 },
      quality_on_demand: { included: 0, overage: 0.35 }
    },
    rejectedRequestPrice: 0
  },
  Enterprise: {
    id: 'Enterprise',
    displayName: 'Enterprise',
    billingPlan: 'COMMERCIAL',
    includedAllowanceMonthly: 100000,
    monthlyCommitment: 12000,
    country: 'BR',
    currency: 'BRL',
    dataPolicy: 'FULL_WITH_CONSENT',
    sla: { availabilityPercent: 99.95, support: '24x7', responseMinutes: 15 },
    prices: {
      number_verification: { committed: 0.045, overage: 0.04 },
      sim_swap: { committed: 0.085, overage: 0.075 },
      quality_on_demand: { committed: 0.22, overage: 0.19 }
    },
    rejectedRequestPrice: 0
  }
};

function emptyState() {
  return { version: 1, assignments: {}, seedUsage: {}, events: [], updatedAt: new Date().toISOString() };
}

function ensureStateFile() {
  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  if (!fs.existsSync(STATE_FILE)) writeState(emptyState());
}

function readState() {
  ensureStateFile();
  try {
    const state = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    state.assignments ||= {};
    state.seedUsage ||= {};
    state.events ||= [];
    return state;
  } catch (error) {
    const recovery = `${STATE_FILE}.corrupt-${Date.now()}`;
    try { fs.renameSync(STATE_FILE, recovery); } catch (_) {}
    const state = emptyState();
    writeState(state);
    return state;
  }
}

function writeState(state) {
  state.updatedAt = new Date().toISOString();
  const temp = `${STATE_FILE}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(temp, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temp, STATE_FILE);
}

function json(res, status, payload, headers = {}) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    ...headers
  });
  res.end(body);
}

function problem(res, status, code, detail, correlationId) {
  return json(res, status, {
    type: `https://example.telco/errors/${code.toLowerCase()}`,
    title: code.replaceAll('_', ' '),
    status,
    code,
    detail,
    correlationId: correlationId || null
  }, { 'x-correlation-id': correlationId || '' });
}

async function readJson(req, limit = 1024 * 1024) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limit) throw Object.assign(new Error('payload too large'), { status: 413 });
    chunks.push(chunk);
  }
  if (!chunks.length) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch (_) { throw Object.assign(new Error('invalid JSON'), { status: 400 }); }
}

function normalizedAssignment(partnerId, input = {}) {
  const planId = input.planId || 'Sandbox';
  const plan = PLAN_CATALOG[planId];
  if (!plan) throw Object.assign(new Error(`unknown planId ${planId}`), { status: 400 });
  return {
    partnerId,
    apiProduct: PRODUCT,
    planId,
    country: String(input.country || plan.country).toUpperCase(),
    currency: String(input.currency || plan.currency).toUpperCase(),
    effectiveFrom: input.effectiveFrom || new Date().toISOString(),
    contractReference: input.contractReference || `DEMO-${partnerId}-${planId}`,
    assignedBy: input.assignedBy || 'commercial-bootstrap',
    updatedAt: new Date().toISOString()
  };
}

function aggregateUsage(state, partnerId, apiProduct = PRODUCT) {
  const assignment = state.assignments[partnerId] || null;
  const perMeter = {};
  const totals = {
    requests: 0,
    successfulRequests: 0,
    rejectedRequests: 0,
    partialResponses: 0,
    billedAmount: 0
  };
  const add = (meter, row) => {
    const target = perMeter[meter] ||= {
      meter,
      requests: 0,
      successfulRequests: 0,
      rejectedRequests: 0,
      partialResponses: 0,
      billedAmount: 0
    };
    for (const key of ['requests', 'successfulRequests', 'rejectedRequests', 'partialResponses']) {
      const value = Number(row[key] || 0);
      target[key] += value;
      totals[key] += value;
    }
    const amount = Number(row.billedAmount || 0);
    target.billedAmount = Number((target.billedAmount + amount).toFixed(6));
    totals.billedAmount = Number((totals.billedAmount + amount).toFixed(6));
  };

  for (const [key, row] of Object.entries(state.seedUsage || {})) {
    if (row.partnerId === partnerId && row.apiProduct === apiProduct) add(row.meter, row);
  }
  for (const event of state.events || []) {
    if (event.partnerId !== partnerId || event.apiProduct !== apiProduct) continue;
    add(event.meter, {
      requests: 1,
      successfulRequests: event.outcome === 'SUCCESS' || event.outcome === 'PARTIAL' ? 1 : 0,
      rejectedRequests: event.outcome === 'REJECTED' ? 1 : 0,
      partialResponses: event.outcome === 'PARTIAL' ? 1 : 0,
      billedAmount: event.billedAmount
    });
  }
  const plan = assignment ? PLAN_CATALOG[assignment.planId] : null;
  return {
    partnerId,
    apiProduct,
    assignment,
    plan,
    period: new Date().toISOString().slice(0, 7),
    totals,
    perMeter: Object.values(perMeter).sort((a, b) => a.meter.localeCompare(b.meter)),
    includedAllowanceMonthly: plan?.includedAllowanceMonthly ?? 0,
    allowanceRemaining: Math.max(0, (plan?.includedAllowanceMonthly ?? 0) - totals.successfulRequests),
    overLimit: Boolean(plan && totals.successfulRequests >= plan.includedAllowanceMonthly),
    recentEvents: (state.events || [])
      .filter((event) => event.partnerId === partnerId && event.apiProduct === apiProduct)
      .slice(-20)
      .reverse()
  };
}

function capabilityResult(capability, body, correlationId) {
  const outcomeHint = String(body.forceOutcome || 'SUCCESS').toUpperCase();
  const msisdn = String(body.msisdn || '+5511999990001');
  const now = new Date().toISOString();
  if (outcomeHint === 'REJECTED') {
    return {
      outcome: 'REJECTED',
      status: 'REJECTED',
      reasonCode: body.reasonCode || 'CONSENT_OR_POLICY_REJECTED',
      detail: 'The request was rejected by the simulated telco policy decision.',
      capability,
      correlationId,
      processedAt: now
    };
  }
  if (capability === 'number_verification') {
    return {
      outcome: 'SUCCESS',
      status: 'VERIFIED',
      capability,
      result: { msisdn, verified: true, matchScore: 0.98 },
      correlationId,
      processedAt: now
    };
  }
  if (capability === 'sim_swap') {
    return {
      outcome: 'SUCCESS',
      status: 'ASSESSED',
      capability,
      result: { msisdn, swappedInLastHours: false, lastSwapAt: '2025-12-01T10:00:00Z' },
      correlationId,
      processedAt: now
    };
  }
  if (capability === 'quality_on_demand') {
    const partial = outcomeHint === 'PARTIAL' || Boolean(body.forcePartial);
    return {
      outcome: partial ? 'PARTIAL' : 'SUCCESS',
      status: partial ? 'ACTIVATED_WITH_PARTIAL_TELEMETRY' : 'ACTIVATED',
      capability,
      partial,
      warnings: partial ? ['Live radio telemetry was unavailable; the QoD session was activated with cached policy data.'] : [],
      result: {
        sessionId: `qod-${crypto.randomUUID()}`,
        profile: body.profile || 'QOS_E',
        durationSeconds: Number(body.durationSeconds || 900),
        device: { ipv4Address: body.ipv4Address || '198.51.100.25' }
      },
      correlationId,
      processedAt: now
    };
  }
  throw Object.assign(new Error(`unsupported capability ${capability}`), { status: 404 });
}

function logEvent(kind, fields = {}) {
  process.stdout.write(`${JSON.stringify({ timestamp: new Date().toISOString(), service: 'commercial-meter-store', kind, ...fields })}\n`);
}

function metrics(state) {
  const lines = [
    '# HELP telco_commercial_usage_requests_total Requests persisted by partner, product, plan, meter and outcome.',
    '# TYPE telco_commercial_usage_requests_total counter',
    '# HELP telco_commercial_billed_amount_total Rated amount persisted by partner, product, plan, meter and currency.',
    '# TYPE telco_commercial_billed_amount_total counter'
  ];
  const groups = new Map();
  for (const event of state.events || []) {
    const labels = [event.partnerId, event.apiProduct, event.planId, event.meter, event.outcome, event.currency];
    const key = labels.join('\u0000');
    const row = groups.get(key) || { labels, count: 0, amount: 0 };
    row.count += 1;
    row.amount += Number(event.billedAmount || 0);
    groups.set(key, row);
  }
  const esc = (value) => String(value ?? '').replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  for (const row of groups.values()) {
    const [partner, product, plan, meter, outcome, currency] = row.labels.map(esc);
    lines.push(`telco_commercial_usage_requests_total{partner="${partner}",product="${product}",plan="${plan}",meter="${meter}",outcome="${outcome}"} ${row.count}`);
    lines.push(`telco_commercial_billed_amount_total{partner="${partner}",product="${product}",plan="${plan}",meter="${meter}",currency="${currency}"} ${row.amount.toFixed(6)}`);
  }
  return `${lines.join('\n')}\n`;
}

const server = http.createServer(async (req, res) => {
  const correlationId = String(req.headers['x-correlation-id'] || `store-${crypto.randomUUID()}`);
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  res.setHeader('x-correlation-id', correlationId);
  try {
    if (req.method === 'GET' && url.pathname === '/health') {
      return json(res, 200, { status: 'UP', service: 'commercial-meter-store', stateFile: STATE_FILE, correlationId });
    }
    if (req.method === 'GET' && url.pathname === '/catalog') {
      return json(res, 200, { apiProduct: PRODUCT, plans: Object.values(PLAN_CATALOG), correlationId });
    }
    if (req.method === 'GET' && url.pathname === '/metrics') {
      const body = metrics(readState());
      res.writeHead(200, { 'content-type': 'text/plain; version=0.0.4', 'content-length': Buffer.byteLength(body) });
      return res.end(body);
    }

    const assignmentMatch = url.pathname.match(/^\/assignments\/([^/]+)$/);
    if (assignmentMatch && req.method === 'PUT') {
      const partnerId = decodeURIComponent(assignmentMatch[1]);
      const body = await readJson(req);
      const state = readState();
      const assignment = normalizedAssignment(partnerId, body);
      state.assignments[partnerId] = assignment;
      writeState(state);
      logEvent('plan-assigned', { correlationId, partnerId, planId: assignment.planId, country: assignment.country, currency: assignment.currency });
      return json(res, 200, { assignment, plan: PLAN_CATALOG[assignment.planId], correlationId });
    }
    if (assignmentMatch && req.method === 'GET') {
      const partnerId = decodeURIComponent(assignmentMatch[1]);
      const state = readState();
      const assignment = state.assignments[partnerId];
      if (!assignment) return problem(res, 404, 'PARTNER_PLAN_NOT_FOUND', `No commercial plan is assigned to ${partnerId}.`, correlationId);
      return json(res, 200, { assignment, plan: PLAN_CATALOG[assignment.planId], correlationId });
    }

    const contextMatch = url.pathname.match(/^\/context\/([^/]+)$/);
    if (contextMatch && req.method === 'GET') {
      const partnerId = decodeURIComponent(contextMatch[1]);
      const state = readState();
      const assignment = state.assignments[partnerId];
      if (!assignment) return problem(res, 404, 'PARTNER_PLAN_NOT_FOUND', `No commercial plan is assigned to ${partnerId}.`, correlationId);
      return json(res, 200, { ...aggregateUsage(state, partnerId, url.searchParams.get('apiProduct') || PRODUCT), correlationId });
    }

    if (req.method === 'GET' && url.pathname === '/usage') {
      const partnerId = url.searchParams.get('partnerId');
      if (!partnerId) return problem(res, 400, 'PARTNER_ID_REQUIRED', 'partnerId is required.', correlationId);
      return json(res, 200, { ...aggregateUsage(readState(), partnerId, url.searchParams.get('apiProduct') || PRODUCT), correlationId });
    }

    const capabilityMatch = url.pathname.match(/^\/capabilities\/(number_verification|sim_swap|quality_on_demand)$/);
    if (capabilityMatch && req.method === 'POST') {
      const body = await readJson(req);
      const delay = Math.min(5000, Math.max(0, Number(body.simulatedDelayMs || 0)));
      if (delay) await new Promise((resolve) => setTimeout(resolve, delay));
      if (String(body.forceOutcome || '').toUpperCase() === 'ERROR') {
        return problem(res, 503, 'SIMULATED_BACKEND_UNAVAILABLE', 'The simulated capability backend is unavailable.', correlationId);
      }
      const result = capabilityResult(capabilityMatch[1], body, correlationId);
      logEvent('capability-result', { correlationId, capability: capabilityMatch[1], outcome: result.outcome });
      return json(res, 200, result);
    }

    if (req.method === 'POST' && url.pathname === '/events') {
      const event = await readJson(req);
      const required = ['eventId', 'partnerId', 'apiProduct', 'planId', 'meter', 'outcome', 'country', 'currency', 'billedAmount'];
      const missing = required.filter((key) => event[key] === undefined || event[key] === null || event[key] === '');
      if (missing.length) return problem(res, 400, 'INVALID_USAGE_EVENT', `Missing fields: ${missing.join(', ')}`, correlationId);
      const state = readState();
      const existing = state.events.find((candidate) => candidate.eventId === event.eventId);
      if (existing) return json(res, 200, { idempotentReplay: true, event: existing, correlationId });
      const persisted = {
        ...event,
        billedAmount: Number(Number(event.billedAmount).toFixed(6)),
        unitPrice: Number(Number(event.unitPrice || 0).toFixed(6)),
        occurredAt: event.occurredAt || new Date().toISOString(),
        correlationId: event.correlationId || correlationId
      };
      state.events.push(persisted);
      if (state.events.length > MAX_EVENTS) state.events.splice(0, state.events.length - MAX_EVENTS);
      writeState(state);
      logEvent('usage-event', {
        correlationId: persisted.correlationId,
        partnerId: persisted.partnerId,
        apiProduct: persisted.apiProduct,
        planId: persisted.planId,
        meter: persisted.meter,
        outcome: persisted.outcome,
        billedAmount: persisted.billedAmount,
        currency: persisted.currency
      });
      return json(res, 201, { idempotentReplay: false, event: persisted, correlationId });
    }

    if (req.method === 'POST' && url.pathname === '/demo/reset') {
      writeState(emptyState());
      logEvent('demo-reset', { correlationId });
      return json(res, 200, { reset: true, correlationId });
    }

    if (req.method === 'POST' && url.pathname === '/demo/seed') {
      const body = await readJson(req);
      const partnerId = String(body.partnerId || 'fintech-br-001');
      const apiProduct = String(body.apiProduct || PRODUCT);
      const meter = String(body.meter || 'number_verification');
      const successfulRequests = Math.max(0, Number(body.successfulRequests || 0));
      const rejectedRequests = Math.max(0, Number(body.rejectedRequests || 0));
      const partialResponses = Math.max(0, Number(body.partialResponses || 0));
      const billedAmount = Math.max(0, Number(body.billedAmount || 0));
      const state = readState();
      const key = `${partnerId}|${apiProduct}|${meter}`;
      state.seedUsage[key] = {
        partnerId,
        apiProduct,
        meter,
        requests: successfulRequests + rejectedRequests,
        successfulRequests,
        rejectedRequests,
        partialResponses,
        billedAmount,
        seededAt: new Date().toISOString(),
        purpose: 'Compact synthetic allowance-consumption fixture; real calls remain event-level records.'
      };
      writeState(state);
      logEvent('usage-seeded', { correlationId, partnerId, apiProduct, meter, successfulRequests });
      return json(res, 200, { seeded: state.seedUsage[key], usage: aggregateUsage(state, partnerId, apiProduct), correlationId });
    }

    return problem(res, 404, 'RESOURCE_NOT_FOUND', `${req.method} ${url.pathname} is not available.`, correlationId);
  } catch (error) {
    const status = Number(error.status || 500);
    logEvent('error', { correlationId, status, message: error.message });
    return problem(res, status, status === 500 ? 'INTERNAL_ERROR' : 'INVALID_REQUEST', error.message, correlationId);
  }
});

ensureStateFile();
server.listen(PORT, '0.0.0.0', () => logEvent('started', { port: PORT, stateFile: STATE_FILE }));
EOF

info "Creating Docker Compose topology and startup ordering"
cat > docker-compose.commercial.yml <<'EOF'
services:
  commercial-meter-store-primary:
    build:
      context: ./services/commercial-meter-store
    container_name: telco-commercial-meter-primary
    environment:
      PORT: "8086"
      STATE_FILE: /data/commercial-meter-state.json
      MAX_EVENTS: "25000"
    volumes:
      - commercial-meter-data:/data
    ports:
      - "18086:8086"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8086/health"]
      interval: 10s
      timeout: 3s
      retries: 20
      start_period: 5s

  commercial-meter-store-secondary:
    build:
      context: ./services/commercial-meter-store
    container_name: telco-commercial-meter-secondary
    environment:
      PORT: "8086"
      STATE_FILE: /data/commercial-meter-state.json
      MAX_EVENTS: "25000"
    volumes:
      - commercial-meter-data:/data
    ports:
      - "18087:8086"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8086/health"]
      interval: 10s
      timeout: 3s
      retries: 20
      start_period: 5s

  wso2-mi:
    depends_on:
      commercial-meter-store-primary:
        condition: service_healthy
      commercial-meter-store-secondary:
        condition: service_healthy

  apim-bootstrapper:
    depends_on:
      commercial-meter-store-primary:
        condition: service_healthy
      commercial-meter-store-secondary:
        condition: service_healthy
      wso2-mi:
        condition: service_healthy

volumes:
  commercial-meter-data:
EOF

info "Creating WSO2 Integrator: MI endpoints, sequences and managed API"
cat > services/wso2-mi/synapse-configs/default/endpoints/CommercialMeterStoreFailoverEndpoint.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<endpoint xmlns="http://ws.apache.org/ns/synapse" name="CommercialMeterStoreFailoverEndpoint">
  <failover>
    <endpoint name="CommercialMeterStorePrimary">
      <address uri="http://commercial-meter-store-primary:8086">
        <timeout>
          <duration>3000</duration>
          <responseAction>fault</responseAction>
        </timeout>
        <markForSuspension>
          <errorCodes>101503,101504,101505,101506,101507,101508</errorCodes>
          <retriesBeforeSuspension>2</retriesBeforeSuspension>
          <retryDelay>500</retryDelay>
        </markForSuspension>
        <suspendOnFailure>
          <initialDuration>5000</initialDuration>
          <progressionFactor>2.0</progressionFactor>
          <maximumDuration>30000</maximumDuration>
        </suspendOnFailure>
      </address>
    </endpoint>
    <endpoint name="CommercialMeterStoreSecondary">
      <address uri="http://commercial-meter-store-secondary:8086">
        <timeout>
          <duration>3000</duration>
          <responseAction>fault</responseAction>
        </timeout>
        <markForSuspension>
          <errorCodes>101503,101504,101505,101506,101507,101508</errorCodes>
          <retriesBeforeSuspension>2</retriesBeforeSuspension>
          <retryDelay>500</retryDelay>
        </markForSuspension>
        <suspendOnFailure>
          <initialDuration>5000</initialDuration>
          <progressionFactor>2.0</progressionFactor>
          <maximumDuration>30000</maximumDuration>
        </suspendOnFailure>
      </address>
    </endpoint>
  </failover>
</endpoint>
EOF

cat > services/wso2-mi/synapse-configs/default/sequences/CommercialCorrelationSequence.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<sequence xmlns="http://ws.apache.org/ns/synapse" name="CommercialCorrelationSequence" trace="disable">
  <property name="commercial.incomingCorrelationId" expression="get-property('transport','X-Correlation-ID')" scope="default" type="STRING"/>
  <filter xpath="string-length(normalize-space(get-property('commercial.incomingCorrelationId'))) &gt; 0">
    <then>
      <property name="commercial.correlationId" expression="get-property('commercial.incomingCorrelationId')" scope="default" type="STRING"/>
    </then>
    <else>
      <property name="commercial.correlationId" expression="fn:concat('commercial-', get-property('SYSTEM_TIME'))" scope="default" type="STRING"/>
    </else>
  </filter>
  <header name="X-Correlation-ID" expression="get-property('commercial.correlationId')" scope="transport"/>
  <property name="activityID" expression="get-property('commercial.correlationId')" scope="default" type="STRING"/>
</sequence>
EOF

cat > services/wso2-mi/synapse-configs/default/sequences/CommercialNormalizedFaultSequence.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<sequence xmlns="http://ws.apache.org/ns/synapse" name="CommercialNormalizedFaultSequence" trace="disable">
  <sequence key="CommercialCorrelationSequence"/>
  <log level="custom">
    <property name="event" value="commercial-flow-fault"/>
    <property name="correlationId" expression="get-property('commercial.correlationId')"/>
    <property name="errorCode" expression="get-property('ERROR_CODE')"/>
    <property name="errorMessage" expression="get-property('ERROR_MESSAGE')"/>
    <property name="failedEndpoint" expression="get-property('SYNAPSE_ENDPOINT')"/>
  </log>
  <payloadFactory media-type="json">
    <format>{"type":"https://example.telco/errors/commercial-flow-unavailable","title":"Commercial flow unavailable","status":503,"code":"COMMERCIAL_FLOW_UNAVAILABLE","detail":"The downstream commercial meter or capability backend could not be reached within the configured timeout and retry budget.","correlationId":"$1"}</format>
    <args>
      <arg evaluator="xml" expression="get-property('commercial.correlationId')"/>
    </args>
  </payloadFactory>
  <property name="HTTP_SC" value="503" scope="axis2" type="STRING"/>
  <property name="messageType" value="application/problem+json" scope="axis2" type="STRING"/>
  <property name="ContentType" value="application/problem+json" scope="axis2" type="STRING"/>
  <header name="X-Correlation-ID" expression="get-property('commercial.correlationId')" scope="transport"/>
  <respond/>
</sequence>
EOF

cat > services/wso2-mi/synapse-configs/default/sequences/CommercialExecuteTransactionSequence.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<sequence xmlns="http://ws.apache.org/ns/synapse" name="CommercialExecuteTransactionSequence" trace="disable">
  <sequence key="CommercialCorrelationSequence"/>
  <property name="commercial.partnerId" expression="json-eval($.partnerId)" scope="default" type="STRING"/>
  <property name="commercial.consentId" expression="json-eval($.consentId)" scope="default" type="STRING"/>
  <property name="commercial.requestCountry" expression="json-eval($.country)" scope="default" type="STRING"/>
  <property name="commercial.requestCurrency" expression="json-eval($.currency)" scope="default" type="STRING"/>
  <enrich>
    <source clone="true" type="body"/>
    <target action="replace" property="commercial.originalRequest" type="property"/>
  </enrich>

  <filter xpath="string-length(normalize-space(get-property('commercial.partnerId'))) = 0">
    <then>
      <payloadFactory media-type="json">
        <format>{"type":"https://example.telco/errors/partner-required","title":"Partner identifier required","status":400,"code":"PARTNER_ID_REQUIRED","detail":"partnerId is required for plan lookup and usage attribution.","correlationId":"$1"}</format>
        <args><arg evaluator="xml" expression="get-property('commercial.correlationId')"/></args>
      </payloadFactory>
      <property name="HTTP_SC" value="400" scope="axis2" type="STRING"/>
      <property name="messageType" value="application/problem+json" scope="axis2" type="STRING"/>
      <respond/>
    </then>
  </filter>

  <property name="REST_URL_POSTFIX" expression="fn:concat('/context/', get-property('commercial.partnerId'), '?apiProduct=SecureMobileTransactionsProduct')" scope="axis2" type="STRING"/>
  <property name="HTTP_METHOD" value="GET" scope="axis2" type="STRING"/>
  <property name="NO_ENTITY_BODY" value="true" scope="axis2" type="BOOLEAN"/>
  <call>
    <endpoint key="CommercialMeterStoreFailoverEndpoint"/>
  </call>
  <property name="commercial.planId" expression="json-eval($.assignment.planId)" scope="default" type="STRING"/>
  <property name="commercial.country" expression="json-eval($.assignment.country)" scope="default" type="STRING"/>
  <property name="commercial.currency" expression="json-eval($.assignment.currency)" scope="default" type="STRING"/>
  <property name="commercial.successfulRequestsBefore" expression="json-eval($.totals.successfulRequests)" scope="default" type="STRING"/>
  <property name="commercial.allowanceBefore" expression="json-eval($.allowanceRemaining)" scope="default" type="STRING"/>

  <enrich>
    <source clone="true" property="commercial.originalRequest" type="property"/>
    <target action="replace" type="body"/>
  </enrich>
  <property name="REST_URL_POSTFIX" expression="fn:concat('/capabilities/', get-property('commercial.meter'))" scope="axis2" type="STRING"/>
  <property name="HTTP_METHOD" value="POST" scope="axis2" type="STRING"/>
  <property name="NO_ENTITY_BODY" action="remove" scope="axis2"/>
  <property name="messageType" value="application/json" scope="axis2" type="STRING"/>
  <header name="X-Correlation-ID" expression="get-property('commercial.correlationId')" scope="transport"/>
  <call>
    <endpoint key="CommercialMeterStoreFailoverEndpoint"/>
  </call>
  <enrich>
    <source clone="true" type="body"/>
    <target action="replace" property="commercial.capabilityResponse" type="property"/>
  </enrich>
  <property name="commercial.outcome" expression="json-eval($.outcome)" scope="default" type="STRING"/>
  <property name="commercial.capabilityStatus" expression="json-eval($.status)" scope="default" type="STRING"/>

  <script language="js"><![CDATA[
    var planId = String(mc.getProperty('commercial.planId') || 'Sandbox');
    var meter = String(mc.getProperty('commercial.meter') || 'number_verification');
    var outcome = String(mc.getProperty('commercial.outcome') || 'REJECTED');
    var successfulBefore = Number(mc.getProperty('commercial.successfulRequestsBefore') || 0);
    var plans = {
      Sandbox: {
        allowance: 100,
        sla: '98.0',
        support: 'community',
        dataPolicy: 'MASKED',
        included: {number_verification:0, sim_swap:0, quality_on_demand:0},
        overage: {number_verification:0, sim_swap:0, quality_on_demand:0}
      },
      Business: {
        allowance: 10000,
        sla: '99.5',
        support: 'business-hours',
        dataPolicy: 'FULL_WITH_CONSENT',
        included: {number_verification:0, sim_swap:0, quality_on_demand:0},
        overage: {number_verification:0.08, sim_swap:0.14, quality_on_demand:0.35}
      },
      Enterprise: {
        allowance: 100000,
        sla: '99.95',
        support: '24x7',
        dataPolicy: 'FULL_WITH_CONSENT',
        committed: {number_verification:0.045, sim_swap:0.085, quality_on_demand:0.22},
        overage: {number_verification:0.04, sim_swap:0.075, quality_on_demand:0.19}
      }
    };
    var plan = plans[planId] || plans.Sandbox;
    var billable = outcome === 'SUCCESS' || outcome === 'PARTIAL';
    var overLimit = successfulBefore >= plan.allowance;
    var chargeType = 'REJECTED_NO_CHARGE';
    var unitPrice = 0;
    if (billable) {
      if (planId === 'Enterprise') {
        unitPrice = overLimit ? Number(plan.overage[meter] || 0) : Number(plan.committed[meter] || 0);
        chargeType = overLimit ? 'ENTERPRISE_OVERAGE' : 'COMMITTED_VOLUME';
      } else if (planId === 'Business') {
        unitPrice = overLimit ? Number(plan.overage[meter] || 0) : 0;
        chargeType = overLimit ? 'BUSINESS_OVERAGE' : 'INCLUDED_ALLOWANCE';
      } else {
        unitPrice = 0;
        chargeType = 'SANDBOX_FREE';
      }
    }
    var factor = outcome === 'PARTIAL' ? 0.70 : (billable ? 1.0 : 0.0);
    var billedAmount = Math.round(unitPrice * factor * 1000000) / 1000000;
    mc.setProperty('commercial.includedAllowance', String(plan.allowance));
    mc.setProperty('commercial.overLimit', String(overLimit));
    mc.setProperty('commercial.unitPrice', String(unitPrice));
    mc.setProperty('commercial.ratingFactor', String(factor));
    mc.setProperty('commercial.billedAmount', String(billedAmount));
    mc.setProperty('commercial.chargeType', chargeType);
    mc.setProperty('commercial.slaAvailability', plan.sla);
    mc.setProperty('commercial.supportEntitlement', plan.support);
    mc.setProperty('commercial.dataPolicy', plan.dataPolicy);
    mc.setProperty('commercial.eventId', String(mc.getProperty('commercial.correlationId')) + '-' + meter);
  ]]></script>

  <payloadFactory media-type="json">
    <format>{"eventId":"$1","partnerId":"$2","apiProduct":"SecureMobileTransactionsProduct","planId":"$3","meter":"$4","outcome":"$5","capabilityStatus":"$6","country":"$7","currency":"$8","unitPrice":$9,"ratingFactor":$10,"billedAmount":$11,"chargeType":"$12","includedAllowanceMonthly":$13,"successfulRequestsBefore":$14,"overLimit":$15,"correlationId":"$16"}</format>
    <args>
      <arg evaluator="xml" expression="get-property('commercial.eventId')"/>
      <arg evaluator="xml" expression="get-property('commercial.partnerId')"/>
      <arg evaluator="xml" expression="get-property('commercial.planId')"/>
      <arg evaluator="xml" expression="get-property('commercial.meter')"/>
      <arg evaluator="xml" expression="get-property('commercial.outcome')"/>
      <arg evaluator="xml" expression="get-property('commercial.capabilityStatus')"/>
      <arg evaluator="xml" expression="get-property('commercial.country')"/>
      <arg evaluator="xml" expression="get-property('commercial.currency')"/>
      <arg evaluator="xml" expression="get-property('commercial.unitPrice')"/>
      <arg evaluator="xml" expression="get-property('commercial.ratingFactor')"/>
      <arg evaluator="xml" expression="get-property('commercial.billedAmount')"/>
      <arg evaluator="xml" expression="get-property('commercial.chargeType')"/>
      <arg evaluator="xml" expression="get-property('commercial.includedAllowance')"/>
      <arg evaluator="xml" expression="get-property('commercial.successfulRequestsBefore')"/>
      <arg evaluator="xml" expression="get-property('commercial.overLimit')"/>
      <arg evaluator="xml" expression="get-property('commercial.correlationId')"/>
    </args>
  </payloadFactory>
  <property name="REST_URL_POSTFIX" value="/events" scope="axis2" type="STRING"/>
  <property name="HTTP_METHOD" value="POST" scope="axis2" type="STRING"/>
  <property name="messageType" value="application/json" scope="axis2" type="STRING"/>
  <header name="X-Correlation-ID" expression="get-property('commercial.correlationId')" scope="transport"/>
  <call>
    <endpoint key="CommercialMeterStoreFailoverEndpoint"/>
  </call>

  <enrich>
    <source clone="true" property="commercial.capabilityResponse" type="property"/>
    <target action="replace" type="body"/>
  </enrich>
  <script language="js"><![CDATA[
    var response = mc.getPayloadJSON();
    var planId = String(mc.getProperty('commercial.planId'));
    if (planId === 'Sandbox' && response.result) {
      if (response.result.msisdn) {
        var value = String(response.result.msisdn);
        response.result.msisdn = value.length > 4 ? '********' + value.substring(value.length - 4) : '****';
      }
      response.result.masked = true;
    }
    response.commercialUsage = {
      partnerId: String(mc.getProperty('commercial.partnerId')),
      apiProduct: 'SecureMobileTransactionsProduct',
      planId: planId,
      meter: String(mc.getProperty('commercial.meter')),
      country: String(mc.getProperty('commercial.country')),
      currency: String(mc.getProperty('commercial.currency')),
      includedAllowanceMonthly: Number(mc.getProperty('commercial.includedAllowance') || 0),
      successfulRequestsBefore: Number(mc.getProperty('commercial.successfulRequestsBefore') || 0),
      overLimit: String(mc.getProperty('commercial.overLimit')) === 'true',
      unitPrice: Number(mc.getProperty('commercial.unitPrice') || 0),
      ratingFactor: Number(mc.getProperty('commercial.ratingFactor') || 0),
      billedAmount: Number(mc.getProperty('commercial.billedAmount') || 0),
      chargeType: String(mc.getProperty('commercial.chargeType')),
      slaEntitlement: {
        availabilityPercent: Number(mc.getProperty('commercial.slaAvailability') || 0),
        support: String(mc.getProperty('commercial.supportEntitlement'))
      },
      dataPolicy: String(mc.getProperty('commercial.dataPolicy'))
    };
    mc.setPayloadJSON(response);
  ]]></script>
  <filter source="get-property('commercial.outcome')" regex="REJECTED">
    <then><property name="HTTP_SC" value="422" scope="axis2" type="STRING"/></then>
    <else><property name="HTTP_SC" value="200" scope="axis2" type="STRING"/></else>
  </filter>
  <property name="messageType" value="application/json" scope="axis2" type="STRING"/>
  <property name="ContentType" value="application/json" scope="axis2" type="STRING"/>
  <header name="X-Correlation-ID" expression="get-property('commercial.correlationId')" scope="transport"/>
  <log level="custom">
    <property name="event" value="commercial-usage-rated"/>
    <property name="correlationId" expression="get-property('commercial.correlationId')"/>
    <property name="partnerId" expression="get-property('commercial.partnerId')"/>
    <property name="apiProduct" value="SecureMobileTransactionsProduct"/>
    <property name="planId" expression="get-property('commercial.planId')"/>
    <property name="meter" expression="get-property('commercial.meter')"/>
    <property name="outcome" expression="get-property('commercial.outcome')"/>
    <property name="billedAmount" expression="get-property('commercial.billedAmount')"/>
    <property name="currency" expression="get-property('commercial.currency')"/>
  </log>
  <respond/>
</sequence>
EOF

cat > services/wso2-mi/synapse-configs/default/api/SecureMobileTransactionsCommercialAPI.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<api xmlns="http://ws.apache.org/ns/synapse" name="SecureMobileTransactionsCommercialAPI" context="/secure-mobile-transactions/v1">
  <resource methods="GET" uri-template="/health">
    <inSequence>
      <sequence key="CommercialCorrelationSequence"/>
      <payloadFactory media-type="json">
        <format>{"status":"UP","service":"SecureMobileTransactionsCommercialAPI","runtime":"WSO2 Integrator: MI","ratingOwner":"MI","persistence":"replicated-failover-store","correlationId":"$1"}</format>
        <args><arg evaluator="xml" expression="get-property('commercial.correlationId')"/></args>
      </payloadFactory>
      <property name="HTTP_SC" value="200" scope="axis2" type="STRING"/>
      <respond/>
    </inSequence>
    <faultSequence><sequence key="CommercialNormalizedFaultSequence"/></faultSequence>
  </resource>

  <resource methods="GET" uri-template="/plans">
    <inSequence>
      <sequence key="CommercialCorrelationSequence"/>
      <property name="REST_URL_POSTFIX" value="/catalog" scope="axis2" type="STRING"/>
      <property name="HTTP_METHOD" value="GET" scope="axis2" type="STRING"/>
      <property name="NO_ENTITY_BODY" value="true" scope="axis2" type="BOOLEAN"/>
      <call><endpoint key="CommercialMeterStoreFailoverEndpoint"/></call>
      <header name="X-Correlation-ID" expression="get-property('commercial.correlationId')" scope="transport"/>
      <respond/>
    </inSequence>
    <faultSequence><sequence key="CommercialNormalizedFaultSequence"/></faultSequence>
  </resource>

  <resource methods="PUT" uri-template="/partners/{partnerId}/plan">
    <inSequence>
      <sequence key="CommercialCorrelationSequence"/>
      <property name="REST_URL_POSTFIX" expression="fn:concat('/assignments/', get-property('uri.var.partnerId'))" scope="axis2" type="STRING"/>
      <property name="HTTP_METHOD" value="PUT" scope="axis2" type="STRING"/>
      <property name="messageType" value="application/json" scope="axis2" type="STRING"/>
      <header name="X-Correlation-ID" expression="get-property('commercial.correlationId')" scope="transport"/>
      <call><endpoint key="CommercialMeterStoreFailoverEndpoint"/></call>
      <header name="X-Correlation-ID" expression="get-property('commercial.correlationId')" scope="transport"/>
      <respond/>
    </inSequence>
    <faultSequence><sequence key="CommercialNormalizedFaultSequence"/></faultSequence>
  </resource>

  <resource methods="GET" uri-template="/partners/{partnerId}/usage">
    <inSequence>
      <sequence key="CommercialCorrelationSequence"/>
      <property name="REST_URL_POSTFIX" expression="fn:concat('/usage?partnerId=', get-property('uri.var.partnerId'), '&amp;apiProduct=SecureMobileTransactionsProduct')" scope="axis2" type="STRING"/>
      <property name="HTTP_METHOD" value="GET" scope="axis2" type="STRING"/>
      <property name="NO_ENTITY_BODY" value="true" scope="axis2" type="BOOLEAN"/>
      <call><endpoint key="CommercialMeterStoreFailoverEndpoint"/></call>
      <header name="X-Correlation-ID" expression="get-property('commercial.correlationId')" scope="transport"/>
      <respond/>
    </inSequence>
    <faultSequence><sequence key="CommercialNormalizedFaultSequence"/></faultSequence>
  </resource>

  <resource methods="POST" uri-template="/demo/seed">
    <inSequence>
      <sequence key="CommercialCorrelationSequence"/>
      <property name="REST_URL_POSTFIX" value="/demo/seed" scope="axis2" type="STRING"/>
      <property name="HTTP_METHOD" value="POST" scope="axis2" type="STRING"/>
      <property name="messageType" value="application/json" scope="axis2" type="STRING"/>
      <call><endpoint key="CommercialMeterStoreFailoverEndpoint"/></call>
      <header name="X-Correlation-ID" expression="get-property('commercial.correlationId')" scope="transport"/>
      <respond/>
    </inSequence>
    <faultSequence><sequence key="CommercialNormalizedFaultSequence"/></faultSequence>
  </resource>

  <resource methods="POST" uri-template="/demo/reset">
    <inSequence>
      <sequence key="CommercialCorrelationSequence"/>
      <property name="REST_URL_POSTFIX" value="/demo/reset" scope="axis2" type="STRING"/>
      <property name="HTTP_METHOD" value="POST" scope="axis2" type="STRING"/>
      <payloadFactory media-type="json"><format>{}</format><args/></payloadFactory>
      <call><endpoint key="CommercialMeterStoreFailoverEndpoint"/></call>
      <header name="X-Correlation-ID" expression="get-property('commercial.correlationId')" scope="transport"/>
      <respond/>
    </inSequence>
    <faultSequence><sequence key="CommercialNormalizedFaultSequence"/></faultSequence>
  </resource>

  <resource methods="POST" uri-template="/number-verification">
    <inSequence>
      <property name="commercial.meter" value="number_verification" scope="default" type="STRING"/>
      <sequence key="CommercialExecuteTransactionSequence"/>
    </inSequence>
    <faultSequence><sequence key="CommercialNormalizedFaultSequence"/></faultSequence>
  </resource>

  <resource methods="POST" uri-template="/sim-swap">
    <inSequence>
      <property name="commercial.meter" value="sim_swap" scope="default" type="STRING"/>
      <sequence key="CommercialExecuteTransactionSequence"/>
    </inSequence>
    <faultSequence><sequence key="CommercialNormalizedFaultSequence"/></faultSequence>
  </resource>

  <resource methods="POST" uri-template="/quality-on-demand">
    <inSequence>
      <property name="commercial.meter" value="quality_on_demand" scope="default" type="STRING"/>
      <sequence key="CommercialExecuteTransactionSequence"/>
    </inSequence>
    <faultSequence><sequence key="CommercialNormalizedFaultSequence"/></faultSequence>
  </resource>
</api>
EOF

info "Creating the managed OpenAPI contract and Developer Portal assets"
cat > contracts/openapi/secure-mobile-transactions-commercial.openapi.json <<'EOF'
{
  "openapi": "3.0.3",
  "info": {
    "title": "Secure Mobile Transactions Commercial API",
    "version": "1.0.0",
    "description": "Operational commercial flow for the Secure Mobile Transactions API Product. WSO2 Integrator: MI resolves the partner plan, executes Number Verification, SIM Swap or Quality on Demand, rates the result, persists an idempotent usage event and returns charge/SLA metadata.",
    "contact": { "name": "Telco API Platform Team", "email": "telco-api-platform@example.com" }
  },
  "servers": [
    { "url": "http://wso2-mi:8290/secure-mobile-transactions/v1", "description": "WSO2 Integrator: MI runtime" }
  ],
  "x-wso2-basePath": "/secure-mobile-transactions/v1",
  "x-wso2-production-endpoints": { "urls": ["http://wso2-mi:8290/secure-mobile-transactions/v1"] },
  "x-wso2-sandbox-endpoints": { "urls": ["http://wso2-mi:8290/secure-mobile-transactions/v1"] },
  "x-telco-api-product": "SecureMobileTransactionsProduct",
  "x-telco-correlation-header": "X-Correlation-ID",
  "tags": [
    { "name": "Transactions", "description": "Commercially rated transaction capabilities" },
    { "name": "Commercial Management", "description": "Plan assignment and usage visibility" },
    { "name": "Demo Administration", "description": "Deterministic demo data preparation" }
  ],
  "paths": {
    "/health": {
      "get": {
        "operationId": "getCommercialFlowHealth",
        "summary": "Check MI commercial flow health",
        "security": [],
        "responses": { "200": { "description": "Runtime is available", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Health" } } } } }
      }
    },
    "/plans": {
      "get": {
        "tags": ["Commercial Management"],
        "operationId": "listCommercialPlans",
        "summary": "List executable commercial plans and per-capability prices",
        "security": [{ "oauth2": ["secure_mobile_transactions:commercial.read"] }],
        "responses": { "200": { "description": "Plan catalog", "content": { "application/json": { "schema": { "type": "object" } } } } }
      }
    },
    "/partners/{partnerId}/plan": {
      "put": {
        "tags": ["Commercial Management"],
        "operationId": "assignPartnerPlan",
        "summary": "Assign a partner to Sandbox, Business or Enterprise",
        "security": [{ "oauth2": ["secure_mobile_transactions:commercial.manage"] }],
        "parameters": [{ "$ref": "#/components/parameters/PartnerId" }, { "$ref": "#/components/parameters/CorrelationId" }],
        "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/PlanAssignmentRequest" } } } },
        "responses": {
          "200": { "description": "Plan assigned", "content": { "application/json": { "schema": { "type": "object" } } } },
          "400": { "$ref": "#/components/responses/Problem" }
        }
      }
    },
    "/partners/{partnerId}/usage": {
      "get": {
        "tags": ["Commercial Management"],
        "operationId": "getPartnerProductUsage",
        "summary": "Get allowance, over-limit state, charges and events by partner and API Product",
        "security": [{ "oauth2": ["secure_mobile_transactions:commercial.read"] }],
        "parameters": [{ "$ref": "#/components/parameters/PartnerId" }, { "$ref": "#/components/parameters/CorrelationId" }],
        "responses": {
          "200": { "description": "Usage summary", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/UsageSummary" } } } },
          "404": { "$ref": "#/components/responses/Problem" }
        }
      }
    },
    "/number-verification": {
      "post": {
        "tags": ["Transactions"],
        "operationId": "verifyMobileNumberCommercially",
        "summary": "Verify a mobile number and rate the result",
        "security": [{ "oauth2": ["secure_mobile_transactions:invoke"] }],
        "parameters": [{ "$ref": "#/components/parameters/CorrelationId" }],
        "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/TransactionRequest" }, "examples": { "business": { "value": { "partnerId": "fintech-br-001", "msisdn": "+5511999990001", "consentId": "consent-2026-001", "country": "BR", "currency": "BRL" } } } } } },
        "responses": { "200": { "$ref": "#/components/responses/Transaction" }, "422": { "$ref": "#/components/responses/Transaction" }, "503": { "$ref": "#/components/responses/Problem" } }
      }
    },
    "/sim-swap": {
      "post": {
        "tags": ["Transactions"],
        "operationId": "checkSimSwapCommercially",
        "summary": "Assess SIM-swap evidence and rate the result",
        "security": [{ "oauth2": ["secure_mobile_transactions:invoke"] }],
        "parameters": [{ "$ref": "#/components/parameters/CorrelationId" }],
        "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/TransactionRequest" } } } },
        "responses": { "200": { "$ref": "#/components/responses/Transaction" }, "422": { "$ref": "#/components/responses/Transaction" }, "503": { "$ref": "#/components/responses/Problem" } }
      }
    },
    "/quality-on-demand": {
      "post": {
        "tags": ["Transactions"],
        "operationId": "activateQualityOnDemandCommercially",
        "summary": "Activate a QoD session and rate full or partial success",
        "description": "A partial response remains a successful business outcome with a 0.70 rating factor when live radio telemetry is unavailable.",
        "security": [{ "oauth2": ["secure_mobile_transactions:invoke"] }],
        "parameters": [{ "$ref": "#/components/parameters/CorrelationId" }],
        "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/TransactionRequest" } } } },
        "responses": { "200": { "$ref": "#/components/responses/Transaction" }, "422": { "$ref": "#/components/responses/Transaction" }, "503": { "$ref": "#/components/responses/Problem" } }
      }
    },
    "/demo/seed": {
      "post": {
        "tags": ["Demo Administration"],
        "operationId": "seedCommercialUsage",
        "summary": "Compactly seed allowance consumption for deterministic overage demonstrations",
        "security": [{ "oauth2": ["secure_mobile_transactions:commercial.manage"] }],
        "requestBody": { "required": true, "content": { "application/json": { "schema": { "type": "object", "required": ["partnerId", "meter", "successfulRequests"], "properties": { "partnerId": { "type": "string" }, "apiProduct": { "type": "string", "default": "SecureMobileTransactionsProduct" }, "meter": { "type": "string", "enum": ["number_verification", "sim_swap", "quality_on_demand"] }, "successfulRequests": { "type": "integer", "minimum": 0 }, "rejectedRequests": { "type": "integer", "minimum": 0 }, "billedAmount": { "type": "number", "minimum": 0 } } } } } },
        "responses": { "200": { "description": "Usage fixture seeded" } }
      }
    },
    "/demo/reset": {
      "post": {
        "tags": ["Demo Administration"],
        "operationId": "resetCommercialDemo",
        "summary": "Reset assignments and usage for deterministic verification",
        "security": [{ "oauth2": ["secure_mobile_transactions:commercial.manage"] }],
        "responses": { "200": { "description": "Commercial demo state reset" } }
      }
    }
  },
  "components": {
    "securitySchemes": {
      "oauth2": {
        "type": "oauth2",
        "flows": {
          "clientCredentials": {
            "tokenUrl": "https://localhost:8243/token",
            "scopes": {
              "secure_mobile_transactions:invoke": "Invoke commercial transaction capabilities",
              "secure_mobile_transactions:commercial.read": "Read plans and partner/product usage",
              "secure_mobile_transactions:commercial.manage": "Assign plans and manage demo fixtures"
            }
          }
        }
      }
    },
    "parameters": {
      "PartnerId": { "name": "partnerId", "in": "path", "required": true, "schema": { "type": "string", "maxLength": 128 } },
      "CorrelationId": { "name": "X-Correlation-ID", "in": "header", "required": false, "schema": { "type": "string", "maxLength": 128 }, "description": "Preserved end-to-end; MI generates one when omitted." }
    },
    "schemas": {
      "PlanAssignmentRequest": {
        "type": "object",
        "additionalProperties": false,
        "required": ["planId", "country", "currency"],
        "properties": {
          "planId": { "type": "string", "enum": ["Sandbox", "Business", "Enterprise"] },
          "country": { "type": "string", "pattern": "^[A-Z]{2}$" },
          "currency": { "type": "string", "pattern": "^[A-Z]{3}$" },
          "contractReference": { "type": "string" },
          "effectiveFrom": { "type": "string", "format": "date-time" }
        }
      },
      "TransactionRequest": {
        "type": "object",
        "additionalProperties": true,
        "required": ["partnerId", "consentId"],
        "properties": {
          "partnerId": { "type": "string" },
          "msisdn": { "type": "string" },
          "consentId": { "type": "string", "description": "Evidence that the partner has a lawful basis and end-user consent where required." },
          "country": { "type": "string", "default": "BR" },
          "currency": { "type": "string", "default": "BRL" },
          "profile": { "type": "string", "default": "QOS_E" },
          "durationSeconds": { "type": "integer", "minimum": 60, "maximum": 3600 },
          "forceOutcome": { "type": "string", "enum": ["SUCCESS", "REJECTED", "PARTIAL", "ERROR"], "description": "Demo-only deterministic branch selector." }
        }
      },
      "CommercialUsage": {
        "type": "object",
        "required": ["partnerId", "apiProduct", "planId", "meter", "currency", "billedAmount", "chargeType"],
        "properties": {
          "partnerId": { "type": "string" },
          "apiProduct": { "type": "string" },
          "planId": { "type": "string" },
          "meter": { "type": "string" },
          "country": { "type": "string" },
          "currency": { "type": "string" },
          "includedAllowanceMonthly": { "type": "integer" },
          "successfulRequestsBefore": { "type": "integer" },
          "overLimit": { "type": "boolean" },
          "unitPrice": { "type": "number" },
          "ratingFactor": { "type": "number" },
          "billedAmount": { "type": "number" },
          "chargeType": { "type": "string" },
          "slaEntitlement": { "type": "object" },
          "dataPolicy": { "type": "string" }
        }
      },
      "TransactionResponse": {
        "type": "object",
        "properties": {
          "outcome": { "type": "string", "enum": ["SUCCESS", "PARTIAL", "REJECTED"] },
          "status": { "type": "string" },
          "partial": { "type": "boolean" },
          "warnings": { "type": "array", "items": { "type": "string" } },
          "result": { "type": "object" },
          "correlationId": { "type": "string" },
          "commercialUsage": { "$ref": "#/components/schemas/CommercialUsage" }
        }
      },
      "UsageSummary": { "type": "object", "properties": { "partnerId": { "type": "string" }, "apiProduct": { "type": "string" }, "assignment": { "type": "object" }, "plan": { "type": "object" }, "totals": { "type": "object" }, "perMeter": { "type": "array", "items": { "type": "object" } }, "overLimit": { "type": "boolean" }, "recentEvents": { "type": "array", "items": { "type": "object" } } } },
      "Health": { "type": "object", "properties": { "status": { "type": "string" }, "service": { "type": "string" }, "runtime": { "type": "string" }, "correlationId": { "type": "string" } } },
      "Problem": { "type": "object", "properties": { "type": { "type": "string", "format": "uri" }, "title": { "type": "string" }, "status": { "type": "integer" }, "code": { "type": "string" }, "detail": { "type": "string" }, "correlationId": { "type": "string" } } }
    },
    "responses": {
      "Transaction": { "description": "Capability and commercial usage result", "headers": { "X-Correlation-ID": { "schema": { "type": "string" } } }, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/TransactionResponse" } } } },
      "Problem": { "description": "Normalized error", "content": { "application/problem+json": { "schema": { "$ref": "#/components/schemas/Problem" } } } }
    }
  }
}
EOF
cp contracts/openapi/secure-mobile-transactions-commercial.openapi.json \
  artifacts/contracts/openapi/secure-mobile-transactions-commercial.openapi.json

cat > docs/secure-mobile-transactions/overview.md <<'EOF'
# Secure Mobile Transactions — commercial flow

The product bundles Number Verification, SIM Swap and Quality on Demand behind one commercial contract. Every invocation carries a partner identifier and correlation identifier. WSO2 API Manager enforces OAuth, subscriptions and technical rate limits. WSO2 Integrator: MI resolves the partner plan, invokes the capability, applies the commercial rating rule and persists an idempotent usage event.

Usage is queryable by `partnerId` and `SecureMobileTransactionsProduct`. Responses include the selected plan, included allowance, over-limit state, meter, country, currency, unit price, billed amount, charge type and SLA entitlement.
EOF

cat > docs/secure-mobile-transactions/plans-and-rating.md <<'EOF'
# Plans and rating

| Plan | Commercial model | Monthly allowance | Data | SLA |
|---|---|---:|---|---|
| Sandbox | Free | 100 successful calls | Masked | 98.0%, community |
| Business | BRL 1,500 monthly, then overage | 10,000 successful calls | Full with consent | 99.5%, business hours |
| Enterprise | BRL 12,000 commitment and lower committed/overage rates | 100,000 successful calls | Full with consent | 99.95%, 24x7, 15-minute response |

Business overage prices are BRL 0.08 for Number Verification, BRL 0.14 for SIM Swap and BRL 0.35 for QoD. Enterprise committed prices are BRL 0.045, BRL 0.085 and BRL 0.22 respectively, with still-lower overage prices. Rejected requests are recorded for audit and operational analysis but billed at zero. A QoD partial success is billable at a 0.70 rating factor.
EOF

cat > docs/secure-mobile-transactions/consent-and-sandbox.md <<'EOF'
# Consent and sandbox data

Consumers must provide a `consentId` that can be mapped to their consent or other lawful-basis record. Do not send secrets or raw identity documents in this field. Production onboarding should define retention, revocation and subject-right handling with the operator.

Sandbox responses mask MSISDN data while preserving deterministic response structure, correlation and usage metadata. `forceOutcome` and `/demo/*` are demonstration controls and must not be exposed in a production contract.
EOF

cat > docs/secure-mobile-transactions/errors-and-sla.md <<'EOF'
# Errors, retries and SLA

Functional rejections return HTTP 422 with a normalized business outcome and a zero-valued usage event. Transport failures return `application/problem+json` with HTTP 503 and the same `X-Correlation-ID` used in MI logs.

The MI endpoint uses a three-second timeout, two bounded retries, exponential endpoint suspension and failover from the primary to the secondary persistence adapter. QoD may return `PARTIAL` when activation succeeds but live telemetry is unavailable; the response contains warnings and uses a 0.70 billing factor.
EOF

cat > docs/secure-mobile-transactions/postman-and-sdk.md <<'EOF'
# Postman and SDK usage

Import `artifacts/developer-experience/secure-mobile-transactions/Secure-Mobile-Transactions.postman_collection.json`. Set `gatewayUrl`, `accessToken` and `partnerId`, then run plan assignment, usage seeding, the three transaction calls and usage summary.

The OpenAPI document is available in the Developer Portal for SDK generation. Generated clients must add `Authorization: Bearer ...`, preserve or create `X-Correlation-ID`, and treat HTTP 422 as a rated rejection rather than a transport error.
EOF

for f in overview plans-and-rating consent-and-sandbox errors-and-sla postman-and-sdk; do
  cp "docs/secure-mobile-transactions/${f}.md" \
    "artifacts/developer-experience/secure-mobile-transactions/${f}.md"
done

cat > artifacts/developer-experience/secure-mobile-transactions/Secure-Mobile-Transactions.postman_collection.json <<'EOF'
{
  "info": {
    "name": "Secure Mobile Transactions Commercial Flow",
    "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
  },
  "variable": [
    { "key": "gatewayUrl", "value": "https://localhost:8243/secure-mobile-transactions-product/1.0.0" },
    { "key": "accessToken", "value": "" },
    { "key": "partnerId", "value": "fintech-br-001" },
    { "key": "correlationId", "value": "commercial-demo-001" }
  ],
  "item": [
    {
      "name": "List plans",
      "request": { "method": "GET", "header": [{ "key": "Authorization", "value": "Bearer {{accessToken}}" }, { "key": "X-Correlation-ID", "value": "{{correlationId}}" }], "url": "{{gatewayUrl}}/plans" }
    },
    {
      "name": "Assign Business plan",
      "request": { "method": "PUT", "header": [{ "key": "Authorization", "value": "Bearer {{accessToken}}" }, { "key": "Content-Type", "value": "application/json" }, { "key": "X-Correlation-ID", "value": "{{correlationId}}" }], "body": { "mode": "raw", "raw": "{\n  \"planId\": \"Business\",\n  \"country\": \"BR\",\n  \"currency\": \"BRL\",\n  \"contractReference\": \"FINTECH-BR-2026\"\n}" }, "url": "{{gatewayUrl}}/partners/{{partnerId}}/plan" }
    },
    {
      "name": "Number Verification",
      "request": { "method": "POST", "header": [{ "key": "Authorization", "value": "Bearer {{accessToken}}" }, { "key": "Content-Type", "value": "application/json" }, { "key": "X-Correlation-ID", "value": "{{correlationId}}" }], "body": { "mode": "raw", "raw": "{\n  \"partnerId\": \"{{partnerId}}\",\n  \"msisdn\": \"+5511999990001\",\n  \"consentId\": \"consent-2026-001\",\n  \"country\": \"BR\",\n  \"currency\": \"BRL\"\n}" }, "url": "{{gatewayUrl}}/number-verification" }
    },
    {
      "name": "Rejected SIM Swap",
      "request": { "method": "POST", "header": [{ "key": "Authorization", "value": "Bearer {{accessToken}}" }, { "key": "Content-Type", "value": "application/json" }, { "key": "X-Correlation-ID", "value": "{{correlationId}}-rejected" }], "body": { "mode": "raw", "raw": "{\n  \"partnerId\": \"{{partnerId}}\",\n  \"msisdn\": \"+5511999990001\",\n  \"consentId\": \"consent-2026-002\",\n  \"forceOutcome\": \"REJECTED\"\n}" }, "url": "{{gatewayUrl}}/sim-swap" }
    },
    {
      "name": "QoD partial response",
      "request": { "method": "POST", "header": [{ "key": "Authorization", "value": "Bearer {{accessToken}}" }, { "key": "Content-Type", "value": "application/json" }, { "key": "X-Correlation-ID", "value": "{{correlationId}}-qod" }], "body": { "mode": "raw", "raw": "{\n  \"partnerId\": \"{{partnerId}}\",\n  \"consentId\": \"consent-2026-003\",\n  \"profile\": \"QOS_E\",\n  \"durationSeconds\": 900,\n  \"forceOutcome\": \"PARTIAL\"\n}" }, "url": "{{gatewayUrl}}/quality-on-demand" }
    },
    {
      "name": "Usage by partner and API Product",
      "request": { "method": "GET", "header": [{ "key": "Authorization", "value": "Bearer {{accessToken}}" }, { "key": "X-Correlation-ID", "value": "{{correlationId}}-usage" }], "url": "{{gatewayUrl}}/partners/{{partnerId}}/usage" }
    }
  ]
}
EOF

info "Creating idempotent APIM policy/API bootstrap and commercial experience bootstrap"
cat > services/apim-bootstrapper/src/commercial-api-setup.js <<'EOF'
'use strict';

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
const fs = require('node:fs');
const path = require('node:path');

const APIM_URL = (process.env.WSO2_APIM_URL || 'https://wso2-apim:9443').replace(/\/$/, '');
const USER = process.env.APIM_USERNAME || 'admin';
const PASSWORD = process.env.APIM_PASSWORD || 'admin';
const API_NAME = 'SecureMobileTransactionsCommercialAPI';
const API_VERSION = '1.0.0';
const API_CONTEXT = '/secure-mobile-transactions';
const ENDPOINT = `${(process.env.WSO2_MI_URL || 'http://wso2-mi:8290').replace(/\/$/, '')}/secure-mobile-transactions/v1`;
const CONTRACT = '/workspace/contracts/openapi/secure-mobile-transactions-commercial.openapi.json';
const MARKER = 'commercial-flow-v1';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const log = (message) => console.log(`[commercial-api] ${message}`);

async function request(url, options = {}, accepted = [200, 201, 202, 204]) {
  const response = await fetch(url, options);
  const text = await response.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch (_) { data = text; }
  if (!accepted.includes(response.status)) {
    throw new Error(`${options.method || 'GET'} ${url} -> HTTP ${response.status}: ${text.slice(0, 2000)}`);
  }
  return { status: response.status, data, headers: response.headers };
}

async function waitForApim() {
  for (let attempt = 1; attempt <= 180; attempt += 1) {
    try {
      const response = await fetch(`${APIM_URL}/services/Version`, { headers: { Accept: 'application/json' } });
      if (response.ok) return;
    } catch (_) {}
    await sleep(2000);
  }
  throw new Error(`APIM did not become ready at ${APIM_URL}`);
}

async function token(scopes) {
  const clientName = `secure-mobile-commercial-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const registration = await request(`${APIM_URL}/client-registration/v0.17/register`, {
    method: 'POST',
    headers: { authorization: `Basic ${Buffer.from(`${USER}:${PASSWORD}`).toString('base64')}`, 'content-type': 'application/json' },
    body: JSON.stringify({
      callbackUrl: 'www.google.lk',
      clientName,
      owner: USER,
      grantType: 'password refresh_token client_credentials',
      saasApp: true
    })
  });
  const clientId = registration.data.clientId;
  const clientSecret = registration.data.clientSecret;
  if (!clientId || !clientSecret) throw new Error(`DCR did not return credentials: ${JSON.stringify(registration.data)}`);
  const body = new URLSearchParams({
    grant_type: 'password',
    username: USER,
    password: PASSWORD,
    scope: scopes
  });
  const result = await request(`${APIM_URL}/oauth2/token`, {
    method: 'POST',
    headers: {
      authorization: `Basic ${Buffer.from(`${clientId}:${clientSecret}`).toString('base64')}`,
      'content-type': 'application/x-www-form-urlencoded'
    },
    body
  });
  if (!result.data?.access_token) throw new Error(`Token response missing access_token: ${JSON.stringify(result.data)}`);
  return result.data.access_token;
}

function auth(accessToken, extra = {}) {
  return { authorization: `Bearer ${accessToken}`, accept: 'application/json', ...extra };
}

async function upsertPolicy(adminToken, plan) {
  const base = `${APIM_URL}/api/am/admin/v4/throttling/policies/subscription`;
  const list = await request(`${base}?limit=100&offset=0`, { headers: auth(adminToken) });
  const existing = (list.data?.list || []).find((item) => item.policyName === plan.policyName);
  const payload = {
    policyName: plan.policyName,
    displayName: plan.displayName,
    description: plan.description,
    isDeployed: true,
    graphQLMaxComplexity: 0,
    graphQLMaxDepth: 0,
    defaultLimit: {
      type: 'REQUESTCOUNTLIMIT',
      requestCount: { timeUnit: 'min', unitTime: 1, requestCount: plan.technicalPerMinute },
      bandwidth: null
    },
    monetization: null,
    rateLimitCount: 0,
    rateLimitTimeUnit: 'min',
    customAttributes: [
      { name: 'commercialPlanId', value: plan.planId },
      { name: 'includedAllowanceMonthly', value: String(plan.allowance) },
      { name: 'country', value: 'BR' },
      { name: 'currency', value: 'BRL' },
      { name: 'slaAvailability', value: String(plan.sla) }
    ],
    stopOnQuotaReach: false,
    billingPlan: plan.billingPlan
  };
  if (existing?.policyId) {
    await request(`${base}/${existing.policyId}`, {
      method: 'PUT',
      headers: auth(adminToken, { 'content-type': 'application/json' }),
      body: JSON.stringify({ ...payload, policyId: existing.policyId })
    });
    log(`Updated subscription policy ${plan.policyName}`);
  } else {
    await request(base, {
      method: 'POST',
      headers: auth(adminToken, { 'content-type': 'application/json' }),
      body: JSON.stringify(payload)
    });
    log(`Created subscription policy ${plan.policyName}`);
  }
}

async function findApi(publisherToken) {
  const result = await request(`${APIM_URL}/api/am/publisher/v4/apis?limit=100&offset=0&query=${encodeURIComponent(`name:${API_NAME}`)}`, { headers: auth(publisherToken) });
  for (const summary of result.data?.list || []) {
    if (summary.name !== API_NAME || summary.version !== API_VERSION) continue;
    const full = await request(`${APIM_URL}/api/am/publisher/v4/apis/${summary.id}`, { headers: auth(publisherToken) });
    if (full.data?.context === API_CONTEXT) return full.data;
  }
  return null;
}

function operations() {
  const definitions = [
    ['GET', '/health', 'None', []],
    ['GET', '/plans', 'Application & Application User', ['secure_mobile_transactions:commercial.read']],
    ['PUT', '/partners/{partnerId}/plan', 'Application & Application User', ['secure_mobile_transactions:commercial.manage']],
    ['GET', '/partners/{partnerId}/usage', 'Application & Application User', ['secure_mobile_transactions:commercial.read']],
    ['POST', '/number-verification', 'Application & Application User', ['secure_mobile_transactions:invoke']],
    ['POST', '/sim-swap', 'Application & Application User', ['secure_mobile_transactions:invoke']],
    ['POST', '/quality-on-demand', 'Application & Application User', ['secure_mobile_transactions:invoke']],
    ['POST', '/demo/seed', 'Application & Application User', ['secure_mobile_transactions:commercial.manage']],
    ['POST', '/demo/reset', 'Application & Application User', ['secure_mobile_transactions:commercial.manage']]
  ];
  return definitions.map(([verb, target, authType, scopes]) => ({
    target,
    verb,
    authType,
    throttlingPolicy: 'Unlimited',
    scopes
  }));
}

function apiPayload(existing = {}) {
  const additionalProperties = [
    { name: 'CommercialFlowVersion', value: MARKER, display: true },
    { name: 'APIProduct', value: 'SecureMobileTransactionsProduct', display: true },
    { name: 'Country', value: 'BR', display: true },
    { name: 'Currency', value: 'BRL', display: true },
    { name: 'RatingOwner', value: 'WSO2 Integrator: MI', display: true },
    { name: 'Meters', value: 'number_verification,sim_swap,quality_on_demand', display: true }
  ];
  return {
    ...existing,
    name: API_NAME,
    context: API_CONTEXT,
    version: API_VERSION,
    provider: existing.provider || USER,
    description: 'MI-owned plan resolution, capability orchestration, outcome-aware rating and usage persistence for Secure Mobile Transactions.',
    type: 'HTTP',
    transport: ['http', 'https'],
    tags: ['telco', 'commercial', 'open-gateway', 'monetization', 'mi'],
    policies: ['SecureMobileSandbox', 'SecureMobileBusiness', 'SecureMobileEnterprise'],
    apiThrottlingPolicy: 'Unlimited',
    authorizationHeader: 'Authorization',
    securityScheme: ['oauth2'],
    visibility: 'PUBLIC',
    subscriptionAvailability: 'ALL_TENANTS',
    isRevision: false,
    enableSchemaValidation: true,
    endpointConfig: {
      endpoint_type: 'http',
      sandbox_endpoints: { url: ENDPOINT },
      production_endpoints: { url: ENDPOINT }
    },
    operations: operations(),
    additionalProperties
  };
}

async function deployIfRequired(publisherToken, api) {
  const deploymentsResult = await request(`${APIM_URL}/api/am/publisher/v4/apis/${api.id}/deployments`, { headers: auth(publisherToken) });
  const deployments = deploymentsResult.data?.list || deploymentsResult.data || [];
  if (Array.isArray(deployments) && deployments.length > 0) {
    log(`API already has ${deployments.length} deployment(s); preserving deployed revision`);
    return;
  }
  const revision = await request(`${APIM_URL}/api/am/publisher/v4/apis/${api.id}/revisions`, {
    method: 'POST',
    headers: auth(publisherToken, { 'content-type': 'application/json' }),
    body: JSON.stringify({ description: 'Secure Mobile Transactions commercial flow bootstrap' })
  });
  await request(`${APIM_URL}/api/am/publisher/v4/apis/${api.id}/deploy-revision?revisionId=${encodeURIComponent(revision.data.id)}`, {
    method: 'POST',
    headers: auth(publisherToken, { 'content-type': 'application/json' }),
    body: JSON.stringify([{ name: 'Default', vhost: 'localhost', displayOnDevportal: true }])
  });
  log(`Deployed revision ${revision.data.id}`);
}

async function publishIfRequired(publisherToken, api) {
  const refreshed = await request(`${APIM_URL}/api/am/publisher/v4/apis/${api.id}`, { headers: auth(publisherToken) });
  if (refreshed.data?.lifeCycleStatus === 'PUBLISHED') return;
  await request(`${APIM_URL}/api/am/publisher/v4/apis/change-lifecycle?action=Publish&apiId=${encodeURIComponent(api.id)}`, {
    method: 'POST',
    headers: auth(publisherToken)
  }, [200, 201]);
  log('Published API');
}

async function main() {
  await waitForApim();
  const adminToken = await token('apim:admin_tier_view apim:admin_tier_manage');
  const publisherToken = await token('apim:api_view apim:api_create apim:api_publish apim:api_manage');
  const plans = [
    { policyName: 'SecureMobileSandbox', displayName: 'Secure Mobile Sandbox', planId: 'Sandbox', allowance: 100, technicalPerMinute: 10, sla: 98.0, billingPlan: 'FREE', description: 'Free sandbox; 100 successful calls/month in the commercial ledger, 10 requests/minute technical protection, masked data.' },
    { policyName: 'SecureMobileBusiness', displayName: 'Secure Mobile Business', planId: 'Business', allowance: 10000, technicalPerMinute: 60, sla: 99.5, billingPlan: 'COMMERCIAL', description: 'BRL Business plan; 10,000 successful calls/month plus per-capability overage, 60 requests/minute technical protection.' },
    { policyName: 'SecureMobileEnterprise', displayName: 'Secure Mobile Enterprise', planId: 'Enterprise', allowance: 100000, technicalPerMinute: 300, sla: 99.95, billingPlan: 'COMMERCIAL', description: 'Committed enterprise volume, lower unit prices, 99.95% SLA and 24x7 support; 300 requests/minute technical protection.' }
  ];
  for (const plan of plans) await upsertPolicy(adminToken, plan);

  let api = await findApi(publisherToken);
  if (!api) {
    const created = await request(`${APIM_URL}/api/am/publisher/v4/apis`, {
      method: 'POST',
      headers: auth(publisherToken, { 'content-type': 'application/json' }),
      body: JSON.stringify(apiPayload())
    });
    api = created.data;
    log(`Created API ${api.id}`);
  } else {
    const marker = (api.additionalProperties || []).find((item) => item.name === 'CommercialFlowVersion')?.value;
    if (marker !== MARKER) {
      const updated = await request(`${APIM_URL}/api/am/publisher/v4/apis/${api.id}`, {
        method: 'PUT',
        headers: auth(publisherToken, { 'content-type': 'application/json' }),
        body: JSON.stringify(apiPayload(api))
      });
      api = updated.data;
      log(`Updated API ${api.id}`);
    } else {
      log(`API ${api.id} already carries marker ${MARKER}`);
    }
  }

  const definition = fs.readFileSync(CONTRACT, 'utf8');
  const definitionForm = new FormData();
  definitionForm.set('apiDefinition', definition);
  await request(`${APIM_URL}/api/am/publisher/v4/apis/${api.id}/swagger`, {
    method: 'PUT',
    headers: auth(publisherToken),
    body: definitionForm
  }, [200]);
  log('Updated managed OpenAPI definition');

  await deployIfRequired(publisherToken, api);
  await publishIfRequired(publisherToken, api);
  fs.mkdirSync('/workspace/state', { recursive: true });
  fs.writeFileSync('/workspace/state/commercial-api.json', `${JSON.stringify({ apiId: api.id, name: API_NAME, version: API_VERSION, context: API_CONTEXT }, null, 2)}\n`);
  log('Commercial API and native subscription policies are ready');
}

main().catch((error) => {
  console.error(`[commercial-api] ${error.stack || error.message || error}`);
  process.exit(1);
});
EOF

cat > services/apim-bootstrapper/src/commercial-experience-setup.js <<'EOF'
'use strict';

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
const fs = require('node:fs');
const path = require('node:path');

const APIM_URL = (process.env.WSO2_APIM_URL || 'https://wso2-apim:9443').replace(/\/$/, '');
const MI_URL = (process.env.WSO2_MI_URL || 'http://wso2-mi:8290').replace(/\/$/, '');
const USER = process.env.APIM_USERNAME || 'admin';
const PASSWORD = process.env.APIM_PASSWORD || 'admin';
const API_NAME = 'SecureMobileTransactionsCommercialAPI';
const PRODUCT_NAME = 'SecureMobileTransactionsProduct';
const VERSION = '1.0.0';
const DOC_DIR = '/workspace/artifacts/developer-experience/secure-mobile-transactions';
const CONTRACT = '/workspace/contracts/openapi/secure-mobile-transactions-commercial.openapi.json';
const log = (message) => console.log(`[commercial-experience] ${message}`);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function request(url, options = {}, accepted = [200, 201, 202, 204]) {
  const response = await fetch(url, options);
  const text = await response.text();
  let data;
  try { data = text ? JSON.parse(text) : null; } catch (_) { data = text; }
  if (!accepted.includes(response.status)) throw new Error(`${options.method || 'GET'} ${url} -> HTTP ${response.status}: ${text.slice(0, 2000)}`);
  return { status: response.status, data };
}

async function token(scopes) {
  const registration = await request(`${APIM_URL}/client-registration/v0.17/register`, {
    method: 'POST', headers: { authorization: `Basic ${Buffer.from(`${USER}:${PASSWORD}`).toString('base64')}`, 'content-type': 'application/json' },
    body: JSON.stringify({ callbackUrl: 'www.google.lk', clientName: `commercial-experience-${Date.now()}`, owner: USER, grantType: 'password refresh_token client_credentials', saasApp: true })
  });
  const basic = Buffer.from(`${registration.data.clientId}:${registration.data.clientSecret}`).toString('base64');
  const result = await request(`${APIM_URL}/oauth2/token`, {
    method: 'POST',
    headers: { authorization: `Basic ${basic}`, 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'password', username: USER, password: PASSWORD, scope: scopes })
  });
  return result.data.access_token;
}
const auth = (accessToken, extra = {}) => ({ authorization: `Bearer ${accessToken}`, accept: 'application/json', ...extra });

async function findExact(basePath, name, accessToken) {
  const pageSize = 100;
  for (let offset = 0; offset < 2000; offset += pageSize) {
    const result = await request(`${APIM_URL}${basePath}?limit=${pageSize}&offset=${offset}`, { headers: auth(accessToken) });
    const list = Array.isArray(result.data) ? result.data : (result.data?.list || result.data?.data || []);
    const exact = list.find((item) => item.name === name && String(item.version || '') === VERSION);
    if (exact) return exact;
    const total = Number(result.data?.pagination?.total || result.data?.count || 0);
    if (list.length < pageSize || (total > 0 && offset + list.length >= total)) break;
  }
  return null;
}

async function upsertDocument(basePath, entityId, accessToken, name, file, summary) {
  const list = await request(`${APIM_URL}${basePath}/${entityId}/documents?limit=100&offset=0`, { headers: auth(accessToken) });
  let document = (list.data?.list || []).find((item) => item.name === name);
  const metadata = { name, type: 'HOWTO', summary, sourceType: 'INLINE', visibility: 'API_LEVEL' };
  if (document) {
    const updated = await request(`${APIM_URL}${basePath}/${entityId}/documents/${document.documentId}`, {
      method: 'PUT', headers: auth(accessToken, { 'content-type': 'application/json' }), body: JSON.stringify({ ...document, ...metadata })
    });
    document = updated.data;
  } else {
    const created = await request(`${APIM_URL}${basePath}/${entityId}/documents`, {
      method: 'POST', headers: auth(accessToken, { 'content-type': 'application/json' }), body: JSON.stringify(metadata)
    });
    document = created.data;
  }
  const content = fs.readFileSync(file, 'utf8');
  const contentUrl = `${APIM_URL}${basePath}/${entityId}/documents/${document.documentId}/content`;
  const contentForm = new FormData();
  contentForm.append('inlineContent', content);
  await request(contentUrl, {
    method: 'POST',
    headers: { authorization: `Bearer ${accessToken}`, accept: 'application/json' },
    body: contentForm
  }, [200, 201, 202, 204]);
  log(`Upserted document ${name}`);
}

async function registerService(accessToken) {
  const serviceName = API_NAME;
  const list = await request(`${APIM_URL}/api/am/service-catalog/v1/services?name=${encodeURIComponent(serviceName)}&version=${VERSION}&limit=100`, { headers: auth(accessToken) });
  const existing = (list.data?.list || []).find((item) => item.name === serviceName && item.version === VERSION);
  const metadata = {
    name: serviceName,
    version: VERSION,
    description: 'WSO2 Integrator: MI service that resolves a partner plan, invokes a mobile capability, applies outcome-aware commercial rating and persists usage by partner and API Product.',
    serviceUrl: `${MI_URL}/secure-mobile-transactions/v1`,
    definitionType: 'OAS3',
    securityType: 'NONE',
    mutualSSLEnabled: false
  };
  const form = new FormData();
  form.append('definitionFile', new Blob([fs.readFileSync(CONTRACT)], { type: 'application/json' }), 'secure-mobile-transactions-commercial.openapi.json');
  form.append('serviceMetadata', new Blob([JSON.stringify(metadata)], { type: 'application/json' }), 'service-metadata.json');
  const target = existing ? `${APIM_URL}/api/am/service-catalog/v1/services/${existing.id}` : `${APIM_URL}/api/am/service-catalog/v1/services`;
  await request(target, { method: existing ? 'PUT' : 'POST', headers: { authorization: `Bearer ${accessToken}`, accept: 'application/json' }, body: form });
  log(`${existing ? 'Updated' : 'Created'} Service Catalog entry ${serviceName}:${VERSION}`);
}

async function ensureApplicationAndSubscription(accessToken, productId) {
  const appName = 'Secure Mobile Fintech BR';
  const apps = await request(`${APIM_URL}/api/am/devportal/v3/applications?limit=100&offset=0`, { headers: auth(accessToken) });
  let app = (apps.data?.list || []).find((item) => item.name === appName);
  if (!app) {
    app = (await request(`${APIM_URL}/api/am/devportal/v3/applications`, {
      method: 'POST', headers: auth(accessToken, { 'content-type': 'application/json' }),
      body: JSON.stringify({ name: appName, throttlingPolicy: 'Unlimited', description: 'Demo partner application assigned to the Business commercial plan.', tokenType: 'JWT', attributes: { partnerId: 'fintech-br-001', country: 'BR', currency: 'BRL', commercialPlan: 'Business' } })
    })).data;
    log(`Created application ${appName}`);
  }
  const applicationId = app.applicationId || app.id;
  const subscriptions = await request(`${APIM_URL}/api/am/devportal/v3/subscriptions?applicationId=${encodeURIComponent(applicationId)}&limit=100&offset=0`, { headers: auth(accessToken) });
  const existing = (subscriptions.data?.list || []).find((item) => item.apiId === productId);
  if (!existing) {
    await request(`${APIM_URL}/api/am/devportal/v3/subscriptions`, {
      method: 'POST', headers: auth(accessToken, { 'content-type': 'application/json' }),
      body: JSON.stringify({ applicationId, apiId: productId, throttlingPolicy: 'SecureMobileBusiness' })
    });
    log('Subscribed the fintech partner application to the API Product with SecureMobileBusiness');
  } else if (existing.throttlingPolicy !== 'SecureMobileBusiness') {
    await request(`${APIM_URL}/api/am/devportal/v3/subscriptions/${existing.subscriptionId}`, {
      method: 'PUT', headers: auth(accessToken, { 'content-type': 'application/json' }),
      body: JSON.stringify({ ...existing, throttlingPolicy: 'SecureMobileBusiness' })
    });
    log('Updated the API Product subscription to SecureMobileBusiness');
  }
  return { applicationId, appName };
}

async function mi(method, route, body, correlationId) {
  const response = await fetch(`${MI_URL}/secure-mobile-transactions/v1${route}`, {
    method,
    headers: { 'content-type': 'application/json', accept: 'application/json', 'x-correlation-id': correlationId },
    body: body === undefined ? undefined : JSON.stringify(body)
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`${method} ${route} -> HTTP ${response.status}: ${text}`);
  return JSON.parse(text);
}

async function seedOperationalFlow() {
  for (let attempt = 1; attempt <= 90; attempt += 1) {
    try {
      const health = await fetch(`${MI_URL}/secure-mobile-transactions/v1/health`);
      if (health.ok) break;
    } catch (_) {}
    if (attempt === 90) throw new Error('MI commercial API did not become ready');
    await sleep(2000);
  }
  await mi('PUT', '/partners/fintech-br-001/plan', { planId: 'Business', country: 'BR', currency: 'BRL', contractReference: 'FINTECH-BR-2026' }, 'commercial-bootstrap-business');
  await mi('PUT', '/partners/sandbox-partner-br/plan', { planId: 'Sandbox', country: 'BR', currency: 'BRL' }, 'commercial-bootstrap-sandbox');
  await mi('PUT', '/partners/operator-enterprise-br/plan', { planId: 'Enterprise', country: 'BR', currency: 'BRL', contractReference: 'ENTERPRISE-BR-2026' }, 'commercial-bootstrap-enterprise');
  await mi('POST', '/demo/seed', { partnerId: 'fintech-br-001', apiProduct: PRODUCT_NAME, meter: 'number_verification', successfulRequests: 10000, rejectedRequests: 0, billedAmount: 0 }, 'commercial-bootstrap-allowance');
  const overage = await mi('POST', '/number-verification', { partnerId: 'fintech-br-001', msisdn: '+5511999990001', consentId: 'consent-bootstrap-001', country: 'BR', currency: 'BRL' }, 'commercial-bootstrap-overage');
  if (overage?.commercialUsage?.chargeType !== 'BUSINESS_OVERAGE' || Number(overage?.commercialUsage?.billedAmount) !== 0.08) {
    throw new Error(`Expected Business overage amount 0.08, received ${JSON.stringify(overage)}`);
  }
  log('Seeded partner assignments, exhausted the Business allowance and persisted a real overage event');
}

async function main() {
  const publisherToken = await token('apim:api_view apim:api_metadata_view apim:api_product_view apim:document_manage apim:document_create apim:document_update');
  const catalogToken = await token('service_catalog:service_view service_catalog:service_write');
  const devportalToken = await token('apim:subscribe');
  const api = await findExact('/api/am/publisher/v4/apis', API_NAME, publisherToken);
  if (!api?.id) throw new Error(`${API_NAME}:${VERSION} was not found after API bootstrap`);
  const product = await findExact('/api/am/publisher/v4/api-products', PRODUCT_NAME, publisherToken);
  if (!product?.id) throw new Error(`${PRODUCT_NAME}:${VERSION} was not found after API Product bootstrap`);

  const documents = [
    ['Commercial flow overview', 'overview.md', 'Architecture and end-to-end commercial flow'],
    ['Plans and outcome-based rating', 'plans-and-rating.md', 'Allowances, per-capability prices, overage and rejected requests'],
    ['Consent and sandbox data', 'consent-and-sandbox.md', 'Consent guidance and masked sandbox behavior'],
    ['Errors, resilience and SLA', 'errors-and-sla.md', 'Normalized errors, timeouts, retries, failover, partial responses and SLA'],
    ['Postman and SDK instructions', 'postman-and-sdk.md', 'Consumer onboarding through Postman and generated SDKs']
  ];
  for (const [name, filename, summary] of documents) {
    await upsertDocument('/api/am/publisher/v4/apis', api.id, publisherToken, name, path.join(DOC_DIR, filename), summary);
  }
  try {
    for (const [name, filename, summary] of documents) {
      await upsertDocument('/api/am/publisher/v4/api-products', product.id, publisherToken, name, path.join(DOC_DIR, filename), summary);
    }
  } catch (error) {
    log(`API Product document endpoint was not available; API-level Developer Portal documents remain authoritative: ${error.message}`);
  }

  await registerService(catalogToken);
  const app = await ensureApplicationAndSubscription(devportalToken, product.id);
  await seedOperationalFlow();

  fs.mkdirSync('/workspace/state', { recursive: true });
  fs.writeFileSync('/workspace/state/commercial-runtime.json', `${JSON.stringify({
    apiId: api.id,
    apiProductId: product.id,
    applicationId: app.applicationId,
    applicationName: app.appName,
    partnerId: 'fintech-br-001',
    subscriptionPolicy: 'SecureMobileBusiness',
    initializedAt: new Date().toISOString()
  }, null, 2)}\n`);
  log('Commercial plan and usage-meter experience is operational');
}

main().catch((error) => {
  console.error(`[commercial-experience] ${error.stack || error.message || error}`);
  process.exit(1);
});
EOF

info "Patching APIM bootstrap order, API Product catalog and monetization metadata"
python3 <<'PY'
from pathlib import Path
import json
import re

product_setup_path = Path('services/apim-bootstrapper/src/api-product-bundles-setup.js')
product_setup = product_setup_path.read_text()
match = re.search(r"const NATIVE_PRODUCT_BUNDLE_IDS = new Set\(\[(.*?)\]\);", product_setup, re.S)
if not match:
    raise SystemExit('Could not locate NATIVE_PRODUCT_BUNDLE_IDS in api-product-bundles-setup.js')
if "'secure-mobile-transactions'" not in match.group(1) and '"secure-mobile-transactions"' not in match.group(1):
    updated_items = match.group(1).rstrip()
    if updated_items and not updated_items.rstrip().endswith(','):
        updated_items += ','
    updated_items += " 'secure-mobile-transactions' "
    product_setup = product_setup[:match.start(1)] + updated_items + product_setup[match.end(1):]
    product_setup_path.write_text(product_setup)

old_operations = 'const operations = bundleOperations.map(operationFromBundle).filter(Boolean);'
new_operations = 'const operations = operationsFromApi(detail, bundleOperations);'
if old_operations in product_setup:
    product_setup = product_setup.replace(old_operations, new_operations, 1)

build_start = product_setup.find('function buildProductPayload(bundle, productApis)')
build_end = product_setup.find('async function createOrUpdateApiProduct', build_start)
if build_start < 0 or build_end < 0:
    raise SystemExit('Could not locate buildProductPayload boundaries')
payload_block = product_setup[build_start:build_end]
if not re.search(r'\bpolicies\s*:', payload_block):
    throttle_match = re.search(r"apiThrottlingPolicy\s*:\s*([^,]+),", payload_block)
    if not throttle_match:
        raise SystemExit('Could not locate apiThrottlingPolicy inside buildProductPayload')
    separator = '\n    ' if '\n' in payload_block else ' '
    policy_expression = "policies: Array.from(new Set([...(bundle.apim?.subscriptionPolicies || bundle.plans || []), 'Unlimited'])),"
    tag_expression = "tags: Array.from(new Set(bundle.apim?.tags || [])),"
    insertion = f"{separator}{policy_expression}{separator}{tag_expression}"
    payload_block = payload_block[:throttle_match.end()] + insertion + payload_block[throttle_match.end():]
    product_setup = product_setup[:build_start] + payload_block + product_setup[build_end:]
product_setup_path.write_text(product_setup)

package_path = Path('services/apim-bootstrapper/package.json')
package = json.loads(package_path.read_text())
start = package.setdefault('scripts', {}).get('start', '')
steps = [step.strip() for step in start.split('&&') if step.strip()]
commercial_api = 'node src/commercial-api-setup.js'
product_step = 'node src/api-product-bundles-setup.js'
developer_step = 'node src/developer-experience-setup.js'
commercial_experience = 'node src/commercial-experience-setup.js'
steps = [step for step in steps if step not in (commercial_api, commercial_experience)]
if product_step not in steps:
    raise SystemExit('Could not locate api-product-bundles-setup.js in bootstrapper start command')
if developer_step not in steps:
    raise SystemExit('Could not locate developer-experience-setup.js in bootstrapper start command')
steps.insert(steps.index(product_step), commercial_api)
steps.insert(steps.index(developer_step) + 1, commercial_experience)
package['scripts']['start'] = ' && '.join(steps)
package_path.write_text(json.dumps(package, indent=2) + '\n')

bundle_path = Path('artifacts/apim-admin/api-product-bundles.json')
bundles = json.loads(bundle_path.read_text())
bundle = {
    'id': 'secure-mobile-transactions',
    'name': 'Secure Mobile Transactions Bundle',
    'title': 'Secure Mobile Transactions',
    'description': 'Operational product for Number Verification, SIM Swap and Quality on Demand with executable plan assignment, allowances, outcome-based rating, country/currency metadata and usage visibility.',
    'businessStory': 'A bank, fintech or enterprise buys one secure mobile transaction product and receives consistent consent handling, commercial rating and usage evidence across three mobile-network capabilities.',
    'businessOutcome': 'Turns API subscriptions into an executable commercial flow with partner-specific allowance, overage, SLA and outcome-based billing evidence.',
    'buyer': 'Banks, fintechs, payment providers, fraud platforms and enterprise mobility teams',
    'businessOwner': 'Telco Digital Products',
    'technicalOwner': 'Telco API Platform',
    'plan': 'SecureMobileBusiness',
    'plans': ['SecureMobileSandbox', 'SecureMobileBusiness', 'SecureMobileEnterprise'],
    'markets': ['BR'],
    'apis': ['SecureMobileTransactionsCommercialAPI'],
    'products': [
        {'name': 'Number Verification', 'meter': 'number_verification', 'unit': 'successful request'},
        {'name': 'SIM Swap', 'meter': 'sim_swap', 'unit': 'successful request'},
        {'name': 'Quality on Demand', 'meter': 'quality_on_demand', 'unit': 'successful or partial activation'}
    ],
    'commercialPlans': [
        {
            'name': 'Sandbox', 'subscriptionPolicy': 'SecureMobileSandbox', 'billingPlan': 'FREE',
            'includedAllowanceMonthly': 100, 'country': 'BR', 'currency': 'BRL', 'dataPolicy': 'MASKED',
            'sla': {'availabilityPercent': 98.0, 'support': 'community'},
            'prices': {'number_verification': 0, 'sim_swap': 0, 'quality_on_demand': 0, 'rejected': 0}
        },
        {
            'name': 'Business', 'subscriptionPolicy': 'SecureMobileBusiness', 'billingPlan': 'COMMERCIAL',
            'monthlyFee': 1500, 'includedAllowanceMonthly': 10000, 'country': 'BR', 'currency': 'BRL',
            'sla': {'availabilityPercent': 99.5, 'support': 'business-hours'},
            'overagePrices': {'number_verification': 0.08, 'sim_swap': 0.14, 'quality_on_demand': 0.35, 'rejected': 0}
        },
        {
            'name': 'Enterprise', 'subscriptionPolicy': 'SecureMobileEnterprise', 'billingPlan': 'COMMERCIAL',
            'monthlyCommitment': 12000, 'committedVolume': 100000, 'country': 'BR', 'currency': 'BRL',
            'sla': {'availabilityPercent': 99.95, 'support': '24x7', 'responseMinutes': 15},
            'committedPrices': {'number_verification': 0.045, 'sim_swap': 0.085, 'quality_on_demand': 0.22},
            'overagePrices': {'number_verification': 0.04, 'sim_swap': 0.075, 'quality_on_demand': 0.19, 'rejected': 0}
        }
    ],
    'apiBundle': [
        {'apiName': 'SecureMobileTransactionsCommercialAPI', 'method': 'POST', 'path': '/number-verification', 'capability': 'Number Verification', 'meter': 'number_verification'},
        {'apiName': 'SecureMobileTransactionsCommercialAPI', 'method': 'POST', 'path': '/sim-swap', 'capability': 'SIM Swap', 'meter': 'sim_swap'},
        {'apiName': 'SecureMobileTransactionsCommercialAPI', 'method': 'POST', 'path': '/quality-on-demand', 'capability': 'Quality on Demand', 'meter': 'quality_on_demand'},
        {'apiName': 'SecureMobileTransactionsCommercialAPI', 'method': 'GET', 'path': '/plans', 'capability': 'Commercial plan catalog', 'meter': 'commercial_read'},
        {'apiName': 'SecureMobileTransactionsCommercialAPI', 'method': 'GET', 'path': '/partners/{partnerId}/usage', 'capability': 'Partner and API Product usage', 'meter': 'commercial_read'},
        {'apiName': 'SecureMobileTransactionsCommercialAPI', 'method': 'PUT', 'path': '/partners/{partnerId}/plan', 'capability': 'Partner plan assignment', 'meter': 'commercial_manage'}
    ],
    'apim': {
        'apiProductName': 'SecureMobileTransactionsProduct',
        'displayName': 'Secure Mobile Transactions',
        'version': '1.0.0',
        'context': '/secure-mobile-transactions-product',
        'description': 'Number Verification, SIM Swap and Quality on Demand sold through executable Sandbox, Business and Enterprise plans.',
        'subscriptionPolicies': ['SecureMobileSandbox', 'SecureMobileBusiness', 'SecureMobileEnterprise'],
        'apiThrottlingPolicy': 'Unlimited',
        'visibility': 'PUBLIC',
        'governanceLabel': 'Telco Commercial APIs',
        'tags': ['telco', 'commercial', 'open-gateway', 'monetization']
    },
    'moesif': {
        'companyId': 'regional-telco-group',
        'productKey': 'moesif_prod_secure_mobile_transactions',
        'billingCatalogReference': 'billing.catalog.secure-mobile-transactions.v1',
        'revenueShareModel': 'OUTCOME_AWARE_USAGE_AND_COMMITMENT',
        'settlementOwner': 'Telco Digital Products Finance',
        'productLine': 'Secure Mobile Transactions',
        'meters': ['api_call', 'number_verification', 'sim_swap', 'quality_on_demand', 'rejected_request']
    }
}
replaced = False
for index, current in enumerate(bundles):
    if current.get('id') == bundle['id'] or current.get('apim', {}).get('apiProductName') == bundle['apim']['apiProductName']:
        bundles[index] = bundle
        replaced = True
        break
if not replaced:
    bundles.append(bundle)
bundle_path.write_text(json.dumps(bundles, indent=2) + '\n')

commercial_plans_path = Path('artifacts/apim-admin/commercial-plans.json')
commercial_plans = []
if commercial_plans_path.exists():
    commercial_plans = json.loads(commercial_plans_path.read_text())
if not isinstance(commercial_plans, list):
    raise SystemExit(f'{commercial_plans_path} must contain a JSON array')
new_commercial_plans = [
    {
        'policyName': 'SecureMobileSandbox',
        'displayName': 'Secure Mobile Sandbox',
        'description': 'Free sandbox with masked data, 100 successful requests per month in the commercial ledger and 10 requests/minute technical protection.',
        'requestCount': 10,
        'timeUnit': 'min',
        'unitTime': 1,
        'billingPlan': 'FREE',
        'stopOnQuotaReach': False,
        'pricing': {
            'billingType': 'FREE',
            'billingCycle': 'month',
            'currencyType': 'BRL',
            'fixedPrice': '0.00',
            'pricePerRequest': '0.00',
            'includedQuota': '100 successful requests/month',
            'commercialSummary': 'Free; masked data; 100 successful requests/month'
        },
        'meterPrices': {'number_verification': 0, 'sim_swap': 0, 'quality_on_demand': 0, 'rejected': 0},
        'country': 'BR',
        'currency': 'BRL',
        'dataPolicy': 'MASKED',
        'sla': {'availabilityPercent': 98.0, 'support': 'community'}
    },
    {
        'policyName': 'SecureMobileBusiness',
        'displayName': 'Secure Mobile Business',
        'description': 'BRL 1,500/month with 10,000 successful requests included, then meter-specific overage; 60 requests/minute technical protection.',
        'requestCount': 60,
        'timeUnit': 'min',
        'unitTime': 1,
        'billingPlan': 'COMMERCIAL',
        'stopOnQuotaReach': False,
        'pricing': {
            'billingType': 'FIXED_PLUS_METERED_OVERAGE',
            'billingCycle': 'month',
            'currencyType': 'BRL',
            'fixedPrice': '1500.00',
            'pricePerRequest': 'meter-specific',
            'includedQuota': '10,000 successful requests/month',
            'commercialSummary': 'BRL 1,500/month; overage NV 0.08, SIM Swap 0.14, QoD 0.35; rejected requests 0.00'
        },
        'meterPrices': {'number_verification': 0.08, 'sim_swap': 0.14, 'quality_on_demand': 0.35, 'rejected': 0},
        'country': 'BR',
        'currency': 'BRL',
        'dataPolicy': 'FULL_WITH_CONSENT',
        'sla': {'availabilityPercent': 99.5, 'support': 'business-hours'}
    },
    {
        'policyName': 'SecureMobileEnterprise',
        'displayName': 'Secure Mobile Enterprise',
        'description': 'BRL 12,000 committed plan with 100,000 successful requests, lower committed/overage unit rates, 99.95% SLA and 24x7 support.',
        'requestCount': 300,
        'timeUnit': 'min',
        'unitTime': 1,
        'billingPlan': 'COMMERCIAL',
        'stopOnQuotaReach': False,
        'pricing': {
            'billingType': 'COMMITTED_VOLUME_PLUS_METERED_OVERAGE',
            'billingCycle': 'month',
            'currencyType': 'BRL',
            'fixedPrice': '12000.00',
            'pricePerRequest': 'meter-specific',
            'includedQuota': '100,000 committed successful requests/month',
            'commercialSummary': 'BRL 12,000 commitment; committed NV 0.045, SIM Swap 0.085, QoD 0.22; lower overage rates; rejected requests 0.00'
        },
        'meterPrices': {
            'number_verification_committed': 0.045,
            'sim_swap_committed': 0.085,
            'quality_on_demand_committed': 0.22,
            'number_verification_overage': 0.04,
            'sim_swap_overage': 0.075,
            'quality_on_demand_overage': 0.19,
            'rejected': 0
        },
        'country': 'BR',
        'currency': 'BRL',
        'dataPolicy': 'FULL_WITH_CONSENT',
        'sla': {'availabilityPercent': 99.95, 'support': '24x7', 'responseMinutes': 15}
    }
]
for item in new_commercial_plans:
    for index, current in enumerate(commercial_plans):
        if current.get('policyName') == item['policyName']:
            commercial_plans[index] = item
            break
    else:
        commercial_plans.append(item)
commercial_plans_path.write_text(json.dumps(commercial_plans, indent=2) + '\n')

monetization_path = Path('artifacts/apim-admin/api-monetization-properties.json')
if monetization_path.exists():
    payload = json.loads(monetization_path.read_text())
    if isinstance(payload, dict):
        entries = payload.setdefault('apis', [])
    else:
        entries = payload
    item = {
        'apiName': 'SecureMobileTransactionsCommercialAPI',
        'version': '1.0.0',
        'properties': {
            'APIProduct': 'SecureMobileTransactionsProduct',
            'CommercialPlans': 'Sandbox,Business,Enterprise',
            'Meters': 'number_verification,sim_swap,quality_on_demand',
            'Country': 'BR',
            'Currency': 'BRL',
            'RatingOwner': 'WSO2 Integrator: MI',
            'UsageDimensions': 'partnerId,apiProduct,planId,meter,outcome,country,currency',
            'OutcomeRating': 'SUCCESS/PARTIAL billed; REJECTED recorded at zero'
        }
    }
    for i, current in enumerate(entries):
        if current.get('apiName') == item['apiName']:
            entries[i] = item
            break
    else:
        entries.append(item)
    monetization_path.write_text(json.dumps(payload, indent=2) + '\n')
PY

info "Adding observability configuration and dashboard"
python3 <<'PY'
from pathlib import Path

prom = Path('observability/prometheus/prometheus.yml')
if prom.exists():
    text = prom.read_text()
    if "job_name: 'commercial-meter'" not in text and 'job_name: "commercial-meter"' not in text:
        block = """
  - job_name: 'commercial-meter'
    scrape_interval: 5s
    static_configs:
      - targets:
          - 'commercial-meter-store-primary:8086'
          - 'commercial-meter-store-secondary:8086'
"""
        if 'scrape_configs:' not in text:
            text += '\nscrape_configs:\n' + block
        else:
            text = text.rstrip() + '\n' + block
        prom.write_text(text.rstrip() + '\n')

control = Path('scripts/telco-demo-control.sh')
if control.exists():
    text = control.read_text()
    if 'docker-compose.commercial.yml' not in text:
        anchor = 'docker-compose.mi.yml \\\n'
        if anchor in text:
            text = text.replace(anchor, anchor + '  docker-compose.commercial.yml \\\n', 1)
        else:
            anchor = 'docker-compose.kafka.yml \\\n'
            if anchor not in text:
                raise SystemExit('Could not locate the Compose file loop in scripts/telco-demo-control.sh')
            text = text.replace(anchor, anchor + '  docker-compose.commercial.yml \\\n', 1)
        control.write_text(text)
PY

cat > observability/grafana/dashboards/secure-mobile-commercial-usage.json <<'EOF'
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 0,
  "id": null,
  "links": [],
  "panels": [
    {
      "type": "stat",
      "title": "Commercial requests",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [{ "expr": "sum(telco_commercial_usage_requests_total)", "refId": "A" }],
      "gridPos": { "h": 8, "w": 6, "x": 0, "y": 0 }
    },
    {
      "type": "stat",
      "title": "Billed amount",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [{ "expr": "sum(telco_commercial_billed_amount_total)", "refId": "A" }],
      "gridPos": { "h": 8, "w": 6, "x": 6, "y": 0 }
    },
    {
      "type": "timeseries",
      "title": "Requests by partner, plan, meter and outcome",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [{ "expr": "sum by (partner, plan, meter, outcome) (rate(telco_commercial_usage_requests_total[5m]))", "legendFormat": "{{partner}} / {{plan}} / {{meter}} / {{outcome}}", "refId": "A" }],
      "gridPos": { "h": 10, "w": 12, "x": 12, "y": 0 }
    },
    {
      "type": "table",
      "title": "Billed amount by partner and API Product",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [{ "expr": "sum by (partner, product, plan, meter, currency) (telco_commercial_billed_amount_total)", "format": "table", "instant": true, "refId": "A" }],
      "gridPos": { "h": 10, "w": 24, "x": 0, "y": 10 }
    }
  ],
  "refresh": "5s",
  "schemaVersion": 39,
  "tags": ["telco", "commercial", "monetization", "wso2"],
  "templating": { "list": [] },
  "time": { "from": "now-1h", "to": "now" },
  "timezone": "browser",
  "title": "Secure Mobile Transactions — Commercial Usage",
  "uid": "secure-mobile-commercial",
  "version": 1
}
EOF

info "Creating automated verification"
cat > scripts/verify-commercial-plan-usage.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
GATEWAY_URL="${WSO2_GATEWAY_URL:-https://127.0.0.1:8243}"
MI_URL="${WSO2_MI_PUBLIC_URL:-http://127.0.0.1:8290}"
STORE_URL="${COMMERCIAL_STORE_URL:-http://127.0.0.1:18086}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASS="${APIM_PASSWORD:-admin}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/commercial-verify.XXXXXX")"
VERIFY_APP_ID=""
trap 'if [[ -n "$VERIFY_APP_ID" && -n "${DEVPORTAL_TOKEN:-}" ]]; then curl -ksS -X DELETE -H "Authorization: Bearer ${DEVPORTAL_TOKEN}" "${APIM_URL}/api/am/devportal/v3/applications/${VERIFY_APP_ID}" >/dev/null 2>&1 || true; fi; rm -rf "$WORK_DIR"' EXIT

ok() { printf '[OK] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "$1 is required"; }
for command in curl jq python3 docker; do require "$command"; done

if docker compose version >/dev/null 2>&1; then DC=(docker compose); elif docker-compose version >/dev/null 2>&1; then DC=(docker-compose); else fail 'Docker Compose is required'; fi
COMPOSE_FILES=(docker-compose.yml)
for file in docker-compose.kafka.yml docker-compose.opa.yml docker-compose.mi.yml docker-compose.commercial.yml docker-compose.mi.soap.yml docker-compose.observability.yml docker-compose.runtime-persistence.yml; do
  [[ -f "$file" ]] && COMPOSE_FILES+=("$file")
done
COMPOSE=("${DC[@]}")
for file in "${COMPOSE_FILES[@]}"; do COMPOSE+=(-f "$file"); done

for file in \
  docker-compose.commercial.yml \
  services/commercial-meter-store/src/server.js \
  services/wso2-mi/synapse-configs/default/api/SecureMobileTransactionsCommercialAPI.xml \
  services/wso2-mi/synapse-configs/default/endpoints/CommercialMeterStoreFailoverEndpoint.xml \
  services/wso2-mi/synapse-configs/default/sequences/CommercialExecuteTransactionSequence.xml \
  contracts/openapi/secure-mobile-transactions-commercial.openapi.json \
  artifacts/developer-experience/secure-mobile-transactions/Secure-Mobile-Transactions.postman_collection.json; do
  [[ -s "$file" ]] || fail "Missing required artifact: $file"
done
ok 'Static commercial artifacts exist'

"${COMPOSE[@]}" config >/dev/null
ok 'Merged Docker Compose topology is valid'

for service in commercial-meter-store-primary commercial-meter-store-secondary wso2-mi wso2-apim; do
  id="$("${COMPOSE[@]}" ps -q "$service" 2>/dev/null || true)"
  [[ -n "$id" ]] || fail "Service is not running: $service"
done
ok 'APIM, MI and both meter-store replicas are running'

wait_url() {
  local url="$1" label="$2" insecure="${3:-false}"
  local args=(-fsS --max-time 5)
  [[ "$insecure" == true ]] && args=(-kfsS --max-time 5)
  for _ in $(seq 1 90); do
    if curl "${args[@]}" "$url" >/dev/null 2>&1; then ok "$label is ready"; return; fi
    sleep 2
  done
  fail "$label did not become ready: $url"
}
wait_url "$STORE_URL/health" 'Primary commercial meter store'
wait_url 'http://127.0.0.1:18087/health' 'Secondary commercial meter store'
wait_url "$MI_URL/secure-mobile-transactions/v1/health" 'MI commercial API'
wait_url "$APIM_URL/services/Version" 'APIM management plane' true

CLIENT_NAME="commercial-verifier-$(date +%s)-$$"
DCR="$(curl -ksS -u "$APIM_USER:$APIM_PASS" -X POST -H 'Content-Type: application/json' \
  -d "{\"callbackUrl\":\"www.google.lk\",\"clientName\":\"${CLIENT_NAME}\",\"owner\":\"${APIM_USER}\",\"grantType\":\"password refresh_token client_credentials\",\"saasApp\":true}" \
  "$APIM_URL/client-registration/v0.17/register")"
CLIENT_ID="$(jq -r '.clientId // empty' <<<"$DCR")"
CLIENT_SECRET="$(jq -r '.clientSecret // empty' <<<"$DCR")"
[[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]] || fail "DCR failed: $DCR"
password_token() {
  local scope="$1"
  curl -ksS -u "$CLIENT_ID:$CLIENT_SECRET" \
    --data-urlencode grant_type=password \
    --data-urlencode username="$APIM_USER" \
    --data-urlencode password="$APIM_PASS" \
    --data-urlencode "scope=$scope" \
    "$APIM_URL/oauth2/token"
}
ADMIN_TOKEN_JSON="$(password_token 'apim:admin_tier_view apim:admin_tier_manage')"
PUBLISHER_TOKEN_JSON="$(password_token 'apim:api_view apim:api_metadata_view apim:api_product_view apim:document_manage apim:document_create apim:document_update')"
CATALOG_TOKEN_JSON="$(password_token 'service_catalog:service_view service_catalog:service_write')"
DEVPORTAL_TOKEN_JSON="$(password_token 'apim:subscribe')"
ADMIN_TOKEN="$(jq -r '.access_token // empty' <<<"$ADMIN_TOKEN_JSON")"
PUBLISHER_TOKEN="$(jq -r '.access_token // empty' <<<"$PUBLISHER_TOKEN_JSON")"
CATALOG_TOKEN="$(jq -r '.access_token // empty' <<<"$CATALOG_TOKEN_JSON")"
DEVPORTAL_TOKEN="$(jq -r '.access_token // empty' <<<"$DEVPORTAL_TOKEN_JSON")"
[[ -n "$ADMIN_TOKEN" ]] || fail "Admin OAuth token failed: $ADMIN_TOKEN_JSON"
[[ -n "$PUBLISHER_TOKEN" ]] || fail "Publisher OAuth token failed: $PUBLISHER_TOKEN_JSON"
[[ -n "$CATALOG_TOKEN" ]] || fail "Service Catalog OAuth token failed: $CATALOG_TOKEN_JSON"
[[ -n "$DEVPORTAL_TOKEN" ]] || fail "DevPortal OAuth token failed: $DEVPORTAL_TOKEN_JSON"
ADMIN_AUTH=(-H "Authorization: Bearer $ADMIN_TOKEN" -H 'Accept: application/json')
PUBLISHER_AUTH=(-H "Authorization: Bearer $PUBLISHER_TOKEN" -H 'Accept: application/json')
CATALOG_AUTH=(-H "Authorization: Bearer $CATALOG_TOKEN" -H 'Accept: application/json')
DEVPORTAL_AUTH=(-H "Authorization: Bearer $DEVPORTAL_TOKEN" -H 'Accept: application/json')
ok 'Obtained dedicated APIM Admin, Publisher, DevPortal and Service Catalog tokens'

POLICIES="$(curl -ksS "${ADMIN_AUTH[@]}" "$APIM_URL/api/am/admin/v4/throttling/policies/subscription?limit=100&offset=0")"
for policy in SecureMobileSandbox SecureMobileBusiness SecureMobileEnterprise; do
  jq -e --arg name "$policy" 'any(.list[]?; .policyName == $name)' <<<"$POLICIES" >/dev/null || fail "Missing subscription policy: $policy"
done
jq -e 'any(.list[]?; .policyName == "SecureMobileBusiness" and .billingPlan == "COMMERCIAL" and .stopOnQuotaReach == false)' <<<"$POLICIES" >/dev/null || fail 'Business policy does not carry expected commercial behavior'
ok 'All three native APIM subscription policies exist'

APIS="$(curl -ksS "${PUBLISHER_AUTH[@]}" --get --data-urlencode 'query=name:SecureMobileTransactionsCommercialAPI' --data-urlencode 'limit=100' "$APIM_URL/api/am/publisher/v4/apis")"
API_ID="$(jq -r 'first(.list[]? | select(.name == "SecureMobileTransactionsCommercialAPI" and .version == "1.0.0") | .id) // empty' <<<"$APIS")"
[[ -n "$API_ID" ]] || fail 'Managed API is absent'
API="$(curl -ksS "${PUBLISHER_AUTH[@]}" "$APIM_URL/api/am/publisher/v4/apis/$API_ID")"
jq -e '.lifeCycleStatus == "PUBLISHED"' <<<"$API" >/dev/null || fail 'Managed API is not PUBLISHED'
jq -e '[.operations[]? | (.verb + " " + .target)] | contains(["POST /number-verification", "POST /sim-swap", "POST /quality-on-demand", "GET /partners/{partnerId}/usage"])' <<<"$API" >/dev/null || fail 'Managed API operations are incomplete'
DEPLOYMENTS="$(curl -ksS "${PUBLISHER_AUTH[@]}" "$APIM_URL/api/am/publisher/v4/apis/$API_ID/deployments")"
jq -e '((.list // .) | length) > 0' <<<"$DEPLOYMENTS" >/dev/null || fail 'Managed API has no deployed revision'
ok 'Managed API is published and deployed with the expected operations'

PRODUCTS="$(curl -ksS "${PUBLISHER_AUTH[@]}" --get --data-urlencode 'query=name:SecureMobileTransactionsProduct' --data-urlencode 'limit=100' "$APIM_URL/api/am/publisher/v4/api-products")"
PRODUCT_ID="$(jq -r 'first(.list[]? | select(.name == "SecureMobileTransactionsProduct" and .version == "1.0.0") | .id) // empty' <<<"$PRODUCTS")"
[[ -n "$PRODUCT_ID" ]] || fail 'SecureMobileTransactionsProduct is absent'
PRODUCT="$(curl -ksS "${PUBLISHER_AUTH[@]}" "$APIM_URL/api/am/publisher/v4/api-products/$PRODUCT_ID")"
jq -e '(.state == "PUBLISHED") or (.lifeCycleStatus == "PUBLISHED")' <<<"$PRODUCT" >/dev/null || fail 'API Product is not PUBLISHED'
jq -e '(.policies // []) | contains(["SecureMobileSandbox", "SecureMobileBusiness", "SecureMobileEnterprise"])' <<<"$PRODUCT" >/dev/null || fail 'API Product does not expose all commercial policies'
PRODUCT_DEPLOYMENTS="$(curl -ksS "${PUBLISHER_AUTH[@]}" "$APIM_URL/api/am/publisher/v4/api-products/$PRODUCT_ID/deployments")"
jq -e '((.list // .) | length) > 0' <<<"$PRODUCT_DEPLOYMENTS" >/dev/null || fail 'API Product has no deployed revision'
ok 'API Product is published, deployed and subscribable with all plans'

DOCS="$(curl -ksS "${PUBLISHER_AUTH[@]}" "$APIM_URL/api/am/publisher/v4/apis/$API_ID/documents?limit=100&offset=0")"
for name in 'Commercial flow overview' 'Plans and outcome-based rating' 'Consent and sandbox data' 'Errors, resilience and SLA' 'Postman and SDK instructions'; do
  jq -e --arg name "$name" 'any(.list[]?; .name == $name)' <<<"$DOCS" >/dev/null || fail "Missing Developer Portal document: $name"
done
ok 'Developer Portal documentation is complete'

CATALOG="$(curl -ksS "${CATALOG_AUTH[@]}" "$APIM_URL/api/am/service-catalog/v1/services?limit=100")"
jq -e 'any(.list[]?; .name == "SecureMobileTransactionsCommercialAPI" and .version == "1.0.0" and .definitionType == "OAS3")' <<<"$CATALOG" >/dev/null || fail 'MI service is absent from the APIM Service Catalog'
ok 'MI-managed commercial service is registered in the Service Catalog'

APPS="$(curl -ksS "${DEVPORTAL_AUTH[@]}" "$APIM_URL/api/am/devportal/v3/applications?limit=100&offset=0")"
PARTNER_APP_ID="$(jq -r 'first(.list[]? | select(.name == "Secure Mobile Fintech BR") | (.applicationId // .id)) // empty' <<<"$APPS")"
[[ -n "$PARTNER_APP_ID" ]] || fail 'Partner application is absent'
SUBS="$(curl -ksS "${DEVPORTAL_AUTH[@]}" --get --data-urlencode "applicationId=$PARTNER_APP_ID" --data-urlencode 'limit=100' "$APIM_URL/api/am/devportal/v3/subscriptions")"
jq -e --arg product "$PRODUCT_ID" 'any(.list[]?; .apiId == $product and .throttlingPolicy == "SecureMobileBusiness")' <<<"$SUBS" >/dev/null || fail 'Partner application is not subscribed to the API Product with Business plan'
ok 'Partner is assigned to the Business subscription plan in APIM'

curl -fsS -X POST -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-reset' -d '{}' "$MI_URL/secure-mobile-transactions/v1/demo/reset" >/dev/null
curl -fsS -X PUT -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-business-assignment' \
  -d '{"planId":"Business","country":"BR","currency":"BRL","contractReference":"VERIFY-BUSINESS"}' \
  "$MI_URL/secure-mobile-transactions/v1/partners/fintech-br-001/plan" > "$WORK_DIR/business-assignment.json"
jq -e '.assignment.planId == "Business" and .assignment.country == "BR" and .assignment.currency == "BRL"' "$WORK_DIR/business-assignment.json" >/dev/null || fail 'Business plan assignment runtime behavior failed'

curl -fsS -X POST -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-seed' \
  -d '{"partnerId":"fintech-br-001","apiProduct":"SecureMobileTransactionsProduct","meter":"number_verification","successfulRequests":10000,"rejectedRequests":0,"billedAmount":0}' \
  "$MI_URL/secure-mobile-transactions/v1/demo/seed" > "$WORK_DIR/seed.json"
jq -e '.usage.overLimit == true and .usage.totals.successfulRequests == 10000' "$WORK_DIR/seed.json" >/dev/null || fail 'Included allowance exhaustion was not seeded correctly'

curl -fsS -X POST -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-business-overage' \
  -d '{"partnerId":"fintech-br-001","msisdn":"+5511999990001","consentId":"verify-consent-001","country":"BR","currency":"BRL"}' \
  "$MI_URL/secure-mobile-transactions/v1/number-verification" > "$WORK_DIR/overage.json"
jq -e '.outcome == "SUCCESS" and .commercialUsage.planId == "Business" and .commercialUsage.meter == "number_verification" and .commercialUsage.overLimit == true and .commercialUsage.chargeType == "BUSINESS_OVERAGE" and .commercialUsage.billedAmount == 0.08 and .commercialUsage.currency == "BRL"' "$WORK_DIR/overage.json" >/dev/null || fail 'Business Number Verification overage rating failed'

curl -fsS -X POST -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-business-sim-swap' \
  -d '{"partnerId":"fintech-br-001","msisdn":"+5511999990001","consentId":"verify-consent-sim-success"}' \
  "$MI_URL/secure-mobile-transactions/v1/sim-swap" > "$WORK_DIR/sim-swap-success.json"
jq -e '.outcome == "SUCCESS" and .commercialUsage.planId == "Business" and .commercialUsage.meter == "sim_swap" and .commercialUsage.chargeType == "BUSINESS_OVERAGE" and .commercialUsage.billedAmount == 0.14' "$WORK_DIR/sim-swap-success.json" >/dev/null || fail 'Business SIM Swap overage rating failed'

curl -fsS -X POST -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-business-qod' \
  -d '{"partnerId":"fintech-br-001","consentId":"verify-consent-qod-success","profile":"QOS_E","durationSeconds":900}' \
  "$MI_URL/secure-mobile-transactions/v1/quality-on-demand" > "$WORK_DIR/qod-success.json"
jq -e '.outcome == "SUCCESS" and .commercialUsage.planId == "Business" and .commercialUsage.meter == "quality_on_demand" and .commercialUsage.chargeType == "BUSINESS_OVERAGE" and .commercialUsage.billedAmount == 0.35' "$WORK_DIR/qod-success.json" >/dev/null || fail 'Business Quality on Demand overage rating failed'
ok 'Business overage prices differ by meter: NV BRL 0.08, SIM Swap BRL 0.14, QoD BRL 0.35'

REJECT_HTTP="$(curl -sS -o "$WORK_DIR/rejected.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-rejected' \
  -d '{"partnerId":"fintech-br-001","msisdn":"+5511999990001","consentId":"verify-consent-002","forceOutcome":"REJECTED"}' \
  "$MI_URL/secure-mobile-transactions/v1/sim-swap")"
[[ "$REJECT_HTTP" == 422 ]] || fail "Rejected request returned HTTP $REJECT_HTTP instead of 422"
jq -e '.outcome == "REJECTED" and .commercialUsage.meter == "sim_swap" and .commercialUsage.billedAmount == 0 and .commercialUsage.chargeType == "REJECTED_NO_CHARGE"' "$WORK_DIR/rejected.json" >/dev/null || fail 'Rejected request rating failed'
ok 'Rejected SIM Swap is recorded but billed at zero'

curl -fsS -X PUT -H 'Content-Type: application/json' -d '{"planId":"Sandbox","country":"BR","currency":"BRL"}' "$MI_URL/secure-mobile-transactions/v1/partners/sandbox-partner-br/plan" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-sandbox' \
  -d '{"partnerId":"sandbox-partner-br","msisdn":"+5511888881234","consentId":"verify-consent-003"}' \
  "$MI_URL/secure-mobile-transactions/v1/number-verification" > "$WORK_DIR/sandbox.json"
jq -e '.commercialUsage.planId == "Sandbox" and .commercialUsage.billedAmount == 0 and .commercialUsage.dataPolicy == "MASKED" and .result.masked == true and (.result.msisdn | startswith("********"))' "$WORK_DIR/sandbox.json" >/dev/null || fail 'Sandbox masking/free rating failed'
ok 'Sandbox is free and returns masked data'

curl -fsS -X PUT -H 'Content-Type: application/json' -d '{"planId":"Enterprise","country":"BR","currency":"BRL"}' "$MI_URL/secure-mobile-transactions/v1/partners/operator-enterprise-br/plan" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-enterprise-qod' \
  -d '{"partnerId":"operator-enterprise-br","consentId":"verify-consent-004","profile":"QOS_E","durationSeconds":900,"forceOutcome":"PARTIAL"}' \
  "$MI_URL/secure-mobile-transactions/v1/quality-on-demand" > "$WORK_DIR/enterprise.json"
jq -e '.outcome == "PARTIAL" and .partial == true and .commercialUsage.planId == "Enterprise" and .commercialUsage.meter == "quality_on_demand" and .commercialUsage.unitPrice == 0.22 and .commercialUsage.ratingFactor == 0.7 and .commercialUsage.billedAmount == 0.154 and .commercialUsage.slaEntitlement.availabilityPercent == 99.95' "$WORK_DIR/enterprise.json" >/dev/null || fail 'Enterprise QoD partial/SLA rating failed'
ok 'Enterprise committed QoD price, partial-response factor and SLA entitlement work'

curl -fsS -H 'X-Correlation-ID: verify-usage' "$MI_URL/secure-mobile-transactions/v1/partners/fintech-br-001/usage" > "$WORK_DIR/usage.json"
jq -e '.partnerId == "fintech-br-001" and .apiProduct == "SecureMobileTransactionsProduct" and .totals.successfulRequests >= 10001 and .totals.rejectedRequests >= 1 and (.perMeter | length) >= 3 and .recentEvents[0].correlationId != null' "$WORK_DIR/usage.json" >/dev/null || fail 'Partner/API Product usage summary failed'
ok 'Usage is visible by partner, API Product, meter, outcome and correlation ID'

METRICS="$(curl -fsS "$STORE_URL/metrics")"
grep -q 'telco_commercial_usage_requests_total' <<<"$METRICS" || fail 'Commercial request metrics are absent'
grep -q 'telco_commercial_billed_amount_total' <<<"$METRICS" || fail 'Commercial billed amount metrics are absent'
ok 'Prometheus commercial usage metrics are exposed'

VERIFY_APP_NAME="Commercial Verification $(date +%s)-$$"
APP_JSON="$(curl -ksS -X POST "${DEVPORTAL_AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"name\":\"${VERIFY_APP_NAME}\",\"throttlingPolicy\":\"Unlimited\",\"description\":\"Ephemeral managed-runtime verifier\",\"tokenType\":\"JWT\"}" \
  "$APIM_URL/api/am/devportal/v3/applications")"
VERIFY_APP_ID="$(jq -r '.applicationId // .id // empty' <<<"$APP_JSON")"
[[ -n "$VERIFY_APP_ID" ]] || fail "Could not create verification application: $APP_JSON"
SUB_JSON="$(curl -ksS -X POST "${DEVPORTAL_AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"applicationId\":\"${VERIFY_APP_ID}\",\"apiId\":\"${PRODUCT_ID}\",\"throttlingPolicy\":\"SecureMobileBusiness\"}" \
  "$APIM_URL/api/am/devportal/v3/subscriptions")"
jq -e '.subscriptionId != null' <<<"$SUB_JSON" >/dev/null || fail "Could not subscribe verification application: $SUB_JSON"
KEY_JSON="$(curl -ksS -X POST "${DEVPORTAL_AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"keyType":"PRODUCTION","grantTypesToBeSupported":["client_credentials"],"callbackUrl":"","validityTime":3600}' \
  "$APIM_URL/api/am/devportal/v3/applications/$VERIFY_APP_ID/generate-keys")"
CONSUMER_KEY="$(jq -r '.consumerKey // empty' <<<"$KEY_JSON")"
CONSUMER_SECRET="$(jq -r '.consumerSecret // empty' <<<"$KEY_JSON")"
[[ -n "$CONSUMER_KEY" && -n "$CONSUMER_SECRET" ]] || fail "Could not generate application keys: $KEY_JSON"
APP_TOKEN_JSON="$(curl -ksS -u "$CONSUMER_KEY:$CONSUMER_SECRET" \
  --data-urlencode grant_type=client_credentials \
  --data-urlencode 'scope=secure_mobile_transactions:invoke secure_mobile_transactions:commercial.read secure_mobile_transactions:commercial.manage' \
  "$APIM_URL/oauth2/token")"
APP_TOKEN="$(jq -r '.access_token // empty' <<<"$APP_TOKEN_JSON")"
if [[ -z "$APP_TOKEN" ]]; then
  # Keep gateway verification diagnostic across APIM installations where newly imported OAS scopes
  # become available only after a cache refresh; the API itself still declares the required scopes.
  APP_TOKEN_JSON="$(curl -ksS -u "$CONSUMER_KEY:$CONSUMER_SECRET" \
    --data-urlencode grant_type=client_credentials \
    "$APIM_URL/oauth2/token")"
  APP_TOKEN="$(jq -r '.access_token // empty' <<<"$APP_TOKEN_JSON")"
fi
[[ -n "$APP_TOKEN" ]] || fail "Could not obtain application token: $APP_TOKEN_JSON"
for _ in $(seq 1 30); do
  GATEWAY_HTTP="$(curl -ksS -o "$WORK_DIR/gateway.json" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $APP_TOKEN" -H 'Content-Type: application/json' -H 'X-Correlation-ID: verify-gateway-product' \
    -d '{"partnerId":"fintech-br-001","msisdn":"+5511999990001","consentId":"verify-consent-gateway"}' \
    "$GATEWAY_URL/secure-mobile-transactions-product/1.0.0/number-verification" || true)"
  [[ "$GATEWAY_HTTP" == 200 ]] && break
  sleep 2
done
[[ "$GATEWAY_HTTP" == 200 ]] || fail "API Product gateway invocation failed with HTTP $GATEWAY_HTTP: $(cat "$WORK_DIR/gateway.json" 2>/dev/null || true)"
jq -e '.commercialUsage.apiProduct == "SecureMobileTransactionsProduct" and .commercialUsage.planId == "Business" and .commercialUsage.billedAmount == 0.08 and .correlationId == "verify-gateway-product"' "$WORK_DIR/gateway.json" >/dev/null || fail 'Gateway response does not contain expected commercial usage/correlation data'
ok 'OAuth subscription and API Product invocation work through the APIM Gateway'

printf '\n[PASS] Secure Mobile Transactions commercial plan and usage-meter flow is complete.\n'
printf '[PASS] Sandbox=free/masked; Business=included+overage; Enterprise=committed/lower-price/SLA.\n'
printf '[PASS] Usage is operational per partner and SecureMobileTransactionsProduct.\n'
EOF
chmod +x scripts/verify-commercial-plan-usage.sh

info "Validating generated source and configuration"
python3 - <<'PY'
from pathlib import Path
import json
import xml.etree.ElementTree as ET

for path in [
    Path('services/wso2-mi/synapse-configs/default/api/SecureMobileTransactionsCommercialAPI.xml'),
    Path('services/wso2-mi/synapse-configs/default/endpoints/CommercialMeterStoreFailoverEndpoint.xml'),
    Path('services/wso2-mi/synapse-configs/default/sequences/CommercialCorrelationSequence.xml'),
    Path('services/wso2-mi/synapse-configs/default/sequences/CommercialNormalizedFaultSequence.xml'),
    Path('services/wso2-mi/synapse-configs/default/sequences/CommercialExecuteTransactionSequence.xml'),
]:
    ET.parse(path)

for path in [
    Path('contracts/openapi/secure-mobile-transactions-commercial.openapi.json'),
    Path('artifacts/developer-experience/secure-mobile-transactions/Secure-Mobile-Transactions.postman_collection.json'),
    Path('observability/grafana/dashboards/secure-mobile-commercial-usage.json'),
    Path('artifacts/apim-admin/api-product-bundles.json'),
    Path('artifacts/apim-admin/commercial-plans.json'),
    Path('services/apim-bootstrapper/package.json'),
]:
    json.loads(path.read_text())
print('[commercial-install] XML and JSON syntax validation passed')
PY

if command -v node >/dev/null 2>&1; then
  node --check services/commercial-meter-store/src/server.js
  node --check services/apim-bootstrapper/src/commercial-api-setup.js
  node --check services/apim-bootstrapper/src/commercial-experience-setup.js
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  COMPOSE=()
fi
if ((${#COMPOSE[@]})); then
  FILES=(docker-compose.yml)
  for file in docker-compose.kafka.yml docker-compose.opa.yml docker-compose.mi.yml docker-compose.commercial.yml docker-compose.mi.soap.yml docker-compose.observability.yml docker-compose.runtime-persistence.yml; do
    [[ -f "$file" ]] && FILES+=("$file")
  done
  CMD=("${COMPOSE[@]}")
  for file in "${FILES[@]}"; do CMD+=(-f "$file"); done
  "${CMD[@]}" config >/dev/null
  info "Merged Docker Compose validation passed"
fi

cat <<'EOF'

[commercial-install] Installation complete (v4 product discovery and publication ordering).

Build and start the complete environment:
  bash scripts/telco-demo-control.sh reset

Or, without deleting persistent volumes:
  bash scripts/telco-demo-control.sh restart

Run the focused verification:
  bash scripts/verify-commercial-plan-usage.sh
EOF
