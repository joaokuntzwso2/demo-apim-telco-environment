'use strict';

const fs = require('fs');
const path = require('path');
const { fetch, FormData, Agent } = require('undici');

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const dispatcher = new Agent({ connect: { rejectUnauthorized: false } });
const APIM_URL = process.env.WSO2_APIM_URL || 'https://wso2-apim:9443';
const USERNAME = process.env.APIM_USERNAME || 'admin';
const PASSWORD = process.env.APIM_PASSWORD || 'admin';
const OPA_URL =
  process.env.CENTRAL_POLICY_OPA_URL ||
  'http://opa:8181/v1/data/telco/central_policy/decision';
const CATALOG_FILE =
  process.env.CENTRAL_POLICY_CATALOG_FILE ||
  '/workspace/artifacts/apim-admin/central-policy-catalog.json';
const STATE_FILE =
  process.env.CENTRAL_POLICY_STATE_FILE ||
  '/workspace/state/central-policy.json';
const FAIL_ON_DENY =
  String(process.env.CENTRAL_POLICY_FAIL_ON_DENY || 'true').toLowerCase() === 'true';
const PRODUCT_NAME = 'CentralPolicyGovernanceProduct';

function log(message) {
  console.log(`[Central Policy] ${message}`);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function request(
  url,
  {
    method = 'GET',
    bearer,
    basic,
    json,
    body,
    headers = {},
    ok = [200, 201, 202, 204],
  } = {},
) {
  const requestHeaders = { ...headers };
  if (bearer) requestHeaders.Authorization = `Bearer ${bearer}`;
  if (basic) {
    requestHeaders.Authorization =
      `Basic ${Buffer.from(basic).toString('base64')}`;
  }
  if (json !== undefined) {
    requestHeaders['Content-Type'] = 'application/json';
    body = JSON.stringify(json);
  }
  const response = await fetch(url, {
    method,
    headers: requestHeaders,
    body,
    dispatcher,
  });
  const text = await response.text();
  let data = text;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }
  if (!ok.includes(response.status)) {
    const rendered =
      typeof data === 'string' ? data : JSON.stringify(data, null, 2);
    throw new Error(`${method} ${url} -> HTTP ${response.status}: ${rendered}`);
  }
  return data;
}

async function waitFor(url, label, attempts = 90) {
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await fetch(url, { dispatcher });
      if (response.ok) {
        log(`${label} is reachable.`);
        return;
      }
    } catch {
      // Service may still be starting.
    }
    log(`Waiting for ${label} (${attempt}/${attempts})`);
    await sleep(2000);
  }
  throw new Error(`${label} did not become reachable at ${url}`);
}

async function getPublisherToken() {
  const dcr = await request(
    `${APIM_URL}/client-registration/v0.17/register`,
    {
      method: 'POST',
      basic: `${USERNAME}:${PASSWORD}`,
      json: {
        callbackUrl: 'http://localhost:8080/callback',
        clientName: `telco-central-policy-${Date.now()}`,
        owner: USERNAME,
        grantType: 'password refresh_token client_credentials',
        saasApp: true,
      },
      ok: [200, 201],
    },
  );
  const form = new URLSearchParams();
  form.set('grant_type', 'password');
  form.set('username', USERNAME);
  form.set('password', PASSWORD);
  form.set(
    'scope',
    [
      'apim:api_view',
      'apim:api_create',
      'apim:api_update',
      'apim:api_manage',
      'apim:api_publish',
      'apim:api_metadata_view',
      'service_catalog:service_view',
      'service_catalog:service_write',
    ].join(' '),
  );
  const token = await request(`${APIM_URL}/oauth2/token`, {
    method: 'POST',
    basic: `${dcr.clientId}:${dcr.clientSecret}`,
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: form.toString(),
    ok: [200],
  });
  if (!token.access_token) throw new Error('Publisher token was not returned.');
  return token.access_token;
}

async function listApis(token) {
  const response = await request(
    `${APIM_URL}/api/am/publisher/v4/apis?limit=1000`,
    { bearer: token },
  );
  return Array.isArray(response) ? response : response.list || response.data || [];
}

async function listProducts(token) {
  const response = await request(
    `${APIM_URL}/api/am/publisher/v4/api-products?limit=1000`,
    { bearer: token },
  );
  return Array.isArray(response) ? response : response.list || response.data || [];
}

