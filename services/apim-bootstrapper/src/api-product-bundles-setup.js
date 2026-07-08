const fs = require('fs');
const path = require('path');
const { fetch } = require('undici');

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const APIM_URL =
  process.env.WSO2_APIM_URL || 'https://wso2-apim:9443';

const USERNAME =
  process.env.APIM_USERNAME || 'admin';

const PASSWORD =
  process.env.APIM_PASSWORD || 'admin';

const BUNDLES_FILE =
  process.env.APIM_API_PRODUCT_BUNDLES_FILE
  || '/workspace/artifacts/apim-admin/api-product-bundles.json';

const STATE_FILE =
  process.env.APIM_API_PRODUCT_BUNDLES_STATE_FILE
  || '/workspace/state/api-product-bundles.json';

const COMMERCIAL_API_STATE_FILE =
  '/workspace/state/commercial-api.json';

const NATIVE_PRODUCT_BUNDLE_IDS = new Set([
  'open-gateway-fraud-defense',
  'digital-customer-bss-experience',
  '5g-network-monetization', 'central-policy-governance',
  'secure-mobile-transactions',
  'telco-audit-siem'
]);

const REST_VERBS = new Set([
  'GET',
  'POST',
  'PUT',
  'DELETE',
  'PATCH',
  'HEAD',
  'OPTIONS'
]);

const PRODUCT_DISCOVERY_MARKER =
  'api-product-idempotency-v4';

function log(message) {
  console.log(`[APIM API Products] ${message}`);
}

function sleep(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

class HttpError extends Error {
  constructor(method, url, status, data) {
    const rendered =
      typeof data === 'string'
        ? data
        : JSON.stringify(data, null, 2);

    super(`${method} ${url} -> HTTP ${status}: ${rendered}`);

    this.name = 'HttpError';
    this.method = method;
    this.url = url;
    this.status = status;
    this.data = data;
  }
}

async function http(
  url,
  opts = {},
  ok = [200, 201, 202, 204]
) {
  const method = opts.method || 'GET';
  const headers = Object.assign({}, opts.headers || {});

  if (opts.basic) {
    headers.Authorization =
      `Basic ${Buffer.from(opts.basic).toString('base64')}`;
  }

  if (opts.bearer) {
    headers.Authorization = `Bearer ${opts.bearer}`;
  }

  let body = opts.body;

  if (opts.json !== undefined) {
    headers['Content-Type'] = 'application/json';
    body = JSON.stringify(opts.json);
  }

  const response = await fetch(
    url,
    {
      method,
      headers,
      body
    }
  );

  const text = await response.text();

  let data = text;

  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }

  if (!ok.includes(response.status)) {
    throw new HttpError(
      method,
      url,
      response.status,
      data
    );
  }

  return data;
}

async function requestPasswordToken(
  clientId,
  clientSecret,
  scopes
) {
  const form = new URLSearchParams();

  form.set('grant_type', 'password');
  form.set('username', USERNAME);
  form.set('password', PASSWORD);
  form.set('scope', scopes.join(' '));

  return http(
    `${APIM_URL}/oauth2/token`,
    {
      method: 'POST',
      basic: `${clientId}:${clientSecret}`,
      headers: {
        'Content-Type':
          'application/x-www-form-urlencoded'
      },
      body: form.toString()
    },
    [200]
  );
}

async function getToken() {
  const dcr = await http(
    `${APIM_URL}/client-registration/v0.17/register`,
    {
      method: 'POST',
      basic: `${USERNAME}:${PASSWORD}`,
      json: {
        callbackUrl:
          'http://localhost:8080/callback',
        clientName:
          `telco-demo-api-products-${Date.now()}`,
        owner: USERNAME,
        grantType:
          'password refresh_token client_credentials',
        saasApp: true
      }
    },
    [200, 201]
  );

  const baseScopes = [
    'apim:api_view',
    'apim:api_create',
    'apim:api_manage',
    'apim:api_publish',
    'apim:api_update',
    'apim:api_metadata_view'
  ];

  const productScopes = [
    'apim:api_product_metadata_view',
    'apim:api_product_create',
    'apim:api_product_update'
  ];

  try {
    const token = await requestPasswordToken(
      dcr.clientId,
      dcr.clientSecret,
      [...baseScopes, ...productScopes]
    );

    log(
      'Publisher token includes API Product '
      + 'discovery/create/update scopes.'
    );

    return token.access_token;
  } catch (error) {
    /*
     * Retain compatibility with installations where broad Publisher
     * scopes imply Product permissions.
     */
    log(
      'Granular API Product scope request failed; '
      + `retrying with broad Publisher scopes: ${error.message}`
    );

    const token = await requestPasswordToken(
      dcr.clientId,
      dcr.clientSecret,
      baseScopes
    );

    return token.access_token;
  }
}

