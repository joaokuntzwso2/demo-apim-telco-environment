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

  log(
    'Developer Portal documentation is owned by ' +
    'developer-experience-setup.js; skipping duplicate writes ' +
    'after publication.'
  );

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