function upsertProperties(entity, properties) {
  const byName = new Map();
  for (const property of Array.isArray(entity.additionalProperties)
    ? entity.additionalProperties
    : []) {
    if (property && property.name) {
      byName.set(String(property.name).toLowerCase(), {
        name: String(property.name),
        value: String(property.value ?? ''),
        display: property.display !== false,
      });
    }
  }
  for (const [name, value] of Object.entries(properties)) {
    byName.set(name.toLowerCase(), {
      name,
      value: String(value ?? ''),
      display: true,
    });
  }
  entity.additionalProperties = Array.from(byName.values());
}

function plansFor(apiName, descriptor) {
  if (apiName === 'OpenGatewaySimSwapRiskAPI') {
    return [
      'TelcoFreeTrial',
      'TelcoOpenGatewayTrustStarter',
      'TelcoOpenGatewayTrustPremium',
      'Unlimited',
    ];
  }
  if (apiName === 'SecureMobileTransactionsCommercialAPI') {
    return [
      'SecureMobileSandbox',
      'SecureMobileBusiness',
      'SecureMobileEnterprise',
      'Unlimited',
    ];
  }
  return ['TelcoPartnerStandard', 'TelcoPartnerPremium', 'Unlimited'];
}

function descriptorProperties(descriptor, decision) {
  return {
    CentralPolicyVersion: decision.policyVersion,
    GroupPolicyVersion: descriptor.groupPolicyVersion,
    CountryOverlay: descriptor.country,
    RiskClassification: descriptor.riskClassification,
    HighRiskAPI: String(Boolean(decision.highRisk)),
    DataResidency: descriptor.dataResidency,
    LocalOwner: descriptor.localOwner.name,
    LocalOwnerEmail: descriptor.localOwner.email,
    RegulatoryProfile: descriptor.regulatoryProfile,
    ApprovalPathId: descriptor.approvalPathId,
    ApprovalPath:
      Array.isArray(decision.approvalPath?.steps)
        ? decision.approvalPath.steps.join(' -> ')
        : '',
    CommercialPlanId: descriptor.commercial.planId,
    CommercialBillingModel: descriptor.commercial.billingModel,
    CommercialCurrency: descriptor.commercial.currency,
    CommercialSubscriptionPolicy: descriptor.commercial.subscriptionPolicy,
    CommercialSlaTier: descriptor.commercial.slaTier,
    CentralPolicyEnforcement: 'BLOCKING_PRODUCTION_AND_ADVISORY_REPORT_ONLY',
    PolicyDecision: decision.decisionStatus,
    PolicyAdvisoryCount: Array.isArray(decision.advisories)
      ? decision.advisories.length
      : 0,
  };
}

async function evaluateDescriptor(descriptor) {
  const response = await request(OPA_URL, {
    method: 'POST',
    json: { input: descriptor },
    ok: [200],
  });
  const decision = response?.result;
  if (!decision || typeof decision !== 'object') {
    throw new Error(`OPA returned no result for ${descriptor.apiName}.`);
  }
  const blocking = Array.isArray(decision.blocking) ? decision.blocking : [];
  const advisories = Array.isArray(decision.advisories)
    ? decision.advisories
    : [];
  log(
    `${descriptor.apiName}: ${decision.decisionStatus}; ` +
      `blocking=${blocking.length}; advisories=${advisories.length}`,
  );
  for (const advisory of advisories) {
    log(`ADVISORY ${descriptor.apiName} ${advisory.code}: ${advisory.message}`);
  }
  if (!decision.allow && FAIL_ON_DENY) {
    throw new Error(
      `Blocking central-policy denial for ${descriptor.apiName}: ` +
        blocking.map(item => `${item.code}: ${item.message}`).join('; '),
    );
  }
  return decision;
}

