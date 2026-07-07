'use strict';

const fs = require('fs');
const path = require('path');
const { fetch, FormData, Agent } = require('undici');

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
const dispatcher = new Agent({ connect: { rejectUnauthorized: false } });
const APIM_URL = process.env.WSO2_APIM_URL || 'https://wso2-apim:9443';
const USERNAME = process.env.APIM_USERNAME || 'admin';
const PASSWORD = process.env.APIM_PASSWORD || 'admin';
const STATE_FILE = process.env.APIM_SIDDHI_RUNTIME_STATE_FILE || '/workspace/state/siddhi-runtime-enforcement.json';
const CONTRACT_ROOT = process.env.APIM_CONTRACT_ROOT || '/workspace/contracts/openapi';
const DOCUMENT_NAME = '10 - Runtime Business Controls';

const TARGETS = {
  OpenGatewaySimSwapRiskAPI: {
    contract: 'open-gateway-sim-swap-risk.openapi.yaml',
    swaggerMarker: 'TelcoSiddhiSimSwapFraudFairUsePolicy',
    policy: 'TelcoSiddhiSimSwapFraudFairUsePolicy',
    context: '/open-gateway/sim-swap/v1',
    threshold: 6,
    window: '15 seconds',
    retryAfter: 15,
    scope: 'opengateway_sim_swap',
    product: 'OpenGatewayFraudDefenseProduct',
    plans: ['TelcoFreeTrial', 'TelcoOpenGatewayTrustStarter', 'TelcoOpenGatewayTrustPremium'],
    sample: `curl -k -i \\
  -H "Authorization: Bearer \${ACCESS_TOKEN}" \\
  -H "X-Partner-Id: digital-bank-demo" \\
  -H "X-Correlation-ID: sim-swap-demo-001" \\
  "https://localhost:8243/open-gateway/sim-swap/v1/1.0.0/api/v1/open-gateway/sim-swap/%2B525512340001/risk?lookbackHours=168"`
  },
  NetworkSliceAPI: {
    contract: 'network-slice.openapi.yaml',
    swaggerMarker: 'createQualityOnDemandSession',
    policy: 'TelcoSiddhiQoDAssuranceBurstPolicy',
    context: '/network-slice/v1',
    threshold: 9,
    window: '5 seconds',
    retryAfter: 5,
    scope: 'network.qod.request',
    product: 'FiveGNetworkMonetizationProduct',
    plans: ['TelcoPartnerStandard', 'TelcoPartnerPremium'],
    sample: `curl -k -i -X POST \\
  -H "Authorization: Bearer \${ACCESS_TOKEN}" \\
  -H "Content-Type: application/json" \\
  -H "X-Partner-Id: enterprise-qod-demo" \\
  -H "X-Correlation-ID: qod-demo-001" \\
  -d '{"device":{"phoneNumber":"+525512340001"},"area":{"type":"CELL_ID","value":"MX-MEX-CELL-001"},"profile":"QOD_GOLD","durationSeconds":120,"maxLatencyMs":20,"minThroughputMbps":100}' \\
  "https://localhost:8243/network-slice/v1/1.0.0/api/v1/network/qod/sessions"`
  }
};

class HttpError extends Error {
  constructor(method, url, status, data) {
    super(`${method} ${url} -> HTTP ${status}: ${typeof data === 'string' ? data : JSON.stringify(data)}`);
    this.status = status;
    this.data = data;
  }
}

function log(message) {
  console.log(`[Siddhi Runtime Enforcement] ${message}`);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function loadState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  } catch {
    return {};
  }
}

function saveState(state) {
  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2) + '\n');
}

async function request(url, { method = 'GET', bearer, basic, json, body, headers = {}, ok = [200, 201, 202, 204] } = {}) {
  const requestHeaders = { ...headers };
  if (bearer) requestHeaders.Authorization = `Bearer ${bearer}`;
  if (basic) requestHeaders.Authorization = `Basic ${Buffer.from(basic).toString('base64')}`;
  if (json !== undefined) {
    requestHeaders['Content-Type'] = 'application/json';
    body = JSON.stringify(json);
  }
  const response = await fetch(url, { method, headers: requestHeaders, body, dispatcher });
  const text = await response.text();
  let data = text;
  try { data = text ? JSON.parse(text) : null; } catch { /* keep text */ }
  if (!ok.includes(response.status)) throw new HttpError(method, url, response.status, data);
  return data;
}