function extractList(result) {
  if (Array.isArray(result)) {
    return result;
  }

  if (Array.isArray(result?.list)) {
    return result.list;
  }

  if (Array.isArray(result?.data)) {
    return result.data;
  }

  return [];
}

async function listCollection(
  token,
  resource,
  query = null
) {
  const limit = 100;
  const collected = [];

  for (
    let offset = 0;
    offset < 5000;
    offset += limit
  ) {
    const parameters = new URLSearchParams();

    parameters.set('limit', String(limit));
    parameters.set('offset', String(offset));

    if (query) {
      parameters.set('query', query);
    }

    const result = await http(
      `${APIM_URL}/api/am/publisher/v4/${resource}`
      + `?${parameters.toString()}`,
      {
        bearer: token
      },
      [200]
    );

    const page = extractList(result);

    collected.push(...page);

    const count = Number(result?.count);

    if (page.length < limit) {
      break;
    }

    if (
      Number.isFinite(count)
      && count >= 0
      && collected.length >= count
    ) {
      break;
    }
  }

  return collected;
}

async function listApis(token, query = null) {
  return listCollection(
    token,
    'apis',
    query
  );
}

// api-product-unified-discovery-v5
async function listApiProducts(token, query = null) {
  let dedicatedProducts = [];

  try {
    dedicatedProducts = await listCollection(
      token,
      'api-products',
      query
    );
  } catch (error) {
    log(
      'Dedicated API Product collection lookup failed: '
      + `${error.message || error}`
    );
  }

  if (dedicatedProducts.length) {
    return dedicatedProducts;
  }

  /*
   * APIM also represents API Products in the unified Publisher API
   * collection. This fallback is required when the dedicated Product
   * collection temporarily returns an empty result while persisted
   * Products still exist.
   */
  const unifiedQueries = [
    'type:APIProduct',
    'type:API_PRODUCT'
  ];

  for (const unifiedQuery of unifiedQueries) {
    try {
      const unifiedProducts = await listCollection(
        token,
        'apis',
        unifiedQuery
      );

      if (unifiedProducts.length) {
        log(
          `Dedicated API Product collection returned 0 items; `
          + `recovered ${unifiedProducts.length} Product candidate(s) `
          + `through /apis?query=${unifiedQuery}.`
        );

        return unifiedProducts;
      }
    } catch (error) {
      log(
        `Unified Product discovery with "${unifiedQuery}" failed: `
        + `${error.message || error}`
      );
    }
  }

  /*
   * Last fallback: use the complete unified list and retain entries whose
   * API type or name identifies them as Products.
   */
  try {
    const allPublisherAssets = await listCollection(
      token,
      'apis',
      null
    );

    const productCandidates = allPublisherAssets.filter(candidate => {
      const type = String(
        candidate?.type
        || candidate?.apiType
        || candidate?.assetType
        || ''
      ).toUpperCase();

      const name = String(candidate?.name || '');

      return (
        type.includes('PRODUCT')
        || name.endsWith('Product')
      );
    });

    if (productCandidates.length) {
      log(
        `Recovered ${productCandidates.length} API Product candidate(s) `
        + 'through complete unified Publisher discovery.'
      );
    }

    return productCandidates;
  } catch (error) {
    log(
      'Complete unified Publisher discovery failed: '
      + `${error.message || error}`
    );

    return [];
  }
}

async function readApi(token, apiId) {
  return http(
    `${APIM_URL}/api/am/publisher/v4/apis/`
    + encodeURIComponent(apiId),
    {
      bearer: token
    },
    [200]
  );
}

async function readApiIfPresent(token, apiId) {
  if (!apiId) {
    return null;
  }

  try {
    return await readApi(token, apiId);
  } catch (error) {
    if (error.status === 404) {
      return null;
    }

    throw error;
  }
}

async function readApiProduct(token, productId) {
  return http(
    `${APIM_URL}/api/am/publisher/v4/api-products/`
    + encodeURIComponent(productId),
    {
      bearer: token
    },
    [200]
  );
}

