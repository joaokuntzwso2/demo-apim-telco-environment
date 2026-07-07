const fs = require('fs');
const path = require('path');
const { fetch } = require('undici');

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const APIM_URL = process.env.WSO2_APIM_URL || 'https://wso2-apim:9443';
const USERNAME = process.env.APIM_USERNAME || 'admin';
const PASSWORD = process.env.APIM_PASSWORD || 'admin';
const BUNDLES_FILE = process.env.APIM_API_PRODUCT_BUNDLES_FILE || '/workspace/artifacts/apim-admin/api-product-bundles.json';
const STATE_FILE = process.env.APIM_API_PRODUCT_BUNDLES_STATE_FILE || '/workspace/state/api-product-bundles.json';

const NATIVE_PRODUCT_BUNDLE_IDS = new Set([
  'open-gateway-fraud-defense',
  'digital-customer-bss-experience',
  '5g-network-monetization'
]);

const REST_VERBS = new Set(['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS']);

function log(message) {
  console.log(`[APIM API Products] ${message}`);
}

async function http(url, opts = {}, ok = [200, 201, 202, 204]) {
  const headers = Object.assign({}, opts.headers || {});

  if (opts.basic) {
    headers.Authorization = `Basic ${Buffer.from(opts.basic).toString('base64')}`;
  }

  if (opts.bearer) {
    headers.Authorization = `Bearer ${opts.bearer}`;
  }

  let body = opts.body;

  if (opts.json) {
    headers['Content-Type'] = 'application/json';
    body = JSON.stringify(opts.json);
  }

  const res = await fetch(url, {
    method: opts.method || 'GET',
    headers,
    body
  });

  const text = await res.text();
  let data = text;

  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }

  if (!ok.includes(res.status)) {
    const rendered = typeof data === 'string' ? data : JSON.stringify(data, null, 2);
    throw new Error(`${opts.method || 'GET'} ${url} -> HTTP ${res.status}: ${rendered}`);
  }

  return data;
}

async function getToken() {
  const dcr = await http(`${APIM_URL}/client-registration/v0.17/register`, {
    method: 'POST',
    basic: `${USERNAME}:${PASSWORD}`,
    json: {
      callbackUrl: 'http://localhost:8080/callback',
      clientName: `telco-demo-api-products-${Date.now()}`,
      owner: USERNAME,
      grantType: 'password refresh_token client_credentials',
      saasApp: true
    }
  }, [200, 201]);

  const form = new URLSearchParams();
  form.set('grant_type', 'password');
  form.set('username', USERNAME);
  form.set('password', PASSWORD);
  form.set('scope', [
    'apim:api_view',
    'apim:api_create',
    'apim:api_manage',
    'apim:api_publish',
    'apim:api_update',
    'apim:api_metadata_view'
  ].join(' '));

  const token = await http(`${APIM_URL}/oauth2/token`, {
    method: 'POST',
    basic: `${dcr.clientId}:${dcr.clientSecret}`,
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded'
    },
    body: form.toString()
  }, [200]);

  return token.access_token;
}

async function listApis(token) {
  const result = await http(`${APIM_URL}/api/am/publisher/v4/apis?limit=1000`, {
    bearer: token
  });

  return Array.isArray(result) ? result : (result.list || result.data || []);
}

async function listApiProducts(token) {
  try {
    const result = await http(`${APIM_URL}/api/am/publisher/v4/api-products?limit=1000`, {
      bearer: token
    });

    return Array.isArray(result) ? result : (result.list || result.data || []);
  } catch (e) {
    log(`could not list existing API Products yet: ${e.message}`);
    return [];
  }
}

async function readApi(token, apiId) {
  return http(`${APIM_URL}/api/am/publisher/v4/apis/${apiId}`, {
    bearer: token
  });
}

async function readApiProduct(token, productId) {
  return http(`${APIM_URL}/api/am/publisher/v4/api-products/${productId}`, {
    bearer: token
  });
}

function apiLooksRest(apiSummary, apiDetail) {
  const type = String(apiSummary.type || apiSummary.apiType || apiDetail.type || apiDetail.apiType || '').toUpperCase();

  if (type.includes('SSE') || type.includes('WS') || type.includes('WEBSOCKET') || type.includes('SOAP') || type.includes('GRAPHQL')) {
    return false;
  }

  return true;
}

