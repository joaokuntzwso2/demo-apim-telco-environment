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
