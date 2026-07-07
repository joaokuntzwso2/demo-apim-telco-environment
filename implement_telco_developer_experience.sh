#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(pwd)"

required_paths=(
  "services/apim-bootstrapper/package.json"
  "services/apim-bootstrapper/src"
  "services/wso2-apim/Dockerfile"
  "scripts/register-mi-service-catalog.sh"
  "scripts/register-soap-modernization-service-catalog.sh"
)

for required in "${required_paths[@]}"; do
  if [[ ! -e "${ROOT_DIR}/${required}" ]]; then
    echo "[developer-experience-install] ERROR: run this script from the repository root." >&2
    echo "[developer-experience-install] Missing: ${required}" >&2
    exit 1
  fi
done

mkdir -p \
  services/apim-bootstrapper/src \
  services/wso2-apim \
  scripts \
  docs/developer-portal

cat > services/apim-bootstrapper/src/developer-experience-setup.js <<'NODE'
'use strict';

const fs = require('fs');
const path = require('path');
const YAML = require('yaml');
const { fetch, FormData, Agent } = require('undici');

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const dispatcher = new Agent({ connect: { rejectUnauthorized: false } });

const APIM_URL = process.env.WSO2_APIM_URL || 'https://wso2-apim:9443';
const APIM_GATEWAY_URL =
  process.env.WSO2_APIM_GATEWAY_URL || 'https://wso2-apim:8243';
const USERNAME = process.env.APIM_USERNAME || 'admin';
const PASSWORD = process.env.APIM_PASSWORD || 'admin';
const BUNDLES_FILE =
  process.env.APIM_API_PRODUCT_BUNDLES_FILE ||
  '/workspace/artifacts/apim-admin/api-product-bundles.json';
const COMMERCIAL_PLANS_FILE =
  process.env.APIM_COMMERCIAL_PLANS_FILE ||
  '/workspace/artifacts/apim-admin/commercial-plans.json';
const STATE_FILE =
  process.env.APIM_DEVELOPER_EXPERIENCE_STATE_FILE ||
  '/workspace/state/developer-experience.json';

const TARGET_API_NAMES = new Set([
  'OpenGatewayNumberVerificationAPI',
  'OpenGatewaySimSwapRiskAPI',
  'OpenGatewayDeviceLocationVerificationAPI',
  'TelcoBusinessCatalogAPI',
  'Customer360API',
  'NumberLifecycleAPI',
  'NetworkSliceAPI',
  'PartnerChargingAPI',
  'BillingAdjustmentSOAP',
  'BillingAdjustmentModernizationAPI',
  'SecureTransactionRiskAssessmentAPI',
  'NetworkEventsStreamAPI'
]);

const TARGET_PRODUCT_NAMES = new Set([
  'OpenGatewayFraudDefenseProduct',
  'DigitalCustomerBSSExperienceProduct',
  'FiveGNetworkMonetizationProduct'
]);

const API_PLAN_ASSIGNMENTS = {
  OpenGatewayNumberVerificationAPI: [
    'TelcoFreeTrial',
    'TelcoOpenGatewayTrustStarter',
    'TelcoOpenGatewayTrustPremium'
  ],
  OpenGatewaySimSwapRiskAPI: [
    'TelcoFreeTrial',
    'TelcoOpenGatewayTrustStarter',
    'TelcoOpenGatewayTrustPremium'
  ],
  OpenGatewayDeviceLocationVerificationAPI: [
    'TelcoFreeTrial',
    'TelcoOpenGatewayTrustStarter',
    'TelcoOpenGatewayTrustPremium'
  ],
  TelcoBusinessCatalogAPI: [
    'TelcoFreeTrial',
    'TelcoPartnerStandard',
    'TelcoPartnerPremium'
  ],
  Customer360API: [
    'TelcoFreeTrial',
    'TelcoPartnerStandard',
    'TelcoPartnerPremium'
  ],
  NumberLifecycleAPI: [
    'TelcoFreeTrial',
    'TelcoPartnerStandard',
    'TelcoPartnerPremium'
  ],
  NetworkSliceAPI: [
    'TelcoPartnerStandard',
    'TelcoPartnerPremium'
  ],
  PartnerChargingAPI: [
    'TelcoPartnerStandard',
    'TelcoPartnerPremium'
  ],
  BillingAdjustmentSOAP: [
    'TelcoFreeTrial',
    'TelcoPartnerStandard'
  ],
  BillingAdjustmentModernizationAPI: [
    'TelcoFreeTrial',
    'TelcoPartnerStandard'
  ],
  SecureTransactionRiskAssessmentAPI: [
    'TelcoFreeTrial',
    'TelcoOpenGatewayTrustStarter',
    'TelcoOpenGatewayTrustPremium'
  ],
  NetworkEventsStreamAPI: [
    'TelcoFreeTrial',
    'TelcoEventStreamPremium'
  ]
};

const DEFAULT_POLICY = 'Unlimited';
const DOC_MARKER = '<!-- TELCO-DEVELOPER-EXPERIENCE-V1 -->';
const DESCRIPTION_MARKER = '[Developer experience: production-ready]';

function log(message) {
  console.log(`[Developer Experience] ${message}`);
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
    returnResponse = false
  } = {}
) {
  const requestHeaders = { ...headers };

  if (bearer) {
    requestHeaders.Authorization = `Bearer ${bearer}`;
  }
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
    dispatcher
  });

  const text = await response.text();
  let data = text;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    // Preserve text responses such as YAML/OpenAPI.
  }

  if (!ok.includes(response.status)) {
    const rendered =
      typeof data === 'string' ? data : JSON.stringify(data, null, 2);
    throw new Error(`${method} ${url} -> HTTP ${response.status}: ${rendered}`);
  }

  return returnResponse
    ? { status: response.status, headers: response.headers, data, text }
    : data;
}

async function waitForApim() {
  for (let attempt = 1; attempt <= 90; attempt += 1) {
    try {
      const response = await fetch(`${APIM_URL}/services/Version`, {
        dispatcher
      });
      if (response.ok) {
        log('WSO2 API Manager is reachable.');
        return;
      }
    } catch {
      // APIM may still be starting.
    }
    log(`Waiting for APIM (${attempt}/90)...`);
    await sleep(5000);
  }
  throw new Error(`APIM did not become reachable at ${APIM_URL}`);
}

async function getPublisherToken() {
  const dcr = await request(
    `${APIM_URL}/client-registration/v0.17/register`,
    {
      method: 'POST',
      basic: `${USERNAME}:${PASSWORD}`,
      json: {
        callbackUrl: 'http://localhost:8080/callback',
        clientName: `telco-developer-experience-${Date.now()}`,
        owner: USERNAME,
        grantType: 'password refresh_token client_credentials',
        saasApp: true
      },
      ok: [200, 201]
    }
  );

  const scopeCandidates = [
    [
      'apim:api_view',
      'apim:api_manage',
      'apim:api_update',
      'apim:api_publish',
      'apim:api_metadata_view',
      'apim:api_product_view',
      'apim:api_product_manage',
      'apim:api_product_publish',
      'apim:document_create',
      'apim:document_manage',
      'apim:document_update',
      'apim:document_delete'
    ],
    [
      'apim:api_view',
      'apim:api_manage',
      'apim:api_update',
      'apim:api_publish',
      'apim:api_metadata_view',
      'apim:document_create',
      'apim:document_manage',
      'apim:document_update',
      'apim:document_delete'
    ]
  ];

  let lastError;
  for (const scopes of scopeCandidates) {
    const form = new URLSearchParams();
    form.set('grant_type', 'password');
    form.set('username', USERNAME);
    form.set('password', PASSWORD);
    form.set('scope', scopes.join(' '));

    try {
      const token = await request(`${APIM_URL}/oauth2/token`, {
        method: 'POST',
        basic: `${dcr.clientId}:${dcr.clientSecret}`,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded'
        },
        body: form.toString(),
        ok: [200]
      });
      if (!token.access_token) {
        throw new Error('Token response did not contain access_token.');
      }
      return token.access_token;
    } catch (error) {
      lastError = error;
      log(`Token scope set rejected; trying compatible fallback: ${error.message}`);
    }
  }

  throw lastError || new Error('Unable to obtain Publisher access token.');
}

async function listApis(token) {
  const response = await request(
    `${APIM_URL}/api/am/publisher/v4/apis?limit=1000`,
    { bearer: token }
  );
  return response.list || response.data || [];
}

async function listApiProducts(token) {
  const response = await request(
    `${APIM_URL}/api/am/publisher/v4/api-products?limit=1000`,
    { bearer: token }
  );
  return response.list || response.data || [];
}

function parseDefinition(raw) {
  if (!raw) {
    return null;
  }
  if (typeof raw === 'object') {
    return raw;
  }
  try {
    return JSON.parse(raw);
  } catch {
    try {
      return YAML.parse(raw);
    } catch {
      return null;
    }
  }
}