async function waitForApim() {
  for (let attempt = 1; attempt <= 90; attempt += 1) {
    try {
      const response = await fetch(`${APIM_URL}/services/Version`, { dispatcher });
      if (response.ok) return;
    } catch { /* APIM is starting */ }
    await sleep(5000);
  }
  throw new Error(`APIM did not become reachable at ${APIM_URL}`);
}

async function accessToken(clientId, clientSecret) {
  const form = new URLSearchParams();
  form.set('grant_type', 'password');
  form.set('username', USERNAME);
  form.set('password', PASSWORD);
  form.set('scope', [
    'apim:api_view',
    'apim:api_metadata_view',
    'apim:api_create',
    'apim:api_publish',
    'apim:document_create',
    'apim:document_manage',
    'apim:document_update'
  ].join(' '));
  const token = await request(`${APIM_URL}/oauth2/token`, {
    method: 'POST',
    basic: `${clientId}:${clientSecret}`,
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: form.toString(),
    ok: [200]
  });
  if (!token.access_token) throw new Error('Publisher token response did not contain access_token');
  return token.access_token;
}

async function publisherToken(state) {
  const saved = state.oauth || {};
  if (saved.clientId && saved.clientSecret) {
    try {
      return { token: await accessToken(saved.clientId, saved.clientSecret), oauth: saved };
    } catch (error) {
      log(`Stored OAuth client is unusable; registering a replacement (${error.message})`);
    }
  }

  const dcr = await request(`${APIM_URL}/client-registration/v0.17/register`, {
    method: 'POST',
    basic: `${USERNAME}:${PASSWORD}`,
    json: {
      callbackUrl: 'http://localhost:8080/callback',
      clientName: `telco-siddhi-runtime-${Date.now()}`,
      owner: USERNAME,
      grantType: 'password refresh_token client_credentials',
      saasApp: true
    },
    ok: [200, 201]
  });
  const oauth = { clientId: dcr.clientId, clientSecret: dcr.clientSecret };
  if (!oauth.clientId || !oauth.clientSecret) throw new Error('Dynamic client registration did not return credentials');
  state.oauth = oauth;
  saveState(state);
  return { token: await accessToken(oauth.clientId, oauth.clientSecret), oauth };
}

function contractText(cfg) {
  const candidate = path.join(CONTRACT_ROOT, cfg.contract);
  if (!fs.existsSync(candidate)) throw new Error(`Runtime API contract is missing: ${candidate}`);
  return fs.readFileSync(candidate, 'utf8');
}

function textValue(value) {
  return typeof value === 'string' ? value : JSON.stringify(value);
}

function deploymentList(value) {
  return Array.isArray(value) ? value : (value?.list || value?.data || value?.deployments || []);
}

function currentDeploymentEnvironments(deployments) {
  const result = [];
  const seen = new Set();
  for (const item of deploymentList(deployments)) {
    const info = item.deploymentInfo || item;
    const name = info.name || info.environment || item.name || item.environment;
    if (!name || seen.has(name)) continue;
    seen.add(name);
    result.push({
      name,
      vhost: info.vhost || item.vhost || 'localhost',
      displayOnDevportal: info.displayOnDevportal ?? item.displayOnDevportal ?? true
    });
  }
  return result.length ? result : [{ name: 'Default', vhost: 'localhost', displayOnDevportal: true }];
}

function revisionId(value) {
  return value?.id || value?.revisionId || value?.revisionUuid || value?.uuid;
}