function documentContent(descriptor, decision, kind) {
  const approvalSteps =
    Array.isArray(decision.approvalPath?.steps)
      ? decision.approvalPath.steps.map((step, i) => `${i + 1}. ${step}`).join('\n')
      : '1. Central policy review';
  const common = [
    `API: **${descriptor.apiName}:${descriptor.apiVersion}**`,
    `Country overlay: **${descriptor.country}**`,
    `Risk classification: **${descriptor.riskClassification}**`,
    `Data residency: **${descriptor.dataResidency}**`,
    `Local owner: **${descriptor.localOwner.name}** (${descriptor.localOwner.email})`,
    `Commercial plan: **${descriptor.commercial.planId}**`,
    `Subscription policy: **${descriptor.commercial.subscriptionPolicy}**`,
    `Policy decision: **${decision.decisionStatus}**`,
  ].join('\n\n');

  if (kind === 'overview') {
    return `# Central Policy and Country Overlay

${common}

## Enforcement model

Production rules for group policy version, country overlay, risk classification,
data residency, local ownership, regulatory profile, commercial metadata and
high-risk evidence are blocking. Documentation-quality findings remain advisory
and are returned in the same decision without preventing publication.

## Approval path

${approvalSteps}

Mexico uses local owner → Mexico Privacy and Legal → Group Security Architecture
Board. Brazil uses local owner → Brazil DPO → Group Security Architecture Board.
`;
  }

  if (kind === 'privacy') {
    return `# Consent, Privacy and Data Residency

${common}

Consumers must preserve purpose limitation, consent or another approved legal
basis, data minimization, retention controls and immutable audit evidence.
The declared data-residency label is a deployment and processing constraint,
not merely descriptive metadata.

- Mexico profile: **MX-LFPDPPP-IFT**
- Brazil profile: **BR-LGPD-ANPD**
- Group baseline: **GROUP-BASELINE**

HIGH and CRITICAL APIs require a security review, privacy-impact assessment and
approval evidence before the blocking gate can return allow=true.
`;
  }

  return `# Errors, SLA, Sandbox, Postman and SDK

${common}

## Normalized errors

MI returns \`CENTRAL_POLICY_UPSTREAM_UNAVAILABLE\` with HTTP 503 only when both
bounded OPA endpoints fail or return an invalid envelope. An OPA policy denial
is a successful HTTP 200 decision with \`allow=false\`, a \`DENY\` status and
one or more blocking findings. Preserve \`X-Correlation-ID\` in support cases.

## Resilience and SLA guidance

- OPA request timeout: 3 seconds per endpoint.
- One bounded retry before suspension.
- Primary-to-DR failover.
- Exponential endpoint suspension up to 30 seconds.
- Advisory findings are a valid partial response and remain non-blocking.
- Illustrative premium target: 99.95% with 24x7 incident handling.

## Sandbox data

Use the catalog descriptors for compliant MX, BR and GROUP examples. To test a
blocking decision, remove \`localOwner.email\` or use a residency that does not
match the country. To test advisory behavior, retain all mandatory fields and
set one documentation evidence flag to false.

## Postman and SDK

Import \`artifacts/postman/telco-central-policy-overlays.postman_collection.json\`.
In the Developer Portal, open the API, use Try Out, and generate an SDK from the
published OpenAPI contract. Configure the generated client with the APIM gateway
base URL and an OAuth2 client-credentials token.
`;
}

async function listDocuments(token, basePath) {
  const response = await request(`${APIM_URL}${basePath}?limit=100`, {
    bearer: token,
  });
  return Array.isArray(response) ? response : response.list || response.data || [];
}

async function upsertDocument(token, basePath, document) {
  const existing = await listDocuments(token, basePath);
  let current = existing.find(item => item.name === document.name);
  const metadata = {
    name: document.name,
    summary: document.summary,
    type: document.type,
    sourceType: 'MARKDOWN',
    visibility: 'API_LEVEL',
  };
  if (current?.documentId || current?.id) {
    const id = current.documentId || current.id;
    current = await request(
      `${APIM_URL}${basePath}/${encodeURIComponent(id)}`,
      {
        method: 'PUT',
        bearer: token,
        json: metadata,
        ok: [200, 201, 202],
      },
    );
  } else {
    current = await request(`${APIM_URL}${basePath}`, {
      method: 'POST',
      bearer: token,
      json: metadata,
      ok: [200, 201, 202],
    });
  }
  const documentId =
    current?.documentId ||
    current?.id ||
    existing.find(item => item.name === document.name)?.documentId;
  if (!documentId) {
    throw new Error(`Document ID was not returned for ${document.name}.`);
  }
  const form = new FormData();
  form.append('inlineContent', document.content);
  await request(
    `${APIM_URL}${basePath}/${encodeURIComponent(documentId)}/content`,
    {
      method: 'POST',
      bearer: token,
      body: form,
      ok: [200, 201, 202],
    },
  );
  log(`upserted document: ${document.name}`);
}