async function readApiDefinition(token, api) {
  const apiId = api.id;
  const apiType = String(api.type || 'HTTP').toUpperCase();
  const asyncApiTypes = new Set([
    'WS',
    'WEBSUB',
    'SSE',
    'WEBHOOK',
    'ASYNC'
  ]);

  const definitionResource =
    apiType === 'GRAPHQL'
      ? 'graphql-schema'
      : asyncApiTypes.has(apiType)
        ? 'asyncapi'
        : 'swagger';

  try {
    const response = await request(
      `${APIM_URL}/api/am/publisher/v4/apis/${apiId}/${definitionResource}`,
      {
        bearer: token,
        headers: {
          Accept: 'application/json, application/yaml, text/yaml, */*'
        },
        returnResponse: true
      }
    );
    return parseDefinition(response.data || response.text);
  } catch (error) {
    log(
      `${apiType} definition could not be read for ${api.name || apiId} ` +
      `from ${definitionResource}: ${error.message}`
    );
    return null;
  }
}

function extractOperations(definition) {
  const operations = [];
  if (!definition || typeof definition !== 'object') {
    return operations;
  }

  const paths = definition.paths || {};
  for (const [resourcePath, pathItem] of Object.entries(paths)) {
    if (!pathItem || typeof pathItem !== 'object') {
      continue;
    }
    for (const method of [
      'get',
      'post',
      'put',
      'patch',
      'delete',
      'head',
      'options'
    ]) {
      const operation = pathItem[method];
      if (!operation) {
        continue;
      }
      operations.push({
        method: method.toUpperCase(),
        path: resourcePath,
        operationId: operation.operationId || '',
        summary: operation.summary || operation.description || ''
      });
    }
  }
  return operations;
}

function appendDescription(existing, overview) {
  const original = String(existing || '').trim();
  if (original.includes(DESCRIPTION_MARKER)) {
    return original;
  }
  return [original, DESCRIPTION_MARKER, overview].filter(Boolean).join('\n\n');
}

function upsertAdditionalProperties(entity, properties) {
  const existing = Array.isArray(entity.additionalProperties)
    ? entity.additionalProperties
    : [];

  const byName = new Map();
  for (const item of existing) {
    if (!item || !item.name) {
      continue;
    }
    byName.set(String(item.name).toLowerCase(), {
      name: String(item.name),
      value: String(item.value ?? ''),
      display: item.display !== false
    });
  }

  for (const [name, value] of Object.entries(properties)) {
    byName.set(name.toLowerCase(), {
      name,
      value: String(value),
      display: true
    });
  }

  entity.additionalProperties = Array.from(byName.values());

  // Publisher update DTOs derive this map internally. Sending a stale/read-only
  // map can cause update failures.
  delete entity.additionalPropertiesMap;
  return entity;
}

function businessOverview(apiName) {
  const overviews = {
    OpenGatewayNumberVerificationAPI:
      'Verifies whether a supplied phone number is associated with the authenticated subscriber, reducing account-takeover and synthetic-identity risk.',
    OpenGatewaySimSwapRiskAPI:
      'Returns recent SIM-swap risk information so banks, fintechs and digital services can apply step-up authentication before sensitive transactions.',
    OpenGatewayDeviceLocationVerificationAPI:
      'Checks whether a device is located within the expected area, enabling fraud prevention and location-aware customer journeys without exposing raw network telemetry.',
    TelcoBusinessCatalogAPI:
      'Provides partners with the operator service catalogue, offer metadata and commercial packaging used to discover and evaluate telco capabilities.',
    Customer360API:
      'Provides a normalized customer view across CRM and BSS domains for service, eligibility and assisted-channel use cases.',
    NumberLifecycleAPI:
      'Manages subscriber-number lifecycle operations and status transitions while preserving traceability across channel and network systems.',
    NetworkSliceAPI:
      'Exposes 5G slice catalogue and operational information for enterprise connectivity and network-as-a-service use cases.',
    PartnerChargingAPI:
      'Captures partner usage and charging information for settlement, reconciliation, revenue sharing and commercial reporting.',
    BillingAdjustmentSOAP:
      'Exposes the legacy billing-adjustment SOAP capability for controlled migration and compatibility testing.',
    BillingAdjustmentModernizationAPI:
      'Modernizes a legacy BSS SOAP operation as a normalized REST API through WSO2 Integrator, including security mediation, fault normalization and backend failover.',
    SecureTransactionRiskAssessmentAPI:
      'Orchestrates CRM, SIM-swap, device-location and OSS signals in WSO2 Integrator to return a normalized fraud-risk decision with partial-response handling.',
    NetworkEventsStreamAPI:
      'Publishes network events to authorized consumers through a streaming interface for proactive operations and partner automation.'
  };

  return (
    overviews[apiName] ||
    'Provides a governed telco capability through WSO2 API Manager with discoverability, security, subscription management and operational controls.'
  );
}

function camaraAlignment(apiName) {
  if (apiName.startsWith('OpenGateway')) {
    return [
      'This API is presented as a **CAMARA/Open Gateway-aligned demo API**.',
      'The OpenAPI contract is the technical source of truth for operations, schemas and examples.',
      'Before production use, validate the contract against the exact CAMARA release selected by the operator, including security profile, consent profile and error model.'
    ].join('\n\n');
  }

  return [
    'This is an operator-domain OpenAPI/AsyncAPI/SOAP capability and is **not represented as a normative CAMARA API**.',
    'It can be composed with CAMARA-aligned APIs in an API Product while retaining its own versioned contract.'
  ].join('\n\n');
}

function consentRequirements(apiName) {
  const directConsent = new Set([
    'OpenGatewayNumberVerificationAPI',
    'OpenGatewaySimSwapRiskAPI',
    'OpenGatewayDeviceLocationVerificationAPI',
    'Customer360API'
  ]);

  const conditionalConsent = new Set([
    'NumberLifecycleAPI',
    'SecureTransactionRiskAssessmentAPI'
  ]);

  if (directConsent.has(apiName)) {
    return {
      level: 'REQUIRED_OR_LEGAL_BASIS',
      text:
        'Use requires a purpose-bound subscriber consent or another operator-approved legal basis. The consuming application must preserve consent reference, purpose, timestamp, requesting party and correlation identifier. Do not expose raw network or subscriber data beyond the minimum response required by the use case.'
    };
  }

  if (conditionalConsent.has(apiName)) {
    return {
      level: 'CONDITIONAL',
      text:
        'Consent depends on the operation and channel. Subscriber-impacting or profile-derived operations require an operator-approved legal basis, while operational lifecycle actions also require authenticated workforce or partner authorization and a complete audit trail.'
    };
  }

  return {
    level: 'BUSINESS_AUTHORIZATION',
    text:
      'End-user consent is not normally the primary control for this capability. Access is governed by partner contract, application subscription, OAuth scopes, least privilege, audit logging and operator policy. Personal data must still be minimized and protected whenever present.'
  };
}

function sandboxData(apiName) {
  const common = {
    correlationId: 'demo-correlation-0001',
    partnerId: 'partner-sandbox-001',
    countryCode: 'BR'
  };

  const values = {
    OpenGatewayNumberVerificationAPI: {
      ...common,
      phoneNumber: '+5511999990001',
      expectedScenario: 'number-match'
    },
    OpenGatewaySimSwapRiskAPI: {
      ...common,
      phoneNumber: '+5511999990002',
      maxAgeHours: 72,
      expectedScenario: 'low-risk'
    },
    OpenGatewayDeviceLocationVerificationAPI: {
      ...common,
      phoneNumber: '+5511999990003',
      latitude: -23.55052,
      longitude: -46.633308,
      radiusMeters: 3000,
      expectedScenario: 'inside-area'
    },
    Customer360API: {
      ...common,
      customerId: 'CUST-10001',
      expectedScenario: 'active-customer'
    },
    NumberLifecycleAPI: {
      ...common,
      subscriberId: 'SUB-10001',
      phoneNumber: '+5511999990004',
      expectedScenario: 'active-number'
    },
    NetworkSliceAPI: {
      ...common,
      sliceId: 'slice-embb-sao-paulo-01',
      enterpriseId: 'ENT-10001',
      expectedScenario: 'available-capacity'
    },
    PartnerChargingAPI: {
      ...common,
      transactionId: 'TXN-DEMO-10001',
      usageUnits: 10,
      currency: 'USD',
      expectedScenario: 'accepted-usage'
    },
    BillingAdjustmentSOAP: {
      ...common,
      accountId: 'ACC-10001',
      adjustmentAmount: 15.5,
      currency: 'USD',
      reasonCode: 'SERVICE_CREDIT'
    },
    BillingAdjustmentModernizationAPI: {
      ...common,
      accountId: 'ACC-10001',
      adjustmentAmount: 15.5,
      currency: 'USD',
      reasonCode: 'SERVICE_CREDIT'
    },
    SecureTransactionRiskAssessmentAPI: {
      ...common,
      transactionId: 'TXN-RISK-10001',
      customerId: 'CUST-10001',
      phoneNumber: '+5511999990002',
      amount: 250.0,
      currency: 'USD',
      expectedScenario: 'allow'
    },
    NetworkEventsStreamAPI: {
      ...common,
      eventType: 'NETWORK_CELL_STATUS_CHANGED',
      cellId: 'CELL-SP-0001'
    },
    TelcoBusinessCatalogAPI: {
      ...common,
      category: 'open-gateway',
      expectedScenario: 'published-offers'
    }
  };

  return values[apiName] || common;
}