function normalizeTarget(value) {
  const raw = String(value || '').trim();

  if (!raw) {
    return '/';
  }

  return raw.startsWith('/') ? raw : `/${raw}`;
}

function operationFromBundle(item) {
  const verb = String(item.method || '').toUpperCase();

  if (!REST_VERBS.has(verb)) {
    return null;
  }

  return {
    target: normalizeTarget(item.path),
    verb,
    authType: 'Application & Application User',
    throttlingPolicy: 'Unlimited'
  };
}

function operationsFromApi(apiDetail, fallbackBundleOperations) {
  const rawOps = apiDetail.operations || apiDetail.apiOperations || apiDetail.operationsDTO || [];

  const derived = rawOps
    .map(op => {
      const verb = String(op.verb || op.method || '').toUpperCase();
      const target = normalizeTarget(op.target || op.path || op.uriTemplate || op.urlPattern);

      if (!REST_VERBS.has(verb)) {
        return null;
      }

      return {
        target,
        verb,
        authType: op.authType || op.authTypeEnabled || 'Application & Application User',
        throttlingPolicy: op.throttlingPolicy || op.throttlingPolicyName || 'Unlimited'
      };
    })
    .filter(Boolean);

  if (derived.length) {
    return derived;
  }

  return fallbackBundleOperations
    .map(operationFromBundle)
    .filter(Boolean);
}

function additionalProperties(bundle) {
  return [
    { name: 'ApiProductBundleId', value: bundle.id, display: true },
    { name: 'ApiProductBundleName', value: bundle.name, display: true },
    { name: 'ApiProductBundleStory', value: bundle.businessStory || '', display: true },
    { name: 'ApiProductBundleOutcome', value: bundle.businessOutcome || '', display: true },
    { name: 'ApiProductBundlePlans', value: (bundle.plans || []).join(','), display: true },
    { name: 'MoesifProductKey', value: bundle.moesif?.productKey || '', display: true },
    { name: 'MoesifBillingCatalogReference', value: bundle.moesif?.billingCatalogReference || '', display: true },
    { name: 'MoesifRevenueShareModel', value: bundle.moesif?.revenueShareModel || '', display: true },
    { name: 'MoesifSettlementOwner', value: bundle.moesif?.settlementOwner || '', display: true },
    { name: 'MoesifProductLine', value: bundle.moesif?.productLine || '', display: true }
  ];
}

function buildProductPayload(bundle, productApis) {
  return {
    name: bundle.apim.apiProductName,
    context: bundle.apim.context,
    version: bundle.apim.version || '1.0.0',
    provider: USERNAME,
    description: `${bundle.description}\n\nBusiness outcome: ${bundle.businessOutcome}`,
    visibility: bundle.apim.visibility || 'PUBLIC',
    visibleRoles: [],
    visibleTenants: [],
    subscriptionAvailability: 'CURRENT_TENANT',
    subscriptionAvailableTenants: [],
    apiThrottlingPolicy: 'Unlimited',
    transport: ['http', 'https'],
    securityScheme: ['oauth2'],
    authorizationHeader: 'Authorization',
    gatewayVendor: 'wso2',
    businessInformation: {
      businessOwner: bundle.moesif?.settlementOwner || 'Telco API Business Office',
      businessOwnerEmail: 'api-business-office@example.com',
      technicalOwner: 'Telco API Platform Team',
      technicalOwnerEmail: 'api-platform@example.com'
    },
    additionalProperties: additionalProperties(bundle),
    apis: productApis
  };
}

async function createOrUpdateApiProduct(token, bundle, productApis, existingProducts) {
  const payload = buildProductPayload(bundle, productApis);

  const existing = existingProducts.find(product =>
    product.name === payload.name &&
    String(product.version || '') === String(payload.version)
  );

  if (existing?.id) {
    const current = await readApiProduct(token, existing.id);
    const updated = Object.assign({}, current, payload, { id: existing.id });

    await http(`${APIM_URL}/api/am/publisher/v4/api-products/${existing.id}`, {
      method: 'PUT',
      bearer: token,
      json: updated
    }, [200, 201, 202]);

    log(`updated native API Product: ${payload.name}:${payload.version}`);
    return { id: existing.id, status: 'UPDATED' };
  }

  const created = await http(`${APIM_URL}/api/am/publisher/v4/api-products`, {
    method: 'POST',
    bearer: token,
    json: payload
  }, [200, 201, 202]);

  log(`created native API Product: ${payload.name}:${payload.version}`);
  return { id: created.id, status: 'CREATED' };
}