// api-product-state-uuid-validation-v7
function isApiProductUuid(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(String(value || '').trim());
}

async function readApiProductIfPresent(
  token,
  productId
) {
  const normalizedId =
    String(productId || '').trim();

  if (!normalizedId) {
    return null;
  }

  /*
   * State entries also contain a bundle id such as
   * "open-gateway-fraud-defense". That value is not the APIM
   * API Product UUID and must never be passed to /api-products/{id}.
   */
  if (!isApiProductUuid(normalizedId)) {
    log(
      `ignoring non-UUID API Product identifier: `
      + normalizedId
    );

    return null;
  }

  try {
    return await readApiProduct(
      token,
      normalizedId
    );
  } catch (error) {
    if (error.status === 404) {
      return null;
    }

    /*
     * Some APIM builds respond with 500 rather than 404 when an old
     * Product UUID no longer exists. Treat that specific lookup result
     * as stale state and continue with Publisher discovery.
     */
    if (
      error.status === 500
      && String(error.message || '').includes(
        'Error while retrieving API Product from Id'
      )
    ) {
      log(
        `ignoring stale API Product UUID from state: `
        + normalizedId
      );

      return null;
    }

    throw error;
  }
}

function readJsonIfPresent(filename) {
  try {
    if (!fs.existsSync(filename)) {
      return null;
    }

    return JSON.parse(
      fs.readFileSync(filename, 'utf8')
    );
  } catch (error) {
    log(
      `Ignoring unreadable state ${filename}: `
      + error.message
    );

    return null;
  }
}

function apiMatches(candidate, apiName) {
  return Boolean(
    candidate
    && candidate.name === apiName
  );
}

function productMatches(
  candidate,
  productName,
  productVersion
) {
  if (
    !candidate
    || candidate.name !== productName
  ) {
    return false;
  }

  const candidateVersion = String(
    candidate.version || ''
  );

  /*
   * Unified API Product summaries can omit the version. The complete
   * Product is read immediately afterward through /api-products/{id}.
   */
  return (
    !candidateVersion
    || candidateVersion === String(productVersion)
  );
}

function selectApi(candidates, apiName) {
  const matches = candidates.filter(
    candidate => apiMatches(
      candidate,
      apiName
    )
  );

  if (!matches.length) {
    return null;
  }

  const versionOne = matches.find(
    candidate =>
      String(candidate.version || '') === '1.0.0'
  );

  return versionOne || matches[0];
}

function selectProduct(
  candidates,
  productName,
  productVersion
) {
  return candidates.find(
    candidate => productMatches(
      candidate,
      productName,
      productVersion
    )
  ) || null;
}

async function resolveCommercialApiFromState(
  token,
  apiName
) {
  if (
    apiName
    !== 'SecureMobileTransactionsCommercialAPI'
  ) {
    return null;
  }

  const state = readJsonIfPresent(
    COMMERCIAL_API_STATE_FILE
  );

  const apiId =
    state?.apiId
    || state?.id
    || state?.api?.id;

  const api = await readApiIfPresent(
    token,
    apiId
  );

  if (apiMatches(api, apiName)) {
    log(
      `resolved ${apiName} from commercial `
      + `bootstrap state: ${api.id}`
    );

    return api;
  }

  return null;
}

async function resolveApi(
  token,
  apiName,
  initialApis
) {
  const fromInitial = selectApi(
    initialApis,
    apiName
  );

  if (fromInitial?.id) {
    return readApi(
      token,
      fromInitial.id
    );
  }

  const fromState =
    await resolveCommercialApiFromState(
      token,
      apiName
    );

  if (fromState) {
    return fromState;
  }

  const attempts =
    apiName ===
    'SecureMobileTransactionsCommercialAPI'
      ? 12
      : 2;

  for (
    let attempt = 1;
    attempt <= attempts;
    attempt += 1
  ) {
    for (const query of [
      apiName,
      `name:${apiName}`
    ]) {
      let candidates = [];

      try {
        candidates = await listApis(
          token,
          query
        );
      } catch (error) {
        log(
          `API query "${query}" failed: `
          + error.message
        );

        continue;
      }

      const found = selectApi(
        candidates,
        apiName
      );

      if (found?.id) {
        const api = await readApi(
          token,
          found.id
        );

        log(
          `resolved ${apiName} through Publisher `
          + `discovery on attempt ${attempt}: ${api.id}`
        );

        return api;
      }
    }

    if (
      apiName ===
      'SecureMobileTransactionsCommercialAPI'
    ) {
      const retriedState =
        await resolveCommercialApiFromState(
          token,
          apiName
        );

      if (retriedState) {
        return retriedState;
      }
    }

    if (attempt < attempts) {
      await sleep(
        Math.min(500 * attempt, 3000)
      );
    }
  }

  /*
   * Final unfiltered scan protects against Publisher
   * search-index timing.
   */
  try {
    const allApis = await listApis(token);
    const found = selectApi(
      allApis,
      apiName
    );

    if (found?.id) {
      return readApi(
        token,
        found.id
      );
    }
  } catch (error) {
    log(
      `final API scan failed for ${apiName}: `
      + error.message
    );
  }

  return null;
}

