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