function renderOperationTable(operations) {
  if (!operations.length) {
    return '_The operation inventory is available in the generated API definition tab._';
  }

  const rows = operations
    .slice(0, 60)
    .map(
      operation =>
        `| \`${operation.method}\` | \`${operation.path}\` | ${String(
          operation.summary || operation.operationId || ''
        ).replace(/\|/g, '\\|')} |`
    );

  return [
    '| Method | Resource | Purpose |',
    '|---|---|---|',
    ...rows
  ].join('\n');
}

function gatewayUrl(entity, operation) {
  const context = String(entity.context || '').replace(/\/$/, '');
  const version = String(entity.version || '').trim();
  const resource = operation?.path || '/';
  const versionSegment =
    version && !context.endsWith(`/${version}`) ? `/${version}` : '';
  return `${APIM_GATEWAY_URL}${context}${versionSegment}${resource}`;
}

function firstCallOperation(operations) {
  return (
    operations.find(operation => operation.method === 'GET') ||
    operations.find(operation => operation.method === 'POST') ||
    operations[0] ||
    { method: 'GET', path: '/', summary: '' }
  );
}

function commercialPlanTable(policyNames, commercialPlans) {
  const byName = new Map(
    commercialPlans.map(plan => [String(plan.policyName), plan])
  );
  const names = Array.from(
    new Set((policyNames || []).filter(Boolean))
  );

  if (!names.length) {
    names.push(DEFAULT_POLICY);
  }

  const rows = names.map(policyName => {
    const plan = byName.get(policyName);
    if (plan) {
      const pricing = plan.pricing || {};
      const allowance =
        pricing.includedQuota ||
        (plan.limitType === 'EVENTCOUNTLIMIT'
          ? `${plan.eventCount || 0} events/${plan.timeUnit || 'min'}`
          : `${plan.requestCount || 0} requests/${plan.timeUnit || 'min'}`);
      const commercial =
        pricing.commercialSummary ||
        (plan.billingPlan === 'FREE' ? 'Free' : plan.billingPlan || 'Configured');
      return `| ${plan.displayName || policyName} (\`${policyName}\`) | ${allowance} | ${String(
        plan.description || ''
      ).replace(/\|/g, '\\|')} | ${String(commercial).replace(/\|/g, '\\|')} |`;
    }

    if (policyName === 'Unlimited') {
      return '| Unlimited (`Unlimited`) | No subscription-tier cap | Restricted internal/demo workloads | Non-commercial unless explicitly contracted |';
    }

    return `| ${policyName} | See the APIM subscription-policy definition | Product-specific entitlement | Defined by operator commercial catalogue |`;
  });

  return [
    '| Plan | Allowance | Intended use | Commercial treatment |',
    '|---|---:|---|---|',
    ...rows
  ].join('\n');
}