// api-product-exact-name-recovery-v6
function escapePublisherSearchValue(value) {
  return String(value || '')
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"');
}

// api-product-candidate-recovery-v9
function apiProductCandidateId(candidate) {
  return (
    candidate?.id
    || candidate?.apiId
    || candidate?.apiProductId
    || candidate?.apiUUID
    || candidate?.uuid
    || candidate?.api?.id
    || candidate?.api?.apiUUID
    || null
  );
}

function apiProductCandidateName(candidate) {
  return String(
    candidate?.name
    || candidate?.apiName
    || candidate?.api?.name
    || ''
  );
}

function apiProductCandidateVersion(candidate) {
  return String(
    candidate?.version
    || candidate?.apiVersion
    || candidate?.api?.version
    || ''
  );
}

function isRequestedApiProductCandidate(
  candidate,
  productName,
  productVersion
) {
  if (
    apiProductCandidateName(candidate)
    !== productName
  ) {
    return false;
  }

  const candidateVersion =
    apiProductCandidateVersion(candidate);

  return (
    !candidateVersion
    || candidateVersion === String(productVersion)
  );
}

async function validateApiProductCandidate(
  token,
  candidate,
  productName,
  productVersion,
  source
) {
  if (
    !isRequestedApiProductCandidate(
      candidate,
      productName,
      productVersion
    )
  ) {
    return null;
  }

  const candidateId =
    apiProductCandidateId(candidate);

  if (!candidateId) {
    log(
      `matched ${productName}:${productVersion} through `
      + `${source}, but the result contained no Product UUID. `
      + `Available fields: ${Object.keys(candidate || {}).join(',')}`
    );

    return null;
  }

  const product =
    await readApiProductIfPresent(
      token,
      candidateId
    );

  if (
    productMatches(
      product,
      productName,
      productVersion
    )
  ) {
    log(
      `resolved exact API Product through ${source}: `
      + `${productName}:${productVersion} `
      + `(${product.id})`
    );

    return product;
  }

  return null;
}

async function findExactApiProduct(
  token,
  productName,
  productVersion
) {
  const escapedName =
    escapePublisherSearchValue(productName);

  const escapedVersion =
    escapePublisherSearchValue(productVersion);

  /*
   * Use exact name searches before broader searches. Each result is
   * validated by retrieving /api-products/{uuid}.
   */
  const searches = [
    {
      resource: 'api-products',
      query:
        `name:"${escapedName}" `
        + `version:"${escapedVersion}"`
    },
    {
      resource: 'api-products',
      query: productName
    },
    {
      resource: 'apis',
      query:
        `name:"${escapedName}" `
        + `version:"${escapedVersion}" `
        + 'type:APIProduct'
    },
    {
      resource: 'apis',
      query:
        `name:"${escapedName}" `
        + `version:"${escapedVersion}"`
    },
    {
      resource: 'apis',
      query: productName
    },
    {
      resource: 'search',
      query:
        `name:"${escapedName}" `
        + `version:"${escapedVersion}"`
    },
    {
      resource: 'search',
      query: productName
    }
  ];

  for (const search of searches) {
    let candidates = [];

    try {
      candidates = await listCollection(
        token,
        search.resource,
        search.query
      );
    } catch (error) {
      log(
        `Product lookup failed through /${search.resource} `
        + `with query "${search.query}": `
        + `${error.message || error}`
      );

      continue;
    }

    for (const candidate of candidates) {
      const product =
        await validateApiProductCandidate(
          token,
          candidate,
          productName,
          productVersion,
          `/${search.resource}`
        );

      if (product) {
        return product;
      }
    }
  }

  /*
   * Final complete scans protect against delayed or inconsistent
   * Publisher search indexes.
   */
  for (const resource of [
    'api-products',
    'apis',
    'search'
  ]) {
    let candidates = [];

    try {
      candidates = await listCollection(
        token,
        resource,
        null
      );
    } catch (error) {
      log(
        `Complete /${resource} scan failed: `
        + `${error.message || error}`
      );

      continue;
    }

    for (const candidate of candidates) {
      const product =
        await validateApiProductCandidate(
          token,
          candidate,
          productName,
          productVersion,
          `complete /${resource} scan`
        );

      if (product) {
        return product;
      }
    }
  }

  return null;
}