async function createRevision(token, api, deployments) {
  const base = `${APIM_URL}/api/am/publisher/v4/apis/${api.id}/revisions`;
  const create = () => request(base, {
    method: 'POST',
    bearer: token,
    json: { description: 'Runtime Siddhi controls: live OpenAPI, QoD resource and normalized 429 contract.' },
    ok: [200, 201]
  });
  try {
    return await create();
  } catch (error) {
    if (!(error instanceof HttpError) || error.status !== 409) throw error;
    const revisions = await request(`${base}?limit=100`, { bearer: token });
    const deployed = new Set(deploymentList(deployments).map(revisionId).filter(Boolean));
    const candidate = deploymentList(revisions).find(item => {
      const id = revisionId(item);
      return id && !deployed.has(id);
    });
    const removable = revisionId(candidate);
    if (!removable) throw new Error(`Cannot create a revision for ${api.name}: APIM revision limit reached and every revision is deployed.`);
    await request(`${base}/${encodeURIComponent(removable)}`, { method: 'DELETE', bearer: token, ok: [200, 204] });
    log(`Deleted undeployed revision ${removable} for ${api.name}`);
    return create();
  }
}

async function ensureLiveDefinition(token, api, cfg) {
  const swaggerUrl = `${APIM_URL}/api/am/publisher/v4/apis/${api.id}/swagger`;
  const current = await request(swaggerUrl, { bearer: token });
  if (textValue(current).includes(cfg.swaggerMarker)) {
    log(`${api.name}:1.0.0 already has the runtime OpenAPI definition`);
    return { changed: false };
  }

  const form = new FormData();
  form.set('apiDefinition', contractText(cfg));
  await request(swaggerUrl, { method: 'PUT', bearer: token, body: form, ok: [200] });
  log(`Updated live OpenAPI definition for ${api.name}:1.0.0`);

  const deployments = await request(`${APIM_URL}/api/am/publisher/v4/apis/${api.id}/deployments`, { bearer: token });
  const revision = await createRevision(token, api, deployments);
  const id = revisionId(revision);
  if (!id) throw new Error(`Revision ID missing after updating ${api.name}:1.0.0`);
  await request(`${APIM_URL}/api/am/publisher/v4/apis/${api.id}/deploy-revision?revisionId=${encodeURIComponent(id)}`, {
    method: 'POST',
    bearer: token,
    json: currentDeploymentEnvironments(deployments),
    ok: [200, 201]
  });
  log(`Created and deployed revision ${id} for ${api.name}:1.0.0`);
  return { changed: true, revisionId: id };
}

function documentContent(api, cfg) {
  return `# Runtime Business Controls

## Enforcement point

This API is protected in the **WSO2 API Manager 4.7 runtime** by the custom Siddhi policy \`${cfg.policy}\`. The policy is evaluated by the APIM Traffic Manager using the real API context/version${api.name === 'OpenGatewaySimSwapRiskAPI' ? ' and consuming application identifier' : ''}; it is not only an uploaded Admin Portal artifact.

## Demonstration limit

- API context: \`${cfg.context}\`
- API version: \`${api.version}\`
- Demo threshold: **${cfg.threshold} requests per ${cfg.window} Siddhi time batch**
- OAuth scope: \`${cfg.scope}\`
- API Product: \`${cfg.product}\`
- Commercial/subscription policies: ${cfg.plans.map(value => `\`${value}\``).join(', ')}

The threshold is intentionally low for a deterministic demonstration. Production values must be derived from contracted partner entitlement, backend capacity, SLA and fraud/network risk appetite.

## 429 response contract