function apiDocuments(api, definition, commercialPlans) {
  const operations = extractOperations(definition);
  const firstOperation = firstCallOperation(operations);
  const consent = consentRequirements(api.name);
  const overview = businessOverview(api.name);
  const invokeUrl = gatewayUrl(api, firstOperation);
  const sandbox = JSON.stringify(sandboxData(api.name), null, 2);
  const ratePlanTable = commercialPlanTable(api.policies, commercialPlans);

  const payloadFlag = ['POST', 'PUT', 'PATCH'].includes(firstOperation.method)
    ? ` \\\n  -H 'Content-Type: application/json' \\\n  --data @request.json`
    : '';

  const curlSample = `curl -k --request ${firstOperation.method} \\
  '${invokeUrl}' \\
  -H 'Accept: application/json' \\
  -H 'Authorization: Bearer '\${ACCESS_TOKEN} \\
  -H 'X-Correlation-ID: demo-correlation-0001'${payloadFlag}`;

  const javascriptSample = `const response = await fetch(${JSON.stringify(
    invokeUrl
  )}, {
  method: ${JSON.stringify(firstOperation.method)},
  headers: {
    Accept: 'application/json',
    Authorization: \`Bearer \${process.env.ACCESS_TOKEN}\`,
    'X-Correlation-ID': 'demo-correlation-0001'
  }${
    ['POST', 'PUT', 'PATCH'].includes(firstOperation.method)
      ? ",\n  body: JSON.stringify(require('./request.json'))"
      : ''
  }
});

if (!response.ok) {
  throw new Error(\`HTTP \${response.status}: \${await response.text()}\`);
}
console.log(await response.json());`;

  const pythonSample = `import os
import requests

response = requests.${firstOperation.method.toLowerCase()}(
    ${JSON.stringify(invokeUrl)},
    headers={
        "Accept": "application/json",
        "Authorization": f"Bearer {os.environ['ACCESS_TOKEN']}",
        "X-Correlation-ID": "demo-correlation-0001",
    },${
      ['POST', 'PUT', 'PATCH'].includes(firstOperation.method)
        ? '\n    json=__import__("json").load(open("request.json")),'
        : ''
    }
    timeout=30,
)
response.raise_for_status()
print(response.json())`;

  return [
    {
      name: '01 - Business Overview',
      summary: 'Business purpose, audience and value proposition.',
      type: 'HOWTO',
      content: `${DOC_MARKER}
# ${api.name}: Business Overview

${overview}

## Intended consumers

- Authorized telco partners and enterprise developers
- Operator digital-channel and integration teams
- Fraud, customer-experience, BSS/OSS or network-domain applications, according to the API

## Business outcome

The API is exposed through WSO2 API Manager as a discoverable, subscribable and governed capability. Consumers can review the contract, create an application, subscribe, generate credentials and test the API directly from the Developer Portal.

## Ownership

- **Business owner:** ${api.businessInformation?.businessOwner || 'Telco API Product Office'}
- **Technical owner:** ${api.businessInformation?.technicalOwner || 'Telco API Platform Team'}
- **Lifecycle status:** ${api.lifeCycleStatus || api.state || 'PUBLISHED'}
- **Version:** ${api.version}
`
    },
    {
      name: '02 - Contract and CAMARA Alignment',
      summary: 'OpenAPI/AsyncAPI operation inventory and CAMARA positioning.',
      type: 'SWAGGER_DOC',
      content: `${DOC_MARKER}
# Contract and CAMARA Alignment

${camaraAlignment(api.name)}

## Contract principles

- The versioned API definition shown in the Developer Portal is the source of truth.
- Consumers must code against documented schemas and status codes.
- Backward-incompatible changes require a new API version.
- Correlation identifiers must be preserved end to end.

## Operation inventory

${renderOperationTable(operations)}

## Generated tooling

Use the Developer Portal **Try Out**, **Postman** and **SDKs** capabilities so generated clients remain aligned with the published definition.
`
    },
    {
      name: '03 - Authentication and First Call',
      summary: 'Self-service application, subscription, token and invocation steps.',
      type: 'HOWTO',
      content: `${DOC_MARKER}
# Authentication and First Call

## Self-service onboarding

1. Sign in to the WSO2 Developer Portal.
2. Create an application or select an existing application.
3. Subscribe the application to this API or to its API Product.
4. Select the required subscription plan.
5. Generate **Sandbox** OAuth credentials.
6. Generate an access token with the scopes displayed by the API.
7. Use **Try Out**, download the generated Postman collection, or invoke with curl.

No Publisher or administrator action is required when the standard self-service workflow is enabled.

## Authentication profile

- OAuth 2.0 bearer access token
- Application subscription
- Scope enforcement where configured
- HTTPS
- Optional mTLS or certificate-bound access token for a production partner profile
- Purpose-bound consent evidence where applicable

## First-call template

The Developer Portal shows the authoritative invoke URL. The following template is generated from the current API context and first operation:

\`\`\`bash
export ACCESS_TOKEN='<sandbox-access-token>'

${curlSample}
\`\`\`

For operations with a request body, export the exact example from the OpenAPI tab or generated Postman collection into \`request.json\`.
`
    },
    {
      name: '04 - Consent and Privacy Requirements',
      summary: 'Consent, legal-basis, minimization and audit requirements.',
      type: 'HOWTO',
      content: `${DOC_MARKER}
# Consent and Privacy Requirements

**Control classification:** \`${consent.level}\`

${consent.text}

## Consumer obligations

- Send only data necessary for the declared purpose.
- Do not cache sensitive responses beyond the approved retention period.
- Keep application, subject, purpose, consent/legal-basis and correlation references in the consumer audit trail.
- Do not use sandbox identities as real customer identities.
- Treat location, SIM-swap, identity, customer and billing data as sensitive operator information.
- Follow the operator's country-specific privacy, telecom and data-residency rules.

## Recommended headers

- \`Authorization: Bearer <token>\`
- \`X-Correlation-ID: <consumer-generated-id>\`
- \`X-Consent-ID: <consent-reference>\` when applicable
- \`X-Purpose: <approved-purpose>\` when applicable
`
    },
    {
      name: '05 - Error Catalogue',
      summary: 'Gateway, policy, integration and backend error handling.',
      type: 'API_MESSAGE_FORMAT',
      content: `${DOC_MARKER}
# Error Catalogue

| HTTP status | Meaning | Consumer action |
|---:|---|---|
| 400 | Invalid request or schema validation failure | Correct the payload, parameters or headers. |
| 401 | Missing, invalid or expired access token | Obtain a valid token and retry once. |
| 403 | Scope, subscription, consent or policy denied | Do not retry automatically; correct authorization. |
| 404 | Resource, customer, number or product not found | Validate the identifier and environment. |
| 409 | Conflicting state transition or duplicate request | Read the current state and use an idempotency key. |
| 429 | Rate limit exceeded | Honor \`Retry-After\` and use exponential backoff with jitter. |
| 500 | Unhandled platform or backend failure | Record correlation ID; retry only when the operation is safe. |
| 502 | Invalid/unavailable upstream response | Retry safe operations with bounded backoff. |
| 503 | Backend unavailable or endpoint circuit open/suspended | Honor retry guidance; do not create a retry storm. |
| 504 | Upstream timeout | Check operation outcome before retrying a non-idempotent request. |

## Normalized error shape

\`\`\`json
{
  "code": "TELCO-ERROR-CODE",
  "message": "Human-readable summary",
  "description": "Actionable detail without sensitive data",
  "correlationId": "demo-correlation-0001",
  "retryable": false,
  "timestamp": "2026-01-01T00:00:00Z"
}
\`\`\`

## Retry policy for consumers

- Retry only \`429\`, \`502\`, \`503\` and \`504\` when the operation is safe or protected by an idempotency key.
- Use exponential backoff with jitter and a bounded attempt count.
- Never retry \`400\`, \`401\`, \`403\` or \`409\` blindly.
- Always log the correlation identifier.
`
    },
    {
      name: '06 - Rate Limits and Commercial Plan',
      summary: 'Subscription tiers and illustrative commercial packaging.',
      type: 'HOWTO',
      content: `${DOC_MARKER}
# Rate Limits and Commercial Plan

The following policies are read from the API's current WSO2 API Manager subscription configuration. Exact prices, overage rules, revenue share and production entitlements remain subject to the operator-partner agreement.

${ratePlanTable}

## Important controls

- Resource and application limits may be stricter than the subscription tier.
- Burst control protects the backend from sudden traffic spikes.
- A \`429 Too Many Requests\` response is not billable unless the commercial agreement explicitly states otherwise.
- The consumer must implement backoff and must not bypass limits by creating multiple applications.
- Commercial values in this demo are illustrative and non-binding.
`
    },
    {
      name: '07 - SLA Support and Resilience',
      summary: 'Illustrative SLA, support and resilience behavior.',
      type: 'SUPPORT_FORUM',
      content: `${DOC_MARKER}
# SLA, Support and Resilience

## Illustrative service levels

| Commercial class | Monthly availability target | Support objective |
|---|---:|---|
| Free trial / sandbox | 99.5% | Business-hours support |
| Standard / starter | 99.9% | Extended-hours partner support |
| Premium production | 99.95% | 24x7 production incident handling |
| Unlimited internal/demo | Non-contractual | Platform-team support |

These values are demo examples and do not constitute a commercial commitment.

## Platform behavior

- WSO2 API Manager enforces authentication, subscription and rate-limiting policies.
- WSO2 Integrator-managed services use bounded timeouts, fault sequences, failover endpoints and endpoint suspension/circuit-breaking behavior where configured.
- Correlation identifiers are propagated for gateway-to-integration-to-backend troubleshooting.
- The risk-assessment flow supports a partial-response policy so a controlled decision can be returned when selected non-critical signals are unavailable.
- Recovery testing should include primary backend outage, timeout, malformed response and repeated-failure scenarios.

## Support information to provide

- API and version
- UTC timestamp
- HTTP status and error code
- Correlation identifier
- Application name
- Non-sensitive request summary
`
    },
    {
      name: '08 - Code Samples Postman and SDKs',
      summary: 'Curl, JavaScript and Python samples plus generated tooling.',
      type: 'SAMPLES',
      content: `${DOC_MARKER}
# Code Samples, Postman and SDKs

## Curl

\`\`\`bash
${curlSample}
\`\`\`

## JavaScript

\`\`\`javascript
${javascriptSample}
\`\`\`

## Python

\`\`\`python
${pythonSample}
\`\`\`

## Postman

From the Developer Portal:

1. Open the API.
2. Select an application/subscription.
3. Open **Try Out**.
4. Download the generated Postman collection.
5. Select the Sandbox endpoint and supply the generated bearer token.

## SDKs

Open the API's **SDKs** tab and generate a supported client SDK. The demo enables Java, JavaScript, Android, JMeter, Python, C#, PHP, Swift and Go where supported by the installed APIM generator.
`
    },
    {
      name: '09 - Sandbox Test Data',
      summary: 'Safe deterministic data for first-call validation.',
      type: 'SAMPLES',
      content: `${DOC_MARKER}
# Sandbox Test Data

Use only these synthetic values in the demo environment.

\`\`\`json
${sandbox}
\`\`\`

## Sandbox rules

- Values are synthetic and must not be interpreted as real subscribers, accounts or network assets.
- Use the Developer Portal definition examples to place these fields in the correct request schema.
- Preserve \`demo-correlation-0001\` for the first test so the request can be traced across APIM, WSO2 Integrator and backend logs.
- Negative tests should include an unknown identifier, an invalid token and a deliberate rate-limit test.
`
    }
  ];
}

function bundleForProduct(product, bundles) {
  return bundles.find(
    bundle =>
      bundle?.apim?.apiProductName === product.name ||
      bundle?.name === product.name
  );
}

function productDocuments(product, bundle, commercialPlans) {
  const memberApis = Array.isArray(product.apis) ? product.apis : [];
  const memberRows = memberApis.length
    ? memberApis
        .map(
          item =>
            `| ${item.name || item.apiName || 'API'} | ${item.version || '1.0.0'} | ${
              Array.isArray(item.operations) ? item.operations.length : 'All selected'
            } |`
        )
        .join('\n')
    : '| Refer to product definition | - | - |';

  const businessStory =
    bundle?.businessStory ||
    bundle?.description ||
    'A curated telco API Product that groups complementary capabilities into one partner subscription.';
  const businessOutcome =
    bundle?.businessOutcome ||
    'Reduce partner onboarding time and present a coherent commercial product instead of disconnected technical APIs.';
  const productPlanNames = Array.from(
    new Set([
      ...(Array.isArray(bundle?.plans) ? bundle.plans : []),
      ...(Array.isArray(product.policies) ? product.policies : []),
      DEFAULT_POLICY
    ])
  );
  const plans = productPlanNames.join(', ');
  const ratePlanTable = commercialPlanTable(productPlanNames, commercialPlans);

  return [
    {
      name: '01 - Product Overview and API Map',
      summary: 'Product value proposition and included APIs.',
      type: 'HOWTO',
      content: `${DOC_MARKER}
# ${product.name}: Product Overview

${businessStory}

## Business outcome

${businessOutcome}

## Included APIs

| API | Version | Included operations |
|---|---|---:|
${memberRows}

## Partner journey

The partner can discover this product, review all member APIs, subscribe one application, generate credentials and begin testing without Publisher or administrator involvement.
`
    },
    {
      name: '02 - Product Onboarding and First Call',
      summary: 'End-to-end self-service onboarding sequence.',
      type: 'HOWTO',
      content: `${DOC_MARKER}
# Product Onboarding and First Call

1. Sign in to the Developer Portal.
2. Review this product overview, commercial plan and consent matrix.
3. Create a Sandbox application.
4. Subscribe the application to this API Product.
5. Generate Sandbox OAuth credentials and an access token.
6. Open a member API and use **Try Out**, generated Postman or an SDK.
7. Start with the member API's published sandbox test data.
8. Preserve \`X-Correlation-ID\` across the complete flow.

## Production readiness checklist

- Contract and version approved
- Security profile and scopes approved
- Consent/legal-basis integration completed
- Rate tier and commercial plan contracted
- Retry/idempotency behavior tested
- SLA and support contacts agreed
- Production credentials stored in an approved secret manager
`
    },
    {
      name: '03 - Consent and Compliance Matrix',
      summary: 'Product-wide privacy and authorization controls.',
      type: 'HOWTO',
      content: `${DOC_MARKER}
# Consent and Compliance Matrix

| Capability type | Required control |
|---|---|
| Identity, number verification, SIM-swap or location | Purpose-bound consent or approved legal basis, minimization and audit |
| Customer/BSS data | Subscriber or workforce authorization according to purpose |
| Billing adjustment | Strong partner/workforce authorization, approval policy and immutable audit |
| Network and charging data | Partner contract, scope enforcement and operational confidentiality |
| Streaming events | Explicit event subscription, filtering and retention control |

Each member API contains its detailed consent classification. The strictest applicable member-API requirement governs the composed partner journey.
`
    },
    {
      name: '04 - Commercial Plans Rate Limits and SLA',
      summary: 'Product subscription plans and illustrative SLA.',
      type: 'HOWTO',
      content: `${DOC_MARKER}
# Commercial Plans, Rate Limits and SLA

**Configured/declared plans:** ${plans}

${ratePlanTable}

## Illustrative SLA mapping

| Commercial class | Monthly availability target | Support |
|---|---:|---|
| Free trial / sandbox | 99.5% | Business hours |
| Standard / starter | 99.9% | Extended hours |
| Premium production | 99.95% | 24x7 incident handling |
| Unlimited internal/demo | Non-contractual | Platform team |

Commercial values, prices, revenue-share models, settlement rules and SLA credits are illustrative until agreed in the operator-partner contract.
`
    },
    {
      name: '05 - Sandbox Postman and SDK Toolkit',
      summary: 'How to use member API examples and generated clients.',
      type: 'SAMPLES',
      content: `${DOC_MARKER}
# Sandbox, Postman and SDK Toolkit

For each member API:

1. Open **Sandbox Test Data**.
2. Copy the published example values.
3. Use **Try Out** for the first request.
4. Download the generated Postman collection from the API.
5. Generate a client SDK from the API's **SDKs** tab.
6. Test authentication failure, authorization failure, rate limiting and backend unavailability.
7. Capture the correlation identifier in every result.

The generated collection and SDK are derived from the published API definition, preventing drift between documentation and executable client artifacts.
`
    }
  ];
}