async function resolveApiProduct(
  token,
  productName,
  productVersion,
  initialProducts,
  previousState
) {
  const previous = (
    previousState?.products || []
  ).find(item => (
    item?.apim?.apiProductName === productName
    && String(
      item?.apim?.version || '1.0.0'
    ) === String(productVersion)
  ));

  /*
   * previous.id is the bundle identifier, not the APIM Product UUID.
   */
  const previousProductId =
    previous?.apiProductId
    || previous?.apiProduct?.id
    || null;

  const fromState =
    await readApiProductIfPresent(
      token,
      previousProductId
    );

  if (
    productMatches(
      fromState,
      productName,
      productVersion
    )
  ) {
    log(
      `resolved existing API Product from state: `
      + `${productName}:${productVersion} `
      + `(${fromState.id})`
    );

    return fromState;
  }

  /*
   * Initial lists may contain id, apiId, apiProductId, apiUUID or uuid.
   */
  for (const candidate of initialProducts || []) {
    const product =
      await validateApiProductCandidate(
        token,
        candidate,
        productName,
        productVersion,
        'initial Product list'
      );

    if (product) {
      return product;
    }
  }

  return findExactApiProduct(
    token,
    productName,
    productVersion
  );
}

function apiLooksRest(apiDetail) {
  const type = String(
    apiDetail?.type
    || apiDetail?.apiType
    || ''
  ).toUpperCase();

  if (
    type.includes('SSE')
    || type.includes('WS')
    || type.includes('WEBSOCKET')
    || type.includes('SOAP')
    || type.includes('GRAPHQL')
  ) {
    return false;
  }

  return true;
}

function normalizeTarget(value) {
  const raw = String(value || '').trim();

  if (!raw) {
    return '/';
  }

  const prefixed =
    raw.startsWith('/')
      ? raw
      : `/${raw}`;

  return prefixed
    .replace(/\/+/g, '/')
    .replace(/\/+$/, '') || '/';
}

function canonicalTarget(value) {
  return normalizeTarget(value)
    .replace(/\{[^/{}]+\}/g, '{}');
}

function operationFromBundle(item) {
  const verb = String(
    item?.method || ''
  ).toUpperCase();

  if (!REST_VERBS.has(verb)) {
    return null;
  }

  return {
    target: normalizeTarget(item.path),
    verb,
    authType:
      'Application & Application User',
    throttlingPolicy: 'Unlimited'
  };
}

function actualOperationsFromApi(apiDetail) {
  const rawOperations =
    apiDetail?.operations
    || apiDetail?.apiOperations
    || apiDetail?.operationsDTO
    || [];

  return rawOperations
    .map(operation => {
      const verb = String(
        operation?.verb
        || operation?.method
        || ''
      ).toUpperCase();

      if (!REST_VERBS.has(verb)) {
        return null;
      }

      return {
        target: normalizeTarget(
          operation?.target
          || operation?.path
          || operation?.uriTemplate
          || operation?.urlPattern
        ),
        verb,
        authType:
          operation?.authType
          || operation?.authTypeEnabled
          || 'Application & Application User',
        throttlingPolicy:
          operation?.throttlingPolicy
          || operation?.throttlingPolicyName
          || 'Unlimited'
      };
    })
    .filter(Boolean);
}

