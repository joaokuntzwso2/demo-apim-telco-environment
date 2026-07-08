'use strict';

const fs = require('fs');
const path = require('path');
const { fetch, Agent } = require('undici');

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
const dispatcher = new Agent({ connect: { rejectUnauthorized: false } });
const APIM_URL = process.env.WSO2_APIM_URL || 'https://wso2-apim:9443';
const MI_URL = (process.env.WSO2_MI_URL || 'http://wso2-mi:8290').replace(/\/+$/, '');
const USERNAME = process.env.APIM_USERNAME || 'admin';
const PASSWORD = process.env.APIM_PASSWORD || 'admin';
const STATE_FILE = process.env.AUDIT_SIEM_BOOTSTRAP_STATE_FILE || '/workspace/state/audit-siem-bootstrap-events.json';
const APP_NAME = process.env.AUDIT_SIEM_APPLICATION_NAME || 'Audit SIEM Verifier';
const POLICY_NAME = 'TelcoSecurityAuditBurst';

function log(message) { console.log(`[Audit SIEM Bootstrap] ${message}`); }
function sleep(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }

async function request(url, { method = 'GET', bearer, basic, json, body: rawBody, headers = {}, ok = [200, 201, 202, 204] } = {}) {
  const requestHeaders = { ...headers };
  if (bearer) requestHeaders.Authorization = `Bearer ${bearer}`;
  if (basic) requestHeaders.Authorization = `Basic ${Buffer.from(basic).toString('base64')}`;
  let body = rawBody;
  if (json !== undefined) {
    requestHeaders['Content-Type'] = 'application/json';
    body = JSON.stringify(json);
  }
  const response = await fetch(url, { method, headers: requestHeaders, body, dispatcher });
  const text = await response.text();
  let data = text;
  try { data = text ? JSON.parse(text) : null; } catch { /* preserve text */ }
  if (!ok.includes(response.status)) {
    throw new Error(`${method} ${url} -> HTTP ${response.status}: ${typeof data === 'string' ? data : JSON.stringify(data)}`);
  }
  return data;
}

async function waitFor(url, label) {
  for (let attempt = 1; attempt <= 60; attempt += 1) {
    try {
      const response = await fetch(url, { dispatcher });
      if (response.ok) return;
    } catch { /* starting */ }
    log(`Waiting for ${label} (${attempt}/60)...`);
    await sleep(3000);
  }
  throw new Error(`${label} did not become ready: ${url}`);
}

async function managementToken() {
  const dcr = await request(`${APIM_URL}/client-registration/v0.17/register`, {
    method: 'POST',
    basic: `${USERNAME}:${PASSWORD}`,
    json: {
      callbackUrl: 'http://localhost:8080/callback',
      clientName: `telco-audit-siem-bootstrap-${Date.now()}`,
      owner: USERNAME,
      grantType: 'password refresh_token client_credentials',
      saasApp: true
    },
    ok: [200, 201]
  });
  const candidates = [
    [
      'apim:api_view', 'apim:api_product_view', 'apim:admin_tier_view',
      'apim:subscribe', 'apim:app_manage', 'apim:sub_manage',
      'apim:api_key', 'apim:api_generate_key'
    ],
    [
      'apim:api_view', 'apim:api_product_view',
      'apim:subscribe', 'apim:app_manage', 'apim:sub_manage',
      'apim:api_key', 'apim:api_generate_key'
    ]
  ];
  let lastError;
  for (const scopes of candidates) {
    const form = new URLSearchParams();
    form.set('grant_type', 'password');
    form.set('username', USERNAME);
    form.set('password', PASSWORD);
    form.set('scope', scopes.join(' '));
    try {
      const token = await request(`${APIM_URL}/oauth2/token`, {
        method: 'POST',
        basic: `${dcr.clientId}:${dcr.clientSecret}`,
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: form.toString(),
        ok: [200]
      });
      if (token?.access_token) return token.access_token;
    } catch (error) {
      lastError = error;
      log(`Token scope set rejected; trying compatible fallback: ${error.message}`);
    }
  }
  throw lastError || new Error('Could not obtain an APIM management token.');
}