async function listDocuments(token, basePath) {
  const response = await request(`${APIM_URL}${basePath}?limit=100`, {
    bearer: token
  });
  return response.list || response.data || [];
}

async function upsertDocument(token, basePath, document) {
  const existing = await listDocuments(token, basePath);
  let current = existing.find(item => item.name === document.name);

  const metadata = {
    name: document.name,
    summary: document.summary,
    type: document.type,
    sourceType: 'MARKDOWN',
    visibility: 'API_LEVEL'
  };

  if (current?.documentId || current?.id) {
    const documentId = current.documentId || current.id;
    current = await request(
      `${APIM_URL}${basePath}/${encodeURIComponent(documentId)}`,
      {
        method: 'PUT',
        bearer: token,
        json: metadata,
        ok: [200, 201, 202]
      }
    );
  } else {
    current = await request(`${APIM_URL}${basePath}`, {
      method: 'POST',
      bearer: token,
      json: metadata,
      ok: [200, 201, 202]
    });
  }

  const documentId =
    current?.documentId ||
    current?.id ||
    existing.find(item => item.name === document.name)?.documentId;

  if (!documentId) {
    throw new Error(
      `Document metadata did not return an ID for ${document.name}`
    );
  }

  const form = new FormData();
  form.append('inlineContent', document.content);

  await request(
    `${APIM_URL}${basePath}/${encodeURIComponent(documentId)}/content`,
    {
      method: 'POST',
      bearer: token,
      body: form,
      ok: [200, 201, 202]
    }
  );

  log(`upserted document: ${document.name}`);
}

async function updateApiMetadata(token, summary, commercialPlans) {
  const api = await request(
    `${APIM_URL}/api/am/publisher/v4/apis/${summary.id}`,
    { bearer: token }
  );

  const consent = consentRequirements(api.name);
  api.description = appendDescription(
    api.description,
    businessOverview(api.name)
  );
  const assignedPlans = API_PLAN_ASSIGNMENTS[api.name] || [];
  api.policies = Array.from(
    new Set([
      ...(Array.isArray(api.policies) ? api.policies : []),
      ...assignedPlans,
      DEFAULT_POLICY
    ])
  );

  upsertAdditionalProperties(api, {
    DocumentationMaturity: 'PRODUCTION_READY',
    AuthenticationProfile: 'OAUTH2_BEARER',
    ConsentRequirement: consent.level,
    SandboxDataAvailable: 'true',
    ErrorCatalogueAvailable: 'true',
    CommercialPlans: api.policies.join(','),
    IllustrativeSLA: 'FreeTrial=99.5%;Standard=99.9%;Premium=99.95%',
    GeneratedPostmanAvailable: 'true',
    GeneratedSDKAvailable: 'true'
  });

  await request(`${APIM_URL}/api/am/publisher/v4/apis/${api.id}`, {
    method: 'PUT',
    bearer: token,
    json: api,
    ok: [200, 201, 202]
  });

  const definition = await readApiDefinition(token, api);
  for (const document of apiDocuments(api, definition, commercialPlans)) {
    await upsertDocument(
      token,
      `/api/am/publisher/v4/apis/${api.id}/documents`,
      document
    );
  }

  return {
    name: api.name,
    id: api.id,
    version: api.version,
    documentCount: apiDocuments(api, definition, commercialPlans).length,
    policies: api.policies
  };
}

async function listProductRevisions(token, productId) {
  try {
    const response = await request(
      `${APIM_URL}/api/am/publisher/v4/api-products/${productId}/revisions`,
      { bearer: token }
    );
    return response.list || response.data || response || [];
  } catch (error) {
    log(`Could not list product revisions: ${error.message}`);
    return [];
  }
}