function resolveConfiguredOperations(
  apiDetail,
  configuredOperations
) {
  const requested = configuredOperations
    .map(operationFromBundle)
    .filter(Boolean);

  const actual =
    actualOperationsFromApi(apiDetail);

  /*
   * Some APIM representations do not return operation
   * details. The bundle remains the source of truth.
   */
  if (!actual.length) {
    return requested;
  }

  const resolved = [];

  for (const request of requested) {
    const match = actual.find(
      candidate => (
        candidate.verb === request.verb
        && canonicalTarget(candidate.target)
          === canonicalTarget(request.target)
      )
    );

    if (!match) {
      log(
        `configured operation was not found in `
        + `${apiDetail.name}: `
        + `${request.verb} ${request.target}`
      );

      continue;
    }

    resolved.push(match);
  }

  return resolved;
}

function isHealthOperation(operation) {
  const target =
    canonicalTarget(operation.target);

  return (
    operation.verb === 'GET'
    && (
      target === '/health'
      || target === '/healthz'
      || target.endsWith('/health')
      || target.endsWith('/healthz')
    )
  );
}

function additionalProperties(bundle) {
  return [
    {
      name: 'ApiProductBundleId',
      value: bundle.id,
      display: true
    },
    {
      name: 'ApiProductBundleName',
      value: bundle.name,
      display: true
    },
    {
      name: 'ApiProductBundleStory',
      value: bundle.businessStory || '',
      display: true
    },
    {
      name: 'ApiProductBundleOutcome',
      value: bundle.businessOutcome || '',
      display: true
    },
    {
      name: 'ApiProductBundlePlans',
      value: (
        bundle.plans || []
      ).join(','),
      display: true
    },
    {
      name: 'MoesifProductKey',
      value:
        bundle.moesif?.productKey || '',
      display: true
    },
    {
      name: 'MoesifBillingCatalogReference',
      value:
        bundle.moesif
          ?.billingCatalogReference || '',
      display: true
    },
    {
      name: 'MoesifRevenueShareModel',
      value:
        bundle.moesif
          ?.revenueShareModel || '',
      display: true
    },
    {
      name: 'MoesifSettlementOwner',
      value:
        bundle.moesif
          ?.settlementOwner || '',
      display: true
    },
    {
      name: 'MoesifProductLine',
      value:
        bundle.moesif
          ?.productLine || '',
      display: true
    },
    {
      name: 'BootstrapReconciliationVersion',
      value: PRODUCT_DISCOVERY_MARKER,
      display: false
    }
  ];
}

function buildProductPayload(
  bundle,
  productApis
) {
  return {
    name: bundle.apim.apiProductName,
    context: bundle.apim.context,
    version:
      bundle.apim.version || '1.0.0',
    provider: USERNAME,
    description:
      `${bundle.description}\n\n`
      + `Business outcome: `
      + `${bundle.businessOutcome}`,
    visibility:
      bundle.apim.visibility || 'PUBLIC',
    visibleRoles: [],
    visibleTenants: [],
    subscriptionAvailability:
      'CURRENT_TENANT',
    subscriptionAvailableTenants: [],
    apiThrottlingPolicy:
      bundle.apim.apiThrottlingPolicy
      || 'Unlimited',
    transport: ['http', 'https'],
    securityScheme: ['oauth2'],
    authorizationHeader: 'Authorization',
    gatewayVendor: 'wso2',
    businessInformation: {
      businessOwner:
        bundle.businessOwner
        || bundle.moesif?.settlementOwner
        || 'Telco API Business Office',
      businessOwnerEmail:
        'api-business-office@example.com',
      technicalOwner:
        bundle.technicalOwner
        || 'Telco API Platform Team',
      technicalOwnerEmail:
        'api-platform@example.com'
    },
    additionalProperties:
      additionalProperties(bundle),
    apis: productApis
  };
}

async function updateApiProduct(
  token,
  existing,
  payload
) {
  const current =
    existing.apis
      ? existing
      : await readApiProduct(
          token,
          existing.id
        );

  const updated = Object.assign(
    {},
    current,
    payload,
    {
      id: current.id
    }
  );

  const result = await http(
    `${APIM_URL}/api/am/publisher/v4/api-products/`
    + encodeURIComponent(current.id),
    {
      method: 'PUT',
      bearer: token,
      json: updated
    },
    [200, 201, 202]
  );

  log(
    `updated native API Product: `
    + `${payload.name}:${payload.version} `
    + `(${current.id})`
  );

  return {
    id: current.id,
    status: 'UPDATED',
    product: result || updated
  };
}