function stateFromDisk() {
  if (!fs.existsSync(STATE_FILE)) return {};
  try { return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')); } catch { return {}; }
}

async function getOrCreateApplication(token) {
  const existing = await request(`${APIM_URL}/api/am/devportal/v3/applications?query=${encodeURIComponent(APP_NAME)}&limit=100`, { bearer: token });
  const application = (existing.list || existing.data || []).find(item => item.name === APP_NAME);
  const applicationId = application?.applicationId || application?.id;
  if (applicationId) {
    log(`using existing DevPortal application: ${APP_NAME} (${applicationId})`);
    return applicationId;
  }
  const created = await request(`${APIM_URL}/api/am/devportal/v3/applications`, {
    method: 'POST',
    bearer: token,
    json: {
      name: APP_NAME,
      throttlingPolicy: 'Unlimited',
      description: 'Idempotent application used to validate the audit/SIEM scenario and the TelcoSecurityAuditBurst subscription policy.'
    },
    ok: [200, 201, 202]
  });
  const id = created.applicationId || created.id;
  if (!id) throw new Error(`Application creation did not return an ID: ${JSON.stringify(created)}`);
  log(`created DevPortal application: ${APP_NAME} (${id})`);
  return id;
}

async function ensureSubscription(token, applicationId, apiId, apiName) {
  await request(`${APIM_URL}/api/am/devportal/v3/subscriptions`, {
    method: 'POST',
    bearer: token,
    json: { applicationId, apiId, throttlingPolicy: POLICY_NAME },
    ok: [200, 201, 202, 409]
  });
  log(`subscription ensured: ${APP_NAME} -> ${apiName} (${POLICY_NAME})`);
}

function normalizeKey(payload) {
  const key = payload?.keyMapping || payload || {};
  return {
    keyMappingId: key.keyMappingId || key.id || null,
    keyType: key.keyType || 'PRODUCTION',
    consumerKey: key.consumerKey || key.consumer_key || null,
    consumerSecret: key.consumerSecret || key.consumer_secret || null
  };
}

async function getExistingProductionKey(token, applicationId) {
  const response = await request(`${APIM_URL}/api/am/devportal/v3/applications/${applicationId}/oauth-keys`, { bearer: token });
  const keys = response.list || response.data || [];
  const production = keys.find(item => String(item?.keyType || '').toUpperCase() === 'PRODUCTION');
  return production ? normalizeKey(production) : null;
}

async function deleteKeyMapping(token, applicationId, keyMappingId) {
  await request(`${APIM_URL}/api/am/devportal/v3/applications/${applicationId}/oauth-keys/${keyMappingId}`, {
    method: 'DELETE', bearer: token, ok: [200, 202, 204, 404]
  });
}

async function generateProductionKeys(token, applicationId, priorApplication = {}, allowCleanup = true) {
  const existing = await getExistingProductionKey(token, applicationId);
  if (existing?.consumerKey && existing?.consumerSecret) return existing;
  if (
    existing?.consumerKey && priorApplication?.consumerKey === existing.consumerKey &&
    priorApplication?.consumerSecret
  ) {
    log(`reusing persisted production secret for ${APP_NAME}`);
    return { ...existing, consumerSecret: priorApplication.consumerSecret };
  }
  if (existing?.keyMappingId && allowCleanup) {
    log(`removing incomplete production key mapping ${existing.keyMappingId} once`);
    await deleteKeyMapping(token, applicationId, existing.keyMappingId);
  }
  const endpoint = `${APIM_URL}/api/am/devportal/v3/applications/${applicationId}/generate-keys`;
  const bodies = [
    { keyType: 'PRODUCTION', grantTypesToBeSupported: ['client_credentials'], callbackUrl: 'http://localhost:8080/callback', validityTime: '3600' },
    { keyType: 'PRODUCTION', grantTypesToBeSupported: ['client_credentials'] }
  ];
  let lastError = 'unknown error';
  for (const body of bodies) {
    const response = await fetch(endpoint, {
      method: 'POST', dispatcher,
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    });
    const text = await response.text();
    let data = text;
    try { data = text ? JSON.parse(text) : null; } catch { /* preserve text */ }
    if (response.ok) {
      const generated = normalizeKey(data);
      if (generated.consumerKey && generated.consumerSecret) return generated;
      lastError = `successful response omitted credentials: ${JSON.stringify(data)}`;
      continue;
    }
    lastError = `HTTP ${response.status}: ${typeof data === 'string' ? data : JSON.stringify(data)}`;
    if (response.status === 409 && allowCleanup) {
      const recovered = await getExistingProductionKey(token, applicationId);
      if (
        recovered?.consumerKey && priorApplication?.consumerKey === recovered.consumerKey &&
        priorApplication?.consumerSecret
      ) return { ...recovered, consumerSecret: priorApplication.consumerSecret };
      if (recovered?.keyMappingId) {
        await deleteKeyMapping(token, applicationId, recovered.keyMappingId);
        return generateProductionKeys(token, applicationId, priorApplication, false);
      }
    }
  }
  throw new Error(`Production key generation failed for ${APP_NAME}: ${lastError}`);
}

async function emit(event) {
  const correlationId = `audit-bootstrap-${event.eventType.toLowerCase()}-${Date.now()}`;
  const response = await request(`${MI_URL}/audit-events/v1/events`, {
    method: 'POST',
    headers: { 'X-Correlation-ID': correlationId },
    json: event,
    ok: [202]
  });
  log(`emitted ${event.eventType}; auditId=${response.auditId}; correlationId=${response.correlationId}`);
  return response;
}

async function main() {
  await waitFor(`${APIM_URL}/services/Version`, 'WSO2 API Manager');
  await waitFor(`${MI_URL}/audit-events/v1/health`, 'MI Audit Events API');
  const prior = stateFromDisk();
  const token = await managementToken();
  const apis = await request(`${APIM_URL}/api/am/publisher/v4/apis?limit=1000`, { bearer: token });
  const products = await request(`${APIM_URL}/api/am/publisher/v4/api-products?limit=1000`, { bearer: token });
  const policies = await request(`${APIM_URL}/api/am/admin/v4/throttling/policies/subscription?limit=1000`, { bearer: token });

  const api = (apis.list || apis.data || []).find(item => item.name === 'TelcoAuditEventsAPI' && String(item.version) === '1.0.0');
  const simApi = (apis.list || apis.data || []).find(item => item.name === 'OpenGatewaySimSwapRiskAPI' && String(item.version) === '1.0.0');
  const product = (products.list || products.data || []).find(item => item.name === 'TelcoAuditSIEMProduct' && String(item.version) === '1.0.0');
  const policy = (policies.list || policies.data || []).find(item => item.policyName === POLICY_NAME);
  if (!api) throw new Error('TelcoAuditEventsAPI:1.0.0 is absent after bootstrap.');
  if (!simApi) throw new Error('OpenGatewaySimSwapRiskAPI:1.0.0 is absent after bootstrap.');
  if (!product) throw new Error('TelcoAuditSIEMProduct:1.0.0 is absent after bootstrap.');
  if (!policy) throw new Error(`${POLICY_NAME} is absent after bootstrap.`);
  if (String(api.lifeCycleStatus || api.state || '').toUpperCase() !== 'PUBLISHED') throw new Error('TelcoAuditEventsAPI is not PUBLISHED.');
  if (String(product.lifeCycleStatus || product.state || '').toUpperCase() !== 'PUBLISHED') throw new Error('TelcoAuditSIEMProduct is not PUBLISHED.');

  const applicationId = await getOrCreateApplication(token);
  await ensureSubscription(token, applicationId, api.id, api.name);
  await ensureSubscription(token, applicationId, simApi.id, simApi.name);
  const keys = await generateProductionKeys(token, applicationId, prior.application || {});
  if (!keys.consumerKey || !keys.consumerSecret) throw new Error('Audit SIEM verifier credentials are incomplete.');

  const application = {
    name: APP_NAME,
    applicationId,
    keyType: 'PRODUCTION',
    keyMappingId: keys.keyMappingId || null,
    consumerKey: keys.consumerKey,
    consumerSecret: keys.consumerSecret,
    subscriptionPolicy: POLICY_NAME,
    subscribedApis: [api.name, simApi.name]
  };
  const fingerprint = [
    api.id, api.lifeCycleStatus || api.state || '', simApi.id,
    product.id, product.lifeCycleStatus || product.state || '',
    policy.policyName, applicationId, keys.consumerKey
  ].join('|');

  if (prior.fingerprint === fingerprint && Array.isArray(prior.emitted) && prior.emitted.length === 5) {
    fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
    fs.writeFileSync(STATE_FILE, JSON.stringify({ ...prior, generatedAt: new Date().toISOString(), application }, null, 2));
    log('management-plane events already emitted for the current APIM object fingerprint; subscriptions and credentials were revalidated without duplicate emission.');
    return;
  }

  const now = new Date().toISOString();
  const common = { actor: USERNAME, timestamp: now, country: 'BR' };
  const events = [
    { ...common, eventType: 'API_PUBLICATION', resource: 'TelcoAuditEventsAPI:1.0.0', action: 'PUBLISH_API', result: 'SUCCESS', details: { apiId: api.id, lifecycleStatus: api.lifeCycleStatus || api.state } },
    { ...common, eventType: 'POLICY_MODIFICATION', resource: POLICY_NAME, action: 'UPSERT_SUBSCRIPTION_POLICY', result: 'SUCCESS', details: { requestCount: 5, timeUnit: 'min', billingPlan: 'COMMERCIAL' } },
    { ...common, eventType: 'SUBSCRIPTION_APPROVAL', resource: `${APP_NAME} -> ${simApi.name}`, action: 'APPROVE_SUBSCRIPTION', result: 'SUCCESS', details: { applicationId, apiId: simApi.id, throttlingPolicy: POLICY_NAME } },
    { ...common, eventType: 'CREDENTIAL_CREATION', resource: `${APP_NAME} production OAuth credential`, action: 'GENERATE_CREDENTIAL', result: 'SUCCESS', details: { applicationId, keyMappingId: keys.keyMappingId || null, keyType: 'PRODUCTION', secretMaterialIncluded: false } },
    { ...common, eventType: 'ADMINISTRATOR_ACTION', resource: 'TelcoAuditSIEMProduct:1.0.0', action: 'BOOTSTRAP_AUDIT_SIEM_SCENARIO', result: 'SUCCESS', details: { apiProductId: product.id, policyName: policy.policyName } }
  ];
  const emitted = [];
  for (const event of events) emitted.push(await emit(event));
  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify({ generatedAt: new Date().toISOString(), fingerprint, application, emitted }, null, 2));
  log(`wrote state: ${STATE_FILE}`);
}

main().catch(error => {
  console.error(`[Audit SIEM Bootstrap] failed: ${error.stack || error.message}`);
  process.exit(1);
});