async function ensureProductPublished(token, product) {
  const currentState = String(
    product.state || product.lifeCycleStatus || product.status || ''
  ).toUpperCase();

  if (currentState === 'PUBLISHED') {
    log(`${product.name} is already PUBLISHED.`);
    return 'PUBLISHED';
  }

  let revisionId;
  try {
    const revision = await request(
      `${APIM_URL}/api/am/publisher/v4/api-products/${product.id}/revisions`,
      {
        method: 'POST',
        bearer: token,
        json: {
          description:
            'Developer Portal self-service release with production-quality documentation'
        },
        ok: [200, 201, 202]
      }
    );
    revisionId = revision.id || revision.revisionUuid || revision.revisionId;
  } catch (error) {
    log(`Product revision creation was not required or failed non-fatally: ${error.message}`);
    const revisions = await listProductRevisions(token, product.id);
    const latest = revisions[revisions.length - 1];
    revisionId = latest?.id || latest?.revisionUuid || latest?.revisionId;
  }

  if (revisionId) {
    try {
      await request(
        `${APIM_URL}/api/am/publisher/v4/api-products/${product.id}/deploy-revision?revisionId=${encodeURIComponent(
          revisionId
        )}`,
        {
          method: 'POST',
          bearer: token,
          json: [
            {
              name: 'Default',
              vhost: 'localhost',
              displayOnDevportal: true
            }
          ],
          ok: [200, 201, 202]
        }
      );
      log(`deployed API Product revision ${revisionId}`);
    } catch (error) {
      const message = String(error.message || error);
      if (
        !message.includes('already deployed') &&
        !message.includes('409') &&
        !message.includes('revision deployment')
      ) {
        throw error;
      }
      log(`API Product revision is already deployed: ${revisionId}`);
    }
  } else {
    log(
      `No revision ID was available for ${product.name}; attempting lifecycle publish because the product may already be deployed.`
    );
  }

  try {
    await request(
      `${APIM_URL}/api/am/publisher/v4/api-products/change-lifecycle?apiProductId=${encodeURIComponent(
        product.id
      )}&action=Publish`,
      {
        method: 'POST',
        bearer: token,
        ok: [200, 201, 202]
      }
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
    log(`${product.name} lifecycle is already compatible with publication.`);
  }

  const refreshed = await request(
    `${APIM_URL}/api/am/publisher/v4/api-products/${product.id}`,
    { bearer: token }
  );
  const state = String(
    refreshed.state || refreshed.lifeCycleStatus || refreshed.status || ''
  ).toUpperCase();

  if (state && state !== 'PUBLISHED') {
    throw new Error(
      `${product.name} was processed but final lifecycle state is ${state}`
    );
  }

  log(`${product.name} is published and configured for Developer Portal display.`);
  return state || 'PUBLISHED';
}

async function updateProductMetadata(token, summary, bundles, commercialPlans) {
  const product = await request(
    `${APIM_URL}/api/am/publisher/v4/api-products/${summary.id}`,
    { bearer: token }
  );
  const bundle = bundleForProduct(product, bundles);

  const overview =
    bundle?.description ||
    bundle?.businessStory ||
    'A curated telco API Product for self-service partner consumption.';

  product.description = appendDescription(product.description, overview);
  product.policies = Array.from(
    new Set([
      ...(Array.isArray(product.policies) ? product.policies : []),
      ...(Array.isArray(bundle?.plans) ? bundle.plans : []),
      DEFAULT_POLICY
    ])
  );

  upsertAdditionalProperties(product, {
    DocumentationMaturity: 'PRODUCTION_READY',
    SelfServiceOnboarding: 'true',
    SandboxDataAvailable: 'true',
    CommercialPlans: product.policies.join(','),
    GeneratedPostmanPerMemberAPI: 'true',
    GeneratedSDKPerMemberAPI: 'true'
  });

  await request(
    `${APIM_URL}/api/am/publisher/v4/api-products/${product.id}`,
    {
      method: 'PUT',
      bearer: token,
      json: product,
      ok: [200, 201, 202]
    }
  );

  for (const document of productDocuments(product, bundle, commercialPlans)) {
    await upsertDocument(
      token,
      `/api/am/publisher/v4/api-products/${product.id}/documents`,
      document
    );
  }

  const state = await ensureProductPublished(token, product);

  return {
    name: product.name,
    id: product.id,
    version: product.version,
    documentCount: productDocuments(product, bundle, commercialPlans).length,
    policies: product.policies,
    state
  };
}

function readBundles() {
  if (!fs.existsSync(BUNDLES_FILE)) {
    log(`Bundle file not found; product docs will use API Product metadata: ${BUNDLES_FILE}`);
    return [];
  }
  return JSON.parse(fs.readFileSync(BUNDLES_FILE, 'utf8'));
}

function readCommercialPlans() {
  if (!fs.existsSync(COMMERCIAL_PLANS_FILE)) {
    log(`Commercial plans file not found; policy names will still be documented: ${COMMERCIAL_PLANS_FILE}`);
    return [];
  }
  return JSON.parse(fs.readFileSync(COMMERCIAL_PLANS_FILE, 'utf8'));
}

async function main() {
  await waitForApim();

  const token = await getPublisherToken();
  const bundles = readBundles();
  const commercialPlans = readCommercialPlans();
  const apiSummaries = await listApis(token);
  const productSummaries = await listApiProducts(token);

  const state = {
    generatedAt: new Date().toISOString(),
    apimUrl: APIM_URL,
    gatewayUrl: APIM_GATEWAY_URL,
    apis: [],
    products: [],
    warnings: []
  };

  for (const apiName of TARGET_API_NAMES) {
    const summary = apiSummaries.find(
      item => item.name === apiName && String(item.version || '1.0.0') === '1.0.0'
    );
    if (!summary?.id) {
      state.warnings.push(`API not found: ${apiName}:1.0.0`);
      log(`WARNING: API not found: ${apiName}:1.0.0`);
      continue;
    }

    log(`enriching API ${apiName}`);
    state.apis.push(await updateApiMetadata(token, summary, commercialPlans));
  }

  const selectedProducts = productSummaries.filter(
    item =>
      TARGET_PRODUCT_NAMES.has(item.name) ||
      bundles.some(bundle => bundle?.apim?.apiProductName === item.name)
  );

  for (const summary of selectedProducts) {
    log(`enriching API Product ${summary.name}`);
    state.products.push(await updateProductMetadata(token, summary, bundles, commercialPlans));
  }

  for (const expectedName of TARGET_PRODUCT_NAMES) {
    if (!selectedProducts.some(item => item.name === expectedName)) {
      state.warnings.push(`Native API Product not found: ${expectedName}`);
    }
  }

  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));

  log(`state written to ${STATE_FILE}`);
  log(
    `completed: ${state.apis.length} APIs and ${state.products.length} API Products enriched`
  );

  if (state.warnings.length) {
    log(`warnings: ${state.warnings.join('; ')}`);
  }
}

main().catch(error => {
  console.error(`[Developer Experience] failed: ${error.stack || error.message}`);
  process.exit(1);
});
NODE

cat > services/wso2-apim/merge-developer-experience-config.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-/home/wso2carbon/wso2am-4.7.0/repository/conf/deployment.toml}"

if [[ ! -f "$TARGET" ]]; then
  echo "[apim-developer-experience-config] ERROR: deployment.toml not found: $TARGET" >&2
  exit 1
fi

upsert_toml_key() {
  local table="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"

  awk -v wanted_table="[${table}]" -v wanted_key="$key" -v wanted_value="$value" '
    BEGIN {
      inside = 0
      section_found = 0
      key_written = 0
    }

    /^\[/ {
      if (inside && !key_written) {
        print wanted_key " = " wanted_value
        key_written = 1
      }
      inside = ($0 == wanted_table)
      if (inside) {
        section_found = 1
        key_written = 0
      }
    }

    {
      if (inside && $0 ~ "^[[:space:]]*" wanted_key "[[:space:]]*=") {
        if (!key_written) {
          print wanted_key " = " wanted_value
          key_written = 1
        }
        next
      }
      print
    }

    END {
      if (inside && !key_written) {
        print wanted_key " = " wanted_value
        key_written = 1
      }
      if (!section_found) {
        print ""
        print wanted_table
        print wanted_key " = " wanted_value
      }
    }
  ' "$TARGET" > "$tmp"

  cat "$tmp" > "$TARGET"
  rm -f "$tmp"
}

upsert_toml_key \
  "apim.publisher" \
  "enable_api_doc_visibility" \
  '"true"'

upsert_toml_key \
  "apim.publisher" \
  "supported_document_types" \
  '"pdf, txt, doc, docx, xls, xlsx, odt, ods, json, yaml, yml, md"'

upsert_toml_key \
  "apim.sdk" \
  "supported_languages" \
  '["android", "java", "javascript", "jmeter", "python", "csharp", "php", "swift5", "go"]'

echo "[apim-developer-experience-config] Developer Portal documentation and SDK settings merged."
SH
chmod +x services/wso2-apim/merge-developer-experience-config.sh

python3 <<'PY'
from pathlib import Path
import json

commercial_plans_path = Path("artifacts/apim-admin/commercial-plans.json")
if commercial_plans_path.exists():
    commercial_plans = json.loads(commercial_plans_path.read_text())
    by_name = {item.get("policyName"): item for item in commercial_plans}

    missing_plans = [
        {
            "policyName": "TelcoOpenGatewayTrustStarter",
            "displayName": "Telco Open Gateway Trust Starter",
            "description": "Starter commercial plan for CAMARA/Open Gateway trust APIs: 500 requests per minute.",
            "requestCount": 500,
            "timeUnit": "min",
            "unitTime": 1,
            "billingPlan": "COMMERCIAL",
            "stopOnQuotaReach": True,
            "pricing": {
                "billingType": "FIXED_RATE",
                "billingCycle": "month",
                "currencyType": "USD",
                "fixedPrice": "999.00",
                "pricePerRequest": "0.0050",
                "includedQuota": "500 req/min",
                "commercialSummary": "USD 999/month + USD 0.005 per extra request"
            }
        },
        {
            "policyName": "TelcoOpenGatewayTrustPremium",
            "displayName": "Telco Open Gateway Trust Premium",
            "description": "Premium commercial plan for high-volume CAMARA/Open Gateway trust APIs: 5000 requests per minute.",
            "requestCount": 5000,
            "timeUnit": "min",
            "unitTime": 1,
            "billingPlan": "COMMERCIAL",
            "stopOnQuotaReach": True,
            "pricing": {
                "billingType": "FIXED_RATE",
                "billingCycle": "month",
                "currencyType": "USD",
                "fixedPrice": "4999.00",
                "pricePerRequest": "0.0020",
                "includedQuota": "5000 req/min",
                "commercialSummary": "USD 4,999/month + USD 0.002 per extra request"
            }
        }
    ]

    changed = False
    for plan in missing_plans:
        if plan["policyName"] not in by_name:
            commercial_plans.append(plan)
            changed = True

    if changed:
        commercial_plans_path.write_text(json.dumps(commercial_plans, indent=2) + "\n")

package_path = Path("services/apim-bootstrapper/package.json")
package = json.loads(package_path.read_text())
start = package["scripts"]["start"]
dx_command = "node src/developer-experience-setup.js"

if dx_command not in start:
    anchor = "node src/api-product-bundles-setup.js"
    if anchor in start:
        start = start.replace(anchor, f"{anchor} && {dx_command}", 1)
    else:
        start = f"{start} && {dx_command}"
    package["scripts"]["start"] = start
    package_path.write_text(json.dumps(package, indent=2) + "\n")

dockerfile_path = Path("services/wso2-apim/Dockerfile")
dockerfile = dockerfile_path.read_text()

begin = "# BEGIN TELCO APIM DEVELOPER EXPERIENCE"
end = "# END TELCO APIM DEVELOPER EXPERIENCE"
block = """# BEGIN TELCO APIM DEVELOPER EXPERIENCE
COPY services/wso2-apim/merge-developer-experience-config.sh /tmp/merge-apim-developer-experience-config.sh
RUN chmod +x /tmp/merge-apim-developer-experience-config.sh \\
    && /tmp/merge-apim-developer-experience-config.sh /home/wso2carbon/wso2am-4.7.0/repository/conf/deployment.toml \\
    && rm -f /tmp/merge-apim-developer-experience-config.sh
# END TELCO APIM DEVELOPER EXPERIENCE
"""

if begin not in dockerfile:
    marker = "# BEGIN TELCO APIM OBSERVABILITY"
    if marker in dockerfile:
        dockerfile = dockerfile.replace(marker, block + marker, 1)
    elif "USER wso2carbon" in dockerfile:
        dockerfile = dockerfile.replace("USER wso2carbon", block + "USER wso2carbon", 1)
    else:
        dockerfile = dockerfile.rstrip() + "\n" + block
    dockerfile_path.write_text(dockerfile)

print("[developer-experience-install] package.json and APIM Dockerfile patched.")
PY

cat > scripts/verify-developer-experience.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

APIM_URL="${WSO2_APIM_PUBLIC_URL:-https://127.0.0.1:9443}"
APIM_USER="${APIM_USERNAME:-admin}"
APIM_PASSWORD="${APIM_PASSWORD:-admin}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/telco-developer-experience-verify.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

for command in curl jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "[verify-developer-experience] ERROR: missing command: $command" >&2
    exit 1
  }