function documentsFor(descriptor, decision) {
  return [
    {
      name: '10 - Central Policy and Country Overlay',
      summary: 'Blocking group policy and local regulatory overlay.',
      type: 'HOWTO',
      content: documentContent(descriptor, decision, 'overview'),
    },
    {
      name: '11 - Consent Privacy and Data Residency',
      summary: 'Country-specific privacy, consent and residency guidance.',
      type: 'HOWTO',
      content: documentContent(descriptor, decision, 'privacy'),
    },
    {
      name: '12 - Errors SLA Sandbox Postman and SDK',
      summary: 'Runtime, resilience, support and consumer tooling.',
      type: 'SAMPLES',
      content: documentContent(descriptor, decision, 'toolkit'),
    },
  ];
}

async function updateApi(token, summary, descriptor, decision) {
  const api = await request(
    `${APIM_URL}/api/am/publisher/v4/apis/${summary.id}`,
    { bearer: token },
  );
  api.policies = Array.from(
    new Set([...(Array.isArray(api.policies) ? api.policies : []), ...plansFor(api.name, descriptor)]),
  );
  api.businessInformation = {
    ...(api.businessInformation || {}),
    businessOwner: descriptor.localOwner.name,
    businessOwnerEmail: descriptor.localOwner.email,
    technicalOwner: 'Telco API Platform Team',
    technicalOwnerEmail: 'api-platform@example.com',
  };
  upsertProperties(api, descriptorProperties(descriptor, decision));
  await request(`${APIM_URL}/api/am/publisher/v4/apis/${api.id}`, {
    method: 'PUT',
    bearer: token,
    json: api,
    ok: [200, 201, 202],
  });
  for (const document of documentsFor(descriptor, decision)) {
    await upsertDocument(
      token,
      `/api/am/publisher/v4/apis/${api.id}/documents`,
      document,
    );
  }
  return {
    id: api.id,
    name: api.name,
    policies: api.policies,
    lifecycle: api.lifeCycleStatus,
  };
}

async function publishProduct(token, product) {
  const state = String(
    product.state || product.lifeCycleStatus || product.status || '',
  ).toUpperCase();
  if (state === 'PUBLISHED') return product;

  let revisionId;
  try {
    const revision = await request(
      `${APIM_URL}/api/am/publisher/v4/api-products/${product.id}/revisions`,
      {
        method: 'POST',
        bearer: token,
        json: {
          description:
            'Central policy country-overlay product release with Developer Portal documentation',
        },
        ok: [200, 201, 202],
      },
    );
    revisionId = revision.id || revision.revisionUuid || revision.revisionId;
  } catch (error) {
    log(`Product revision creation was non-fatal: ${error.message}`);
    const response = await request(
      `${APIM_URL}/api/am/publisher/v4/api-products/${product.id}/revisions`,
      { bearer: token },
    );
    const revisions = Array.isArray(response)
      ? response
      : response.list || response.data || [];
    const latest = revisions[revisions.length - 1];
    revisionId = latest?.id || latest?.revisionUuid || latest?.revisionId;
  }

  if (revisionId) {
    try {
      await request(
        `${APIM_URL}/api/am/publisher/v4/api-products/${product.id}/deploy-revision?revisionId=${encodeURIComponent(revisionId)}`,
        {
          method: 'POST',
          bearer: token,
          json: [
            {
              name: 'Default',
              vhost: 'localhost',
              displayOnDevportal: true,
            },
          ],
          ok: [200, 201, 202],
        },
      );
    } catch (error) {
      const message = String(error.message || error).toLowerCase();
      if (
        !message.includes('already deployed') &&
        !message.includes('409') &&
        !message.includes('revision deployment')
      ) {
        throw error;
      }
    }
  }

  try {
    await request(
      `${APIM_URL}/api/am/publisher/v4/api-products/change-lifecycle?apiProductId=${encodeURIComponent(product.id)}&action=Publish`,
      {
        method: 'POST',
        bearer: token,
        ok: [200, 201, 202],
      },
    );
  } catch (error) {
    const message = String(error.message || error).toLowerCase();
    if (
      !message.includes('already') &&
      !message.includes('unsupported state change action') &&
      !message.includes('903234')
    ) {
      throw error;
    }
  }

  return request(
    `${APIM_URL}/api/am/publisher/v4/api-products/${product.id}`,
    { bearer: token },
  );
}