When the policy is active, APIM returns \`429 Too Many Requests\` with:

- \`Retry-After: ${cfg.retryAfter}\`
- \`RateLimit-Limit\`, \`RateLimit-Remaining\`, \`RateLimit-Reset\`
- \`RateLimit-Policy: ${cfg.policy}\`
- compatibility \`X-RateLimit-*\` headers
- \`X-Correlation-ID\`
- an \`application/problem+json\` body containing the partner, API, application, policy and correlation identifiers

Consumers must honor \`Retry-After\`, use bounded exponential backoff with jitter, and must not evade fair use by creating duplicate applications.

## Observable alert

For custom-policy error code \`900806\`, the APIM throttle-out sequence asynchronously calls the MI-managed \`RuntimePolicyAlertAPI\`. MI validates the event, preserves the correlation identifier, and publishes it to Kafka topic \`telco.runtime.policy.alerts\` through a timeout/retry/suspension-protected endpoint. Alert delivery is a non-blocking partial-response path: an alert failure cannot replace the client-facing 429.

Every alert includes:

- \`policyName\`
- \`partnerId\`
- \`apiName\`, \`apiContext\`, \`apiVersion\`
- \`applicationId\`, \`applicationName\`
- \`correlationId\`
- HTTP status, APIM error code, limit and retry interval

## Consent and privacy

The rate-control event contains operational identifiers, not SIM, location or request payload data. The consuming application remains responsible for purpose-bound consent/legal basis for the underlying API operation and for avoiding personal data in partner/correlation headers.

## Sandbox request

\`\`\`bash
export ACCESS_TOKEN='<application access token with ${cfg.scope}>'
${cfg.sample}
\`\`\`

Repeat the request rapidly using a unique correlation ID for each policy demonstration. The repository verification script performs the complete burst, 429/header/body validation and Kafka event lookup automatically.

## Postman and SDKs

Import \`artifacts/postman/telco-siddhi-runtime-enforcement.postman_collection.json\` for the runtime examples. SDKs generated from the Developer Portal use the updated OpenAPI definition; consumers must add retry/backoff handling for the documented 429 response.

## SLA and support evidence

For support, provide UTC timestamp, API name/version, application name, partner ID and correlation ID. Do not include access tokens or subscriber payloads. The demo limit is non-contractual; production policy changes require API product owner and network/fraud operations approval.
`;
}

async function upsertDocument(token, api, content) {
  const base = `${APIM_URL}/api/am/publisher/v4/apis/${api.id}/documents`;
  const docs = await request(`${base}?limit=100`, { bearer: token });
  const existing = (docs.list || []).find(item => item.name === DOCUMENT_NAME);
  const metadata = {
    name: DOCUMENT_NAME,
    summary: 'Runtime Siddhi fair-use/assurance limits, 429 contract, Kafka alert evidence and consumer guidance.',
    type: 'HOWTO',
    sourceType: 'MARKDOWN',
    visibility: 'API_LEVEL'
  };
  let doc;
  if (existing) {
    doc = await request(`${base}/${existing.documentId || existing.id}`, {
      method: 'PUT', bearer: token, json: metadata, ok: [200]
    });
  } else {
    doc = await request(base, { method: 'POST', bearer: token, json: metadata, ok: [201] });
  }
  const documentId = doc.documentId || doc.id || existing?.documentId || existing?.id;
  if (!documentId) throw new Error(`Document ID missing for ${api.name}`);
  const form = new FormData();
  form.set('inlineContent', content);
  await request(`${base}/${documentId}/content`, {
    method: 'POST', bearer: token, body: form, ok: [200, 201]
  });
  return documentId;
}

async function main() {
  await waitForApim();
  const state = loadState();
  const auth = await publisherToken(state);
  state.oauth = auth.oauth;
  const response = await request(`${APIM_URL}/api/am/publisher/v4/apis?limit=1000`, { bearer: auth.token });
  const apis = response.list || [];
  state.generatedAt = new Date().toISOString();
  state.documentName = DOCUMENT_NAME;
  state.apis = [];

  for (const [name, cfg] of Object.entries(TARGETS)) {
    const api = apis.find(item => item.name === name && item.version === '1.0.0');
    if (!api) throw new Error(`Required API not found: ${name}:1.0.0`);
    const lifecycle = api.lifeCycleStatus || api.state;
    if (lifecycle && lifecycle !== 'PUBLISHED') {
      throw new Error(`${name}:1.0.0 is not PUBLISHED (state=${lifecycle})`);
    }
    const definition = await ensureLiveDefinition(auth.token, api, cfg);
    const documentId = await upsertDocument(auth.token, api, documentContent(api, cfg));
    state.apis.push({
      name,
      version: api.version,
      apiId: api.id,
      documentId,
      policy: cfg.policy,
      definitionChanged: definition.changed,
      revisionId: definition.revisionId || null
    });
    log(`Upserted ${DOCUMENT_NAME} for ${name}:1.0.0`);
  }

  saveState(state);
  log(`State written to ${STATE_FILE}`);
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