async function createOrUpdateApiProduct(
  token,
  bundle,
  productApis,
  initialProducts,
  previousState
) {
  const payload =
    buildProductPayload(
      bundle,
      productApis
    );

  let existing =
    await resolveApiProduct(
      token,
      payload.name,
      payload.version,
      initialProducts,
      previousState
    );

  if (existing?.id) {
    return updateApiProduct(
      token,
      existing,
      payload
    );
  }

  try {
    const created = await http(
      `${APIM_URL}/api/am/publisher/v4/api-products`,
      {
        method: 'POST',
        bearer: token,
        json: payload
      },
      [200, 201, 202]
    );

    log(
      `created native API Product: `
      + `${payload.name}:${payload.version} `
      + `(${created.id})`
    );

    return {
      id: created.id,
      status: 'CREATED',
      product: created
    };
  } catch (error) {
    if (error.status !== 409) {
      throw error;
    }

    log(
      `create returned HTTP 409 for `
      + `${payload.name}:${payload.version}; `
      + 'resolving and updating the persisted Product.'
    );

    for (
      let attempt = 1;
      attempt <= 4;
      attempt += 1
    ) {
      existing =
        await resolveApiProduct(
          token,
          payload.name,
          payload.version,
          initialProducts,
          previousState
        );

      if (existing?.id) {
        log(
          `recovered existing API Product `
          + `${existing.id} after 409 `
          + `(attempt ${attempt}).`
        );

        return updateApiProduct(
          token,
          existing,
          payload
        );
      }

      await sleep(
        Math.min(500 * attempt, 3000)
      );
    }

    throw new Error(
      `APIM reported that ${payload.name}:`
      + `${payload.version} already exists, `
      + 'but Product discovery did not return it.'
    );
  }
}

async function attachMetadataToMemberApis(
  token,
  bundle,
  apiDetails
) {
  for (const item of apiDetails) {
    const api = item.apiDetail;
    const desired =
      additionalProperties(bundle);

    const currentProps =
      Array.isArray(api.additionalProperties)
        ? api.additionalProperties
        : [];

    const byName = new Map(
      currentProps.map(property => [
        String(property.name).toLowerCase(),
        property
      ])
    );

    for (const property of desired) {
      byName.set(
        property.name.toLowerCase(),
        property
      );
    }

    const updated = Object.assign(
      {},
      api,
      {
        additionalProperties:
          Array.from(byName.values())
      }
    );

    try {
      await http(
        `${APIM_URL}/api/am/publisher/v4/apis/`
        + encodeURIComponent(api.id),
        {
          method: 'PUT',
          bearer: token,
          json: updated
        },
        [200, 201, 202]
      );

      log(
        `attached bundle metadata to member API: `
        + api.name
      );
    } catch (error) {
      log(
        `could not update member API metadata for `
        + `${api.name}: ${error.message}`
      );
    }
  }
}

