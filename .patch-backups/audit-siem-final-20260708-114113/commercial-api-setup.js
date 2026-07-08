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

// commercial-api-idempotency-v3
function normalizeApiContext(value) {
  return String(value || '').replace(/\/+$/, '');
}

function isExpectedCommercialApi(candidate) {
  return Boolean(
    candidate
    && candidate.name === API_NAME
    && candidate.version === API_VERSION
  );
}

async function readApiById(publisherToken, apiId) {
  if (!apiId) return null;

  const result = await request(
    `${APIM_URL}/api/am/publisher/v4/apis/${encodeURIComponent(apiId)}`,
    {
      headers: auth(publisherToken)
    },
    [200, 404]
  );

  if (result.status === 404) return null;
  return isExpectedCommercialApi(result.data) ? result.data : null;
}

async function scanApiList(publisherToken, query = null) {
  const limit = 100;

  for (let offset = 0; offset < 5000; offset += limit) {
    const queryPart = query
      ? `&query=${encodeURIComponent(query)}`
      : '';

    let result;

    try {
      result = await request(
        `${APIM_URL}/api/am/publisher/v4/apis?limit=${limit}&offset=${offset}${queryPart}`,
        {
          headers: auth(publisherToken)
        }
      );
    } catch (error) {
      log(
        `API lookup ${query || '<unfiltered>'} failed: `
        + `${error.message || error}`
      );
      return null;
    }

    const list = Array.isArray(result.data?.list)
      ? result.data.list
      : [];

    for (const summary of list) {
      if (!isExpectedCommercialApi(summary)) continue;

      const full = await readApiById(publisherToken, summary.id);
      if (!full) continue;

      if (
        normalizeApiContext(full.context)
        !== normalizeApiContext(API_CONTEXT)
      ) {
        log(
          `Resolved API ${full.id} by name/version. `
          + `Stored context is ${full.context}; desired context is ${API_CONTEXT}.`
        );
      }

      return full;
    }

    const total = Number(result.data?.count);

    if (list.length < limit) break;

    if (
      Number.isFinite(total)
      && total >= 0
      && offset + list.length >= total
    ) {
      break;
    }
  }

  return null;
}

async function findApi(publisherToken) {
  const statePath = '/workspace/state/commercial-api.json';

  /*
   * First use the durable bootstrap state. This is the most deterministic
   * recovery route after a persisted APIM restart.
   */
  try {
    if (fs.existsSync(statePath)) {
      const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
      const fromState = await readApiById(publisherToken, state.apiId);

      if (fromState) {
        log(`Resolved existing API from bootstrap state: ${fromState.id}`);
        return fromState;
      }

      log(
        `Bootstrap state referenced unavailable API ${state.apiId || '<empty>'}; `
        + 'continuing with Publisher API discovery.'
      );
    }
  } catch (error) {
    log(`Ignoring invalid commercial API bootstrap state: ${error.message}`);
  }

  /*
   * Try focused Publisher searches first. Search syntax and returned context
   * representation can vary, so name/version—not an exact context string—is
   * the identity used for duplicate recovery.
   */
  const queries = [
    `name:${API_NAME}`,
    API_NAME,
    `context:${API_CONTEXT}`
  ];

  for (const query of queries) {
    const found = await scanApiList(publisherToken, query);
    if (found) return found;
  }

  /*
   * Final fallback: paginate through all APIs. This protects idempotency when
   * the Publisher search index has not caught up with the persisted database.
   */
  return scanApiList(publisherToken, null);
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
let createdNow = false;

if (!api) {
  try {
    const created = await request(
      `${APIM_URL}/api/am/publisher/v4/apis`,
      {
        method: 'POST',
        headers: auth(
          publisherToken,
          {
            'content-type': 'application/json'
          }
        ),
        body: JSON.stringify(apiPayload())
      }
    );

    api = created.data;
    createdNow = true;
    log(`Created API ${api.id}`);
  } catch (error) {
    const message = String(error?.message || error);

    if (!message.includes('HTTP 409')) {
      throw error;
    }

    log(
      'Create returned HTTP 409; resolving the existing APIM API '
      + 'instead of treating the duplicate as fatal.'
    );

    /*
     * APIM database persistence and Publisher search indexing may become
     * visible at slightly different moments. Retry with a bounded delay.
     */
    for (let attempt = 1; attempt <= 12; attempt += 1) {
      api = await findApi(publisherToken);

      if (api) {
        log(
          `Recovered existing API ${api.id} after HTTP 409 `
          + `(attempt ${attempt}).`
        );
        break;
      }

      await sleep(Math.min(500 * attempt, 3000));
    }

    if (!api) {
      throw new Error(
        `APIM reported that ${API_NAME}:${API_VERSION} already exists, `
        + 'but it could not be resolved through state, filtered search, '
        + 'or complete paginated discovery.'
      );
    }
  }
}

if (!api?.id) {
  throw new Error(
    `Commercial API resolution did not return a valid API ID: `
    + `${JSON.stringify(api)}`
  );
}

const currentMarker = (
  api.additionalProperties || []
).find(
  (item) => item.name === 'CommercialFlowVersion'
)?.value;

if (!createdNow && currentMarker !== MARKER) {
  const updated = await request(
    `${APIM_URL}/api/am/publisher/v4/apis/${encodeURIComponent(api.id)}`,
    {
      method: 'PUT',
      headers: auth(
        publisherToken,
        {
          'content-type': 'application/json'
        }
      ),
      body: JSON.stringify(apiPayload(api))
    }
  );

  api = updated.data;
  log(`Reconciled existing API ${api.id} with the desired configuration.`);
} else if (createdNow) {
  log(`API ${api.id} was created with marker ${MARKER}.`);
} else {
  log(`API ${api.id} already carries marker ${MARKER}.`);
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