done

dcr_response="$(
  curl -ksS \
    -u "${APIM_USER}:${APIM_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d "{
      \"callbackUrl\":\"http://localhost:8080/callback\",
      \"clientName\":\"telco-dx-verifier-$(date +%s)-$$\",
      \"owner\":\"${APIM_USER}\",
      \"grantType\":\"password refresh_token client_credentials\",
      \"saasApp\":true
    }" \
    "${APIM_URL}/client-registration/v0.17/register"
)"

client_id="$(jq -r '.clientId // empty' <<<"$dcr_response")"
client_secret="$(jq -r '.clientSecret // empty' <<<"$dcr_response")"

if [[ -z "$client_id" || -z "$client_secret" ]]; then
  echo "[verify-developer-experience] ERROR: DCR failed." >&2
  jq . <<<"$dcr_response" >&2 || printf '%s\n' "$dcr_response" >&2
  exit 1
fi

publisher_token_response="$(
  curl -ksS \
    -u "${client_id}:${client_secret}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${APIM_USER}" \
    --data-urlencode "password=${APIM_PASSWORD}" \
    --data-urlencode 'scope=apim:api_view apim:api_manage apim:api_publish apim:api_metadata_view apim:document_create apim:document_manage apim:document_update apim:document_delete' \
    "${APIM_URL}/oauth2/token"
)"
publisher_token="$(jq -r '.access_token // empty' <<<"$publisher_token_response")"

if [[ -z "$publisher_token" ]]; then
  echo "[verify-developer-experience] ERROR: Publisher token request failed." >&2
  jq . <<<"$publisher_token_response" >&2 || printf '%s\n' "$publisher_token_response" >&2
  exit 1
fi

api_names=(
  OpenGatewayNumberVerificationAPI
  OpenGatewaySimSwapRiskAPI
  OpenGatewayDeviceLocationVerificationAPI
  TelcoBusinessCatalogAPI
  Customer360API
  NumberLifecycleAPI
  NetworkSliceAPI
  PartnerChargingAPI
  BillingAdjustmentSOAP
  BillingAdjustmentModernizationAPI
  SecureTransactionRiskAssessmentAPI
  NetworkEventsStreamAPI
)

api_doc_names=(
  "01 - Business Overview"
  "02 - Contract and CAMARA Alignment"
  "03 - Authentication and First Call"
  "04 - Consent and Privacy Requirements"
  "05 - Error Catalogue"
  "06 - Rate Limits and Commercial Plan"
  "07 - SLA Support and Resilience"
  "08 - Code Samples Postman and SDKs"
  "09 - Sandbox Test Data"
)

product_doc_names=(
  "01 - Product Overview and API Map"
  "02 - Product Onboarding and First Call"
  "03 - Consent and Compliance Matrix"
  "04 - Commercial Plans Rate Limits and SLA"
  "05 - Sandbox Postman and SDK Toolkit"
)

publisher_apis="$(
  curl -ksS \
    -H "Authorization: Bearer ${publisher_token}" \
    -H 'Accept: application/json' \
    "${APIM_URL}/api/am/publisher/v4/apis?limit=1000"
)"

failures=0

for api_name in "${api_names[@]}"; do
  api_id="$(
    jq -r --arg name "$api_name" \
      'first(.list[]? | select(.name == $name and (.version // "1.0.0") == "1.0.0") | .id) // empty' \
      <<<"$publisher_apis"
  )"

  if [[ -z "$api_id" ]]; then
    echo "[verify-developer-experience] MISSING API: ${api_name}:1.0.0" >&2
    failures=$((failures + 1))
    continue
  fi

  api_detail="$(
    curl -ksS \
      -H "Authorization: Bearer ${publisher_token}" \
      -H 'Accept: application/json' \
      "${APIM_URL}/api/am/publisher/v4/apis/${api_id}"
  )"

  case "$api_name" in
    OpenGatewayNumberVerificationAPI|OpenGatewaySimSwapRiskAPI|OpenGatewayDeviceLocationVerificationAPI|SecureTransactionRiskAssessmentAPI)
      required_plans="TelcoFreeTrial TelcoOpenGatewayTrustStarter TelcoOpenGatewayTrustPremium Unlimited"
      ;;
    TelcoBusinessCatalogAPI|Customer360API|NumberLifecycleAPI)
      required_plans="TelcoFreeTrial TelcoPartnerStandard TelcoPartnerPremium Unlimited"
      ;;
    NetworkSliceAPI|PartnerChargingAPI)
      required_plans="TelcoPartnerStandard TelcoPartnerPremium Unlimited"
      ;;
    BillingAdjustmentSOAP|BillingAdjustmentModernizationAPI)
      required_plans="TelcoFreeTrial TelcoPartnerStandard Unlimited"
      ;;
    NetworkEventsStreamAPI)
      required_plans="TelcoFreeTrial TelcoEventStreamPremium Unlimited"
      ;;
    *)
      required_plans="Unlimited"
      ;;
  esac

  for required_plan in $required_plans; do
    if ! jq -e --arg plan "$required_plan"       '((.policies // []) | index($plan)) != null'       <<<"$api_detail" >/dev/null; then
      echo "[verify-developer-experience] MISSING API PLAN: ${api_name} -> ${required_plan}" >&2
      failures=$((failures + 1))
    fi
  done

  docs="$(
    curl -ksS \
      -H "Authorization: Bearer ${publisher_token}" \
      -H 'Accept: application/json' \
      "${APIM_URL}/api/am/publisher/v4/apis/${api_id}/documents?limit=100"
  )"

  for required_doc in "${api_doc_names[@]}"; do
    if ! jq -e --arg name "$required_doc" \
      'any(.list[]?; .name == $name)' <<<"$docs" >/dev/null; then
      echo "[verify-developer-experience] MISSING API DOC: ${api_name} -> ${required_doc}" >&2
      failures=$((failures + 1))
    fi
  done

  echo "[verify-developer-experience] API OK: ${api_name}"
done

publisher_products="$(
  curl -ksS \
    -H "Authorization: Bearer ${publisher_token}" \
    -H 'Accept: application/json' \
    "${APIM_URL}/api/am/publisher/v4/api-products?limit=1000"
)"

product_ids="$(
  jq -r '.list[]? | [.id, .name] | @tsv' <<<"$publisher_products"
)"