async function updateProduct(token, productSummary, descriptor, decision) {
  const product = await request(
    `${APIM_URL}/api/am/publisher/v4/api-products/${productSummary.id}`,
    { bearer: token },
  );
  product.policies = Array.from(
    new Set([
      ...(Array.isArray(product.policies) ? product.policies : []),
      'TelcoPartnerStandard',
      'TelcoPartnerPremium',
      'Unlimited',
    ]),
  );
  upsertProperties(product, {
    ...descriptorProperties(descriptor, decision),
    CountryOverlayCoverage: 'GROUP,MX,BR',
    MemberPolicyAPI: 'CentralPolicyDecisionAPI',
  });
  await request(
    `${APIM_URL}/api/am/publisher/v4/api-products/${product.id}`,
    {
      method: 'PUT',
      bearer: token,
      json: product,
      ok: [200, 201, 202],
    },
  );
  for (const document of documentsFor(descriptor, decision)) {
    await upsertDocument(
      token,
      `/api/am/publisher/v4/api-products/${product.id}/documents`,
      document,
    );
  }
  const published = await publishProduct(token, product);
  const finalState = String(
    published.state || published.lifeCycleStatus || published.status || '',
  ).toUpperCase();
  if (finalState && finalState !== 'PUBLISHED') {
    throw new Error(`${PRODUCT_NAME} final lifecycle state is ${finalState}.`);
  }
  return { id: product.id, name: product.name, state: finalState || 'PUBLISHED' };
}

function centralPolicyServiceDefinition() {
  return {
    openapi: '3.0.3',
    info: {
      title: 'Central Policy Decision API',
      version: '1.0.0',
      description:
        'MI-managed OPA decision facade with correlation, normalized errors, bounded retry and failover.',
    },
    servers: [
      { url: 'http://wso2-mi:8290/internal/central-policy/v1' },
    ],
    paths: {
      '/health': {
        get: {
          operationId: 'centralPolicyHealth',
          responses: {
            200: {
              description: 'Healthy',
              content: {
                'application/json': {
                  schema: { type: 'object', additionalProperties: true },
                },
              },
            },
          },
        },
      },
      '/decisions': {
        post: {
          operationId: 'evaluateCentralPolicy',
          requestBody: {
            required: true,
            content: {
              'application/json': {
                schema: { type: 'object', additionalProperties: true },
              },
            },
          },
          responses: {
            200: {
              description: 'Evaluated policy decision',
              content: {
                'application/json': {
                  schema: { type: 'object', additionalProperties: true },
                },
              },
            },
            503: { description: 'Both bounded OPA endpoints unavailable' },
          },
        },
      },
    },
  };
}

async function upsertServiceCatalog(token) {
  const metadata = {
    name: 'CentralPolicyDecisionAPI',
    version: '1.0.0',
    description:
      'WSO2 Integrator: MI service that preserves correlation, wraps OPA requests, normalizes decisions and uses bounded retry, failover and endpoint suspension.',
    serviceUrl: 'http://wso2-mi:8290/internal/central-policy/v1',
    definitionType: 'OAS3',
    securityType: 'NONE',
    mutualSSLEnabled: false,
  };
  const response = await request(
    `${APIM_URL}/api/am/service-catalog/v1/services?limit=100`,
    { bearer: token },
  );
  const services = Array.isArray(response)
    ? response
    : response.list || response.data || [];
  const existing = services.find(
    item =>
      item.name === metadata.name &&
      String(item.version || '') === metadata.version,
  );
  const form = new FormData();
  form.append(
    'definitionFile',
    new Blob([JSON.stringify(centralPolicyServiceDefinition(), null, 2)], {
      type: 'application/json',
    }),
    'central-policy-decision-openapi.json',
  );
  form.append(
    'serviceMetadata',
    new Blob([JSON.stringify(metadata, null, 2)], {
      type: 'application/json',
    }),
    'central-policy-decision-metadata.json',
  );
  const id = existing?.id || existing?.serviceId;
  const url = id
    ? `${APIM_URL}/api/am/service-catalog/v1/services/${encodeURIComponent(id)}`
    : `${APIM_URL}/api/am/service-catalog/v1/services`;
  const result = await request(url, {
    method: id ? 'PUT' : 'POST',
    bearer: token,
    body: form,
    ok: [200, 201, 202],
  });
  log(
    `${metadata.name}:${metadata.version} ${id ? 'updated' : 'created'} in APIM Service Catalog.`,
  );
  return {
    id: result?.id || result?.serviceId || id || null,
    name: metadata.name,
    version: metadata.version,
    action: id ? 'UPDATED' : 'CREATED',
  };
}