async function main() {
  if (!fs.existsSync(BUNDLES_FILE)) {
    throw new Error(
      `bundle file not found: ${BUNDLES_FILE}`
    );
  }

  const bundles = JSON.parse(
    fs.readFileSync(
      BUNDLES_FILE,
      'utf8'
    )
  );

  const previousState =
    readJsonIfPresent(STATE_FILE);

  const token = await getToken();

  const initialApis =
    await listApis(token);

  const initialProducts =
    await listApiProducts(token);

  log(
    `discovered ${initialApis.length} APIs and `
    + `${initialProducts.length} API Products `
    + 'before reconciliation.'
  );

  const state = {
    generatedAt: new Date().toISOString(),
    reconciliationVersion:
      PRODUCT_DISCOVERY_MARKER,
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

    /*
     * WSO2 API Products cannot contain duplicate
     * target+verb resources, even when they originate
     * from different APIs.
     */
    const usedProductResources = new Set();

    for (const apiName of bundle.apis || []) {
      const detail =
        await resolveApi(
          token,
          apiName,
          initialApis
        );

      if (!detail?.id) {
        memberState.members.push({
          apiName,
          status: 'NOT_FOUND'
        });

        continue;
      }

      if (!apiLooksRest(detail)) {
        memberState.members.push({
          apiName,
          apiId: detail.id,
          status: 'SKIPPED_NON_REST'
        });

        continue;
      }

      const configuredOperations = (
        bundle.apiBundle || []
      ).filter(
        item => item.apiName === apiName
      );

      const resolvedOperations =
        resolveConfiguredOperations(
          detail,
          configuredOperations
        );

      const includedOperations = [];
      const skippedOperations = [];

      for (const operation of resolvedOperations) {
        if (isHealthOperation(operation)) {
          skippedOperations.push({
            operation:
              `${operation.verb} ${operation.target}`,
            reason:
              'OPERATIONAL_HEALTH_RESOURCE'
          });

          log(
            `excluded operational health resource from `
            + `${bundle.apim.apiProductName}: `
            + `${operation.verb} ${operation.target} `
            + `from ${apiName}`
          );

          continue;
        }

        const resourceKey =
          `${operation.verb} `
          + `${canonicalTarget(operation.target)}`;

        if (usedProductResources.has(resourceKey)) {
          skippedOperations.push({
            operation:
              `${operation.verb} ${operation.target}`,
            reason:
              'DUPLICATE_PRODUCT_RESOURCE'
          });

          log(
            `excluded duplicate Product resource from `
            + `${bundle.apim.apiProductName}: `
            + `${resourceKey} from ${apiName}`
          );

          continue;
        }

        usedProductResources.add(resourceKey);
        includedOperations.push(operation);
      }

      if (!includedOperations.length) {
        memberState.members.push({
          apiName,
          apiId: detail.id,
          status:
            'SKIPPED_NO_UNIQUE_REST_OPERATIONS',
          skippedOperations
        });

        continue;
      }

      apiDetails.push({
        apiDetail: detail
      });

      productApis.push({
        name: detail.name || apiName,
        apiId: detail.id,
        version:
          detail.version || '1.0.0',
        operations: includedOperations
      });

      memberState.members.push({
        apiName,
        apiId: detail.id,
        status: 'INCLUDED',
        operations:
          includedOperations.map(
            operation =>
              `${operation.verb} `
              + operation.target
          ),
        skippedOperations
      });
    }

    await attachMetadataToMemberApis(
      token,
      bundle,
      apiDetails
    );

    if (
      !NATIVE_PRODUCT_BUNDLE_IDS.has(
        bundle.id
      )
    ) {
      memberState.status =
        'METADATA_ONLY_BUNDLE';

      state.products.push(memberState);

      log(
        `metadata-only bundle kept outside native `
        + `API Products: ${bundle.name}`
      );

      continue;
    }

    if (!productApis.length) {
      memberState.status =
        'NO_ELIGIBLE_REST_APIS';

      state.products.push(memberState);

      log(
        `no eligible REST APIs for native `
        + `API Product: ${bundle.name}`
      );

      continue;
    }

    try {
      const result =
        await createOrUpdateApiProduct(
          token,
          bundle,
          productApis,
          initialProducts,
          previousState
        );

      memberState.nativeApiProduct = true;
      memberState.apiProductId = result.id;
      memberState.status = result.status;

      /*
       * Make Products created during this execution
       * immediately discoverable to later bundles.
       */
      initialProducts.push({
        id: result.id,
        name:
          bundle.apim.apiProductName,
        version:
          bundle.apim.version || '1.0.0'
      });
    } catch (error) {
      memberState.status = 'FAILED';
      memberState.error = error.message;

      log(
        `failed to create/update native API Product `
        + `${bundle.apim.apiProductName}: `
        + error.message
      );
    }

    state.products.push(memberState);
  }

  fs.mkdirSync(
    path.dirname(STATE_FILE),
    {
      recursive: true
    }
  );

  fs.writeFileSync(
    STATE_FILE,
    JSON.stringify(state, null, 2)
  );

  log(`wrote state: ${STATE_FILE}`);

  const missingNativeProducts =
    Array.from(
      NATIVE_PRODUCT_BUNDLE_IDS
    )
      .map(bundleId => {
        const product =
          state.products.find(
            item => item.id === bundleId
          );

        if (
          product?.nativeApiProduct
          && product?.apiProductId
        ) {
          return null;
        }

        return {
          bundleId,
          status:
            product?.status
            || 'MISSING_FROM_STATE',
          error:
            product?.error || null,
          members:
            product?.members || []
        };
      })
      .filter(Boolean);

  if (missingNativeProducts.length) {
    throw new Error(
      'Expected native API Products were not '
      + 'reconciled: '
      + JSON.stringify(
          missingNativeProducts,
          null,
          2
        )
    );
  }

  log(
    'completed: all expected native API Products '
    + 'were reconciled.'
  );
}

main().catch(error => {
  console.error(
    `[APIM API Products] failed: `
    + `${error.stack || error.message}`
  );

  process.exitCode = 1;
});