product_count=0
while IFS=$'\t' read -r product_id product_name; do
  [[ -n "$product_id" ]] || continue

  case "$product_name" in
    OpenGatewayFraudDefenseProduct|DigitalCustomerBSSExperienceProduct|FiveGNetworkMonetizationProduct)
      ;;
    *)
      continue
      ;;
  esac

  product_count=$((product_count + 1))
  detail="$(
    curl -ksS \
      -H "Authorization: Bearer ${publisher_token}" \
      -H 'Accept: application/json' \
      "${APIM_URL}/api/am/publisher/v4/api-products/${product_id}"
  )"

  state="$(jq -r '(.state // .lifeCycleStatus // .status // "") | ascii_upcase' <<<"$detail")"
  if [[ "$state" != "PUBLISHED" ]]; then
    echo "[verify-developer-experience] PRODUCT NOT PUBLISHED: ${product_name} (${state:-unknown})" >&2
    failures=$((failures + 1))
  fi

  case "$product_name" in
    OpenGatewayFraudDefenseProduct)
      required_product_plans="TelcoOpenGatewayTrustStarter TelcoOpenGatewayTrustPremium Unlimited"
      ;;
    DigitalCustomerBSSExperienceProduct)
      required_product_plans="TelcoPartnerStandard TelcoPartnerPremium Unlimited"
      ;;
    FiveGNetworkMonetizationProduct)
      required_product_plans="TelcoPartnerPremium TelcoEventStreamPremium Unlimited"
      ;;
  esac

  for required_plan in $required_product_plans; do
    if ! jq -e --arg plan "$required_plan"       '((.policies // []) | index($plan)) != null'       <<<"$detail" >/dev/null; then
      echo "[verify-developer-experience] MISSING PRODUCT PLAN: ${product_name} -> ${required_plan}" >&2
      failures=$((failures + 1))
    fi
  done

  docs="$(
    curl -ksS \
      -H "Authorization: Bearer ${publisher_token}" \
      -H 'Accept: application/json' \
      "${APIM_URL}/api/am/publisher/v4/api-products/${product_id}/documents?limit=100"
  )"

  for required_doc in "${product_doc_names[@]}"; do
    if ! jq -e --arg name "$required_doc" \
      'any(.list[]?; .name == $name)' <<<"$docs" >/dev/null; then
      echo "[verify-developer-experience] MISSING PRODUCT DOC: ${product_name} -> ${required_doc}" >&2
      failures=$((failures + 1))
    fi
  done

  echo "[verify-developer-experience] API PRODUCT OK: ${product_name}"
done <<<"$product_ids"

if (( product_count != 3 )); then
  echo "[verify-developer-experience] Expected 3 native API Products, found ${product_count}." >&2
  failures=$((failures + 1))
fi

catalog_token_response="$(
  curl -ksS \
    -u "${client_id}:${client_secret}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${APIM_USER}" \
    --data-urlencode "password=${APIM_PASSWORD}" \
    --data-urlencode 'scope=service_catalog:service_view service_catalog:service_write' \
    "${APIM_URL}/oauth2/token"
)"
catalog_token="$(jq -r '.access_token // empty' <<<"$catalog_token_response")"

if [[ -z "$catalog_token" ]]; then
  echo "[verify-developer-experience] ERROR: Service Catalog token request failed." >&2
  failures=$((failures + 1))
else
  catalog="$(
    curl -ksS \
      -H "Authorization: Bearer ${catalog_token}" \
      -H 'Accept: application/json' \
      "${APIM_URL}/api/am/service-catalog/v1/services?limit=1000"
  )"

  catalog_services=(
    SecureTransactionRiskAssessmentAPI
    CrmRiskAdapterAPI
    SimSwapRiskAdapterAPI
    DeviceLocationRiskAdapterAPI
    OssRiskAdapterAPI
    BillingAdjustmentModernizationAPI
    LegacyBillingAdjustmentSOAPService
  )

  for service_name in "${catalog_services[@]}"; do
    if ! jq -e --arg name "$service_name" \
      'any(.list[]?; .name == $name and .version == "1.0.0")' \
      <<<"$catalog" >/dev/null; then
      echo "[verify-developer-experience] MISSING SERVICE CATALOG ENTRY: ${service_name}:1.0.0" >&2
      failures=$((failures + 1))
    else
      echo "[verify-developer-experience] SERVICE CATALOG OK: ${service_name}"
    fi
  done
fi

if (( failures > 0 )); then
  echo "[verify-developer-experience] FAILED with ${failures} issue(s)." >&2
  exit 1
fi

echo "[verify-developer-experience] PASS: documentation, products, plans and Service Catalog entries are complete."
SH
chmod +x scripts/verify-developer-experience.sh

cat > scripts/verify-mi-resilience-config.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

endpoint_dir="services/wso2-mi/src/main/wso2mi/artifacts/endpoints"
sequence_dir="services/wso2-mi/src/main/wso2mi/artifacts/sequences"

if [[ ! -d "$endpoint_dir" || ! -d "$sequence_dir" ]]; then
  echo "[verify-mi-resilience] ERROR: run from the repository root." >&2
  exit 1
fi

endpoint_files=(
  CrmLegacyFailoverEndpoint.xml
  SimSwapFailoverEndpoint.xml
  DeviceLocationFailoverEndpoint.xml
  OssLegacyFailoverEndpoint.xml
  LegacyBillingSoapFailoverEndpoint.xml
)

required_endpoint_patterns=(
  '<failover'
  '<timeout>'
  '<responseAction>fault</responseAction>'
  '<suspendOnFailure>'
  '<initialDuration>'
  '<progressionFactor>'
  '<maximumDuration>'
  '<markForSuspension>'
)

failures=0

for file_name in "${endpoint_files[@]}"; do
  file="${endpoint_dir}/${file_name}"
  if [[ ! -f "$file" ]]; then
    echo "[verify-mi-resilience] MISSING ENDPOINT: $file" >&2
    failures=$((failures + 1))
    continue
  fi

  for pattern in "${required_endpoint_patterns[@]}"; do
    if ! grep -Fq "$pattern" "$file"; then
      echo "[verify-mi-resilience] MISSING '${pattern}' in ${file_name}" >&2
      failures=$((failures + 1))
    fi
  done

  echo "[verify-mi-resilience] ENDPOINT OK: ${file_name}"
done

sequence_checks=(
  "InitializeCorrelationSequence.xml:X-Correlation-ID"
  "RiskAssessmentFaultSequence.xml:HTTP_SC"
  "RiskAdapterFallbackSequence.xml:partial"
  "BillingModernizationTransportFaultSequence.xml:HTTP_SC"
  "BillingModernizationSoapFaultSequence.xml:HTTP_SC"
)

for check in "${sequence_checks[@]}"; do
  file_name="${check%%:*}"
  pattern="${check#*:}"
  file="${sequence_dir}/${file_name}"

  if [[ ! -f "$file" ]]; then
    echo "[verify-mi-resilience] MISSING SEQUENCE: $file" >&2
    failures=$((failures + 1))
    continue
  fi

  if ! grep -Fqi "$pattern" "$file"; then
    echo "[verify-mi-resilience] MISSING '${pattern}' in ${file_name}" >&2
    failures=$((failures + 1))
  else
    echo "[verify-mi-resilience] SEQUENCE OK: ${file_name}"
  fi
done

if (( failures > 0 )); then
  echo "[verify-mi-resilience] FAILED with ${failures} issue(s)." >&2
  exit 1
fi

echo "[verify-mi-resilience] PASS: MI failover, timeout, endpoint suspension/circuit breaking, correlation and fault handling are present."
SH
chmod +x scripts/verify-mi-resilience-config.sh

cat > docs/developer-portal/README.md <<'MD'
# Telco Developer Portal Enablement

This implementation makes Developer Portal onboarding part of the automated APIM bootstrap.

## Generated for every demo API

1. Business overview
2. Contract and CAMARA alignment
3. Authentication and first-call guide
4. Consent and privacy requirements
5. Error catalogue
6. Rate limits and commercial plans
7. SLA, support and resilience
8. Code samples, Postman and generated SDK guidance
9. Sandbox test data

## Generated for every native API Product

1. Product overview and API map
2. Product onboarding and first call
3. Consent and compliance matrix
4. Commercial plans, rate limits and SLA
5. Sandbox, Postman and SDK toolkit

## Runtime behavior

- The bootstrap enriches API and API Product metadata through Publisher REST API v4.
- It assigns Bronze, Silver, Gold and Unlimited subscription policies.
- It creates or updates Markdown documentation idempotently.
- It deploys and publishes native API Products for Developer Portal visibility.
- APIM is configured to allow API document visibility and multiple generated SDK languages.
- The existing MI Service Catalog scripts remain authoritative for MI service registration.
- Existing MI endpoint failover, timeout and suspension settings are validated as the circuit-breaking implementation.

## Validation

Run:

```bash
./scripts/verify-mi-resilience-config.sh
./scripts/run-with-mi-risk.sh
./scripts/verify-developer-experience.sh
```

`run-with-mi-risk.sh` starts the complete APIM + MI topology, registers both MI
Service Catalog groups, and runs the APIM bootstrapper. The two registration
scripts remain independently rerunnable for troubleshooting.
MD

echo
echo "[developer-experience-install] Installation files created."
echo "[developer-experience-install] Next commands:"
echo "  ./scripts/verify-mi-resilience-config.sh"
echo "  ./scripts/run-with-mi-risk.sh"
echo "  ./scripts/verify-developer-experience.sh"
echo
echo "[developer-experience-install] The full MI runner already rebuilds/starts APIM and MI,"
echo "[developer-experience-install] registers both Service Catalog groups, and reruns the APIM bootstrapper."