async function main() {
  if (!fs.existsSync(CATALOG_FILE)) {
    throw new Error(`Central policy catalog is missing: ${CATALOG_FILE}`);
  }
  const catalog = JSON.parse(fs.readFileSync(CATALOG_FILE, 'utf8'));
  if (!Array.isArray(catalog.descriptors) || catalog.descriptors.length < 3) {
    throw new Error('Central policy catalog must contain GROUP, MX and BR descriptors.');
  }

  await waitFor(`${APIM_URL}/services/Version`, 'WSO2 API Manager');
  await waitFor(
    OPA_URL.replace('/v1/data/telco/central_policy/decision', '/health'),
    'OPA',
    30,
  ).catch(async () => {
    // OPA's root health URL differs by version. The decision call below is authoritative.
    log('OPA root health endpoint was not exposed; continuing to decision evaluation.');
  });

  const decisions = [];
  for (const descriptor of catalog.descriptors) {
    decisions.push({
      descriptor,
      decision: await evaluateDescriptor(descriptor),
    });
  }

  const token = await getPublisherToken();
  const apiSummaries = await listApis(token);
  const productSummaries = await listProducts(token);
  const state = {
    status: 'READY',
    generatedAt: new Date().toISOString(),
    failOnDeny: FAIL_ON_DENY,
    decisions: [],
    apis: [],
    products: [],
    serviceCatalog: null,
  };

  for (const item of decisions) {
    const summary = apiSummaries.find(
      api =>
        api.name === item.descriptor.apiName &&
        String(api.version || '1.0.0') === String(item.descriptor.apiVersion),
    );
    if (!summary?.id) {
      throw new Error(
        `Expected API is absent from Publisher: ` +
          `${item.descriptor.apiName}:${item.descriptor.apiVersion}`,
      );
    }
    state.apis.push(
      await updateApi(token, summary, item.descriptor, item.decision),
    );
    state.decisions.push({
      apiName: item.descriptor.apiName,
      allow: item.decision.allow,
      decisionStatus: item.decision.decisionStatus,
      blockingCount: item.decision.blocking?.length || 0,
      advisoryCount: item.decision.advisories?.length || 0,
      approvalPath: item.decision.approvalPath,
    });
  }

  const central = decisions.find(
    item => item.descriptor.apiName === 'CentralPolicyDecisionAPI',
  );
  const productSummary = productSummaries.find(
    product =>
      product.name === PRODUCT_NAME &&
      String(product.version || '1.0.0') === '1.0.0',
  );
  if (!productSummary?.id) {
    throw new Error(`Expected native API Product is absent: ${PRODUCT_NAME}:1.0.0`);
  }
  state.products.push(
    await updateProduct(
      token,
      productSummary,
      central.descriptor,
      central.decision,
    ),
  );
  state.serviceCatalog = await upsertServiceCatalog(token);

  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(STATE_FILE, `${JSON.stringify(state, null, 2)}\n`);
  log(`state written to ${STATE_FILE}`);
  log(
    `completed: ${state.apis.length} governed APIs, ` +
      `${state.products.length} native API Product, ` +
      `${state.decisions.length} blocking/advisory decisions, ` +
      `Service Catalog registered`,
  );
}

main().catch(error => {
  console.error(`[Central Policy] failed: ${error.stack || error.message}`);
  try {
    fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
    fs.writeFileSync(
      STATE_FILE,
      `${JSON.stringify(
        {
          status: 'FAILED',
          generatedAt: new Date().toISOString(),
          error: error.message,
        },
        null,
        2,
      )}\n`,
    );
  } catch {
    // Preserve the original failure.
  }
  process.exit(1);
});