async function attachMetadataToMemberApis(token, bundle, apiDetails) {
  for (const item of apiDetails) {
    const api = item.apiDetail;
    const props = additionalProperties(bundle);

    const currentProps = Array.isArray(api.additionalProperties) ? api.additionalProperties : [];
    const byName = new Map(currentProps.map(prop => [String(prop.name).toLowerCase(), prop]));

    for (const prop of props) {
      byName.set(prop.name.toLowerCase(), prop);
    }

    api.additionalProperties = Array.from(byName.values());

    try {
      await http(`${APIM_URL}/api/am/publisher/v4/apis/${api.id}`, {
        method: 'PUT',
        bearer: token,
        json: api
      }, [200, 201, 202]);

      log(`attached bundle metadata to member API: ${api.name}`);
    } catch (e) {
      log(`could not update member API metadata for ${api.name}: ${e.message}`);
    }
  }
}

async function main() {
  if (!fs.existsSync(BUNDLES_FILE)) {
    log(`bundle file not found: ${BUNDLES_FILE}`);
    return;
  }

  const bundles = JSON.parse(fs.readFileSync(BUNDLES_FILE, 'utf8'));
  const token = await getToken();
  const apiSummaries = await listApis(token);
  const existingProducts = await listApiProducts(token);

  const state = {
    generatedAt: new Date().toISOString(),
    products: []
  };

  for (const bundle of bundles) {
    const memberState = {
      id: bundle.id,
      name: bundle.name,
      nativeApiProduct: false,
      apim: bundle.apim,
      members: []
    };

    const apiDetails = [];
    const productApis = [];

    for (const apiName of bundle.apis || []) {
      const summary = apiSummaries.find(api => api.name === apiName);

      if (!summary?.id) {
        memberState.members.push({ apiName, status: 'NOT_FOUND' });
        continue;
      }

      const detail = await readApi(token, summary.id);

      const bundleOperations = (bundle.apiBundle || []).filter(item => item.apiName === apiName);

      if (!apiLooksRest(summary, detail)) {
        memberState.members.push({
          apiName,
          apiId: summary.id,
          status: 'SKIPPED_NON_REST'
        });
        continue;
      }

      const operations = bundleOperations.map(operationFromBundle).filter(Boolean);

      if (!operations.length) {
        memberState.members.push({
          apiName,
          apiId: summary.id,
          status: 'SKIPPED_NO_REST_OPERATIONS'
        });
        continue;
      }

      apiDetails.push({ summary, apiDetail: detail });

      productApis.push({
        name: detail.name || summary.name,
        apiId: summary.id,
        version: detail.version || summary.version || '1.0.0',
        operations
      });

      memberState.members.push({
        apiName,
        apiId: summary.id,
        status: 'INCLUDED',
        operations: operations.map(op => `${op.verb} ${op.target}`)
      });
    }

    await attachMetadataToMemberApis(token, bundle, apiDetails);

    if (!NATIVE_PRODUCT_BUNDLE_IDS.has(bundle.id)) {
      memberState.status = 'METADATA_ONLY_BUNDLE';
      state.products.push(memberState);
      log(`metadata-only bundle kept outside native API Products: ${bundle.name}`);
      continue;
    }

    if (productApis.length < 1) {
      memberState.status = 'NO_ELIGIBLE_REST_APIS';
      state.products.push(memberState);
      log(`no eligible REST APIs for native API Product: ${bundle.name}`);
      continue;
    }

    try {
      const result = await createOrUpdateApiProduct(token, bundle, productApis, existingProducts);
      memberState.nativeApiProduct = true;
      memberState.apiProductId = result.id;
      memberState.status = result.status;
    } catch (e) {
      memberState.status = 'FAILED';
      memberState.error = e.message;
      log(`failed to create/update native API Product ${bundle.apim.apiProductName}: ${e.message}`);
    }

    state.products.push(memberState);
  }

  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
  log(`wrote state: ${STATE_FILE}`);
  log('completed.');
}

main().catch(e => {
  console.error(`[APIM API Products] failed: ${e.stack || e.message}`);
  process.exitCode = 1;
});
