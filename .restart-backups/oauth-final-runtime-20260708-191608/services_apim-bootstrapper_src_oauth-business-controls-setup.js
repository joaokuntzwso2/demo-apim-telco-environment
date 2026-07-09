'use strict';

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const fs = require('node:fs');
const path = require('node:path');
const { fetch, FormData, Agent } = require('undici');

const dispatcher = new Agent({ connect: { rejectUnauthorized: false } });
const APIM_URL = (process.env.WSO2_APIM_URL || 'https://wso2-apim:9443').replace(/\/$/, '');
const MI_URL = (process.env.WSO2_MI_URL || 'http://wso2-mi:8290').replace(/\/$/, '');
const USER = process.env.APIM_USERNAME || 'admin';
const PASSWORD = process.env.APIM_PASSWORD || 'admin';
const API_NAME = 'SubscriberAuthorizationControlAPI';
const API_VERSION = '1.0.0';
const API_CONTEXT = '/subscriber-authorization/v1';
const CONTRACT = '/workspace/contracts/openapi/subscriber-authorization-control.openapi.yaml';
const STATE_FILE = '/workspace/state/oauth-business-controls.json';
const MARKER = 'oauth-consent-risk-controls-v1';

const PERSONAS = [
  {
    username: 'partner.alpha',
    password: 'PartnerAlpha#2026',
    role: 'telco_partner',
    persona: 'partner',
    partnerId: 'partner-alpha',
    country: 'BR'
  },
  {
    username: 'partner.beta',
    password: 'PartnerBeta#2026',
    role: 'telco_partner',
    persona: 'partner',
    partnerId: 'partner-beta',
    country: 'MX'
  },
  {
    username: 'telco.operations',
    password: 'TelcoOperations#2026',
    role: 'telco_operations',
    persona: 'operations',
    partnerId: '*',
    country: '*'
  },
  {
    username: 'telco.product',
    password: 'TelcoProduct#2026',
    role: 'telco_product_manager',
    persona: 'product_manager',
    partnerId: '*',
    country: '*'
  },
  {
    username: 'telco.admin',
    password: 'TelcoAdmin#2026',
    role: 'telco_platform_admin',
    persona: 'platform_administrator',
    partnerId: '*',
    country: '*'
  }
];

const SCOPES = [
  {
    name: 'Number Verification Read',
    key: 'number-verification:read',
    description: 'Read consented number-verification outcomes.',
    roles: ['telco_partner', 'telco_operations', 'telco_platform_admin']
  },
  {
    name: 'SIM Swap Read',
    key: 'sim-swap:read',
    description: 'Read consented SIM-swap risk.',
    roles: ['telco_partner', 'telco_operations', 'telco_platform_admin']
  },
  {
    name: 'Device Location Verify',
    key: 'device-location:verify',
    description: 'Verify device location for an approved purpose.',
    roles: ['telco_partner', 'telco_operations', 'telco_platform_admin']
  },
  {
    name: 'Quality on Demand Request',
    key: 'qod:request',
    description: 'Request a purpose-bound Quality-on-Demand session.',
    roles: ['telco_partner', 'telco_operations', 'telco_platform_admin']
  },
  {
    name: 'Commercial Usage Read',
    key: 'commercial-usage:read',
    description: 'Read usage and plan information for an authorized partner.',
    roles: [
      'telco_partner',
      'telco_operations',
      'telco_product_manager',
      'telco_platform_admin'
    ]
  }
];

const OPERATIONS = [
  ['GET', '/health', 'None', []],
  ['POST', '/number-verifications', 'Application & Application User', ['number-verification:read']],
  ['POST', '/sim-swap-checks', 'Application & Application User', ['sim-swap:read']],
  ['POST', '/device-location-verifications', 'Application & Application User', ['device-location:verify']],
  ['POST', '/qod-requests', 'Application & Application User', ['qod:request']],
  ['GET', '/partners/{partnerId}/commercial-usage', 'Application & Application User', ['commercial-usage:read']]
].map(([verb, target, authType, scopes]) => ({
  target,
  verb,
  authType,
  throttlingPolicy: 'Unlimited',
  scopes
}));

function log(message) {
  console.log(`[oauth-business-controls] ${message}`);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function request(url, options = {}, accepted = [200, 201, 202, 204]) {
  const response = await fetch(url, { dispatcher, ...options });
  const text = await response.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }
  if (!accepted.includes(response.status)) {
    throw new Error(`${options.method || 'GET'} ${url} -> HTTP ${response.status}: ${text.slice(0, 3000)}`);
  }
  return { status: response.status, data, headers: response.headers };
}

function basic(value) {
  return `Basic ${Buffer.from(value).toString('base64')}`;
}

function bearer(token, extra = {}) {
  return { authorization: `Bearer ${token}`, accept: 'application/json', ...extra };
}

async function waitForApim() {
  for (let attempt = 1; attempt <= 180; attempt += 1) {
    try {
      const response = await fetch(`${APIM_URL}/services/Version`, { dispatcher });
      if (response.ok) return;
    } catch {
      // APIM is starting.
    }
    await sleep(2000);
  }
  throw new Error(`APIM did not become ready at ${APIM_URL}`);
}

async function dcrClient(name) {
  const response = await request(`${APIM_URL}/client-registration/v0.17/register`, {
    method: 'POST',
    headers: {
      authorization: basic(`${USER}:${PASSWORD}`),
      'content-type': 'application/json'
    },
    body: JSON.stringify({
      callbackUrl: 'http://localhost:8080/callback',
      clientName: `${name}-${Date.now()}-${Math.random().toString(16).slice(2)}`,
      owner: USER,
      grantType: 'password refresh_token client_credentials',
      saasApp: true
    })
  });
  if (!response.data?.clientId || !response.data?.clientSecret) {
    throw new Error(`DCR response did not include credentials: ${JSON.stringify(response.data)}`);
  }
  return response.data;
}

async function managementToken(scopes) {
  const client = await dcrClient('oauth-business-controls-bootstrap');
  const form = new URLSearchParams({
    grant_type: 'password',
    username: USER,
    password: PASSWORD,
    scope: scopes
  });
  const response = await request(`${APIM_URL}/oauth2/token`, {
    method: 'POST',
    headers: {
      authorization: basic(`${client.clientId}:${client.clientSecret}`),
      'content-type': 'application/x-www-form-urlencoded'
    },
    body: form
  });
  if (!response.data?.access_token) {
    throw new Error(`Management token response missing access_token: ${JSON.stringify(response.data)}`);
  }
  return response.data.access_token;
}

/* oauth-api-idempotency-v2 */
async function listAndFindApi(token) {
  function normalizeContext(value) {
    const normalized = String(value || '').trim();

    if (normalized.length > 1) {
      return normalized.replace(/\/+$/, '');
    }

    return normalized;
  }

  function isTarget(candidate) {
    return (
      candidate &&
      candidate.name === API_NAME &&
      String(candidate.version || '') === API_VERSION
    );
  }

  async function readFullApi(id) {
    if (!id) return null;

    try {
      const response = await request(
        `${APIM_URL}/api/am/publisher/v4/apis/${encodeURIComponent(id)}`,
        {
          headers: bearer(token)
        }
      );

      return response.data || null;
    } catch (error) {
      log(
        `Could not read Publisher API ${id}; continuing discovery: ` +
        `${error.message || error}`
      );

      return null;
    }
  }

  /*
   * First reuse the API ID written by an earlier successful OAuth bootstrap.
   * This avoids relying on Publisher search indexing during repeated starts.
   */
  if (fs.existsSync(STATE_FILE)) {
    try {
      const state = JSON.parse(
        fs.readFileSync(STATE_FILE, 'utf8')
      );

      const storedId =
        state?.api?.id ||
        state?.apiId ||
        null;

      if (storedId) {
        const storedApi = await readFullApi(storedId);

        if (isTarget(storedApi)) {
          log(
            `Resolved existing ${API_NAME}:${API_VERSION} ` +
            `from bootstrap state: ${storedApi.id}`
          );

          return storedApi;
        }
      }
    } catch (error) {
      log(
        `Bootstrap state could not be reused; ` +
        `falling back to Publisher discovery: ${error.message || error}`
      );
    }
  }

  /*
   * WSO2 Publisher search can temporarily omit an existing API or interpret
   * query expressions differently across API-M releases. Try targeted
   * searches first, followed by an authoritative unfiltered traversal.
   */
  const searches = [
    `name:${API_NAME}`,
    API_NAME,
    `context:${API_CONTEXT}`,
    API_CONTEXT,
    ''
  ];

  const seenIds = new Set();
  let nameVersionFallback = null;

  for (const search of searches) {
    let offset = 0;

    for (let page = 0; page < 50; page += 1) {
      const queryPart = search
        ? `&query=${encodeURIComponent(search)}`
        : '';

      let response;

      try {
        response = await request(
          `${APIM_URL}/api/am/publisher/v4/apis` +
            `?limit=100&offset=${offset}${queryPart}`,
          {
            headers: bearer(token)
          }
        );
      } catch (error) {
        log(
          `Publisher lookup '${search || '<unfiltered>'}' failed ` +
          `non-fatally: ${error.message || error}`
        );

        break;
      }

      const summaries =
        response.data?.list ||
        response.data?.data ||
        response.data ||
        [];

      if (!Array.isArray(summaries)) {
        break;
      }

      for (const summary of summaries) {
        if (!summary?.id || seenIds.has(summary.id)) {
          continue;
        }

        seenIds.add(summary.id);

        const candidate =
          (await readFullApi(summary.id)) ||
          summary;

        if (!isTarget(candidate)) {
          continue;
        }

        if (
          normalizeContext(candidate.context) ===
          normalizeContext(API_CONTEXT)
        ) {
          log(
            `Resolved existing ${API_NAME}:${API_VERSION} ` +
            `by Publisher discovery: ${candidate.id}`
          );

          return candidate;
        }

        /*
         * APIM uniqueness is primarily based on API identity. Preserve a
         * same-name/version result as a fallback instead of attempting a POST
         * that will necessarily return 409.
         */
        nameVersionFallback ||= candidate;
      }

      if (summaries.length < 100) {
        break;
      }

      offset += summaries.length;
    }
  }

  if (nameVersionFallback) {
    log(
      `Resolved ${API_NAME}:${API_VERSION} by name/version with context ` +
      `'${nameVersionFallback.context || '<empty>'}'. ` +
      `The existing API will be reconciled instead of recreated.`
    );

    return nameVersionFallback;
  }

  return null;
}

function apiPayload(existing = {}) {
  const additionalProperties = [
    { name: 'SecurityControlModel', value: MARKER, display: true },
    { name: 'AuthorizationLayers', value: 'OAuth scope,persona,consent,purpose,country,partner isolation,masking', display: true },
    { name: 'IdentityContext', value: 'APIM gateway-issued backend JWT', display: true },
    { name: 'ConsentRegistry', value: 'MI demo registry; replace with enterprise consent store for production', display: true },
    { name: 'PartialResponse', value: 'Existing SecureTransactionRiskAssessmentAPI', display: true },
    { name: 'ServiceOwner', value: 'Telco API Platform Security', display: true }
  ];
  return {
    ...existing,
    name: API_NAME,
    context: API_CONTEXT,
    version: API_VERSION,
    provider: existing.provider || USER,
    description:
      'Business authorization facade managed by WSO2 Integrator: MI. WSO2 API Manager enforces role-bound OAuth scopes; MI enforces persona, purpose, consent, country, partner isolation, subscriber masking, correlation and downstream resilience.',
    type: 'HTTP',
    transport: ['http', 'https'],
    tags: ['telco', 'oauth', 'consent', 'authorization', 'risk', 'mi'],
    policies: ['TelcoConsentRiskPartner', 'TelcoConsentRiskOperations', 'Unlimited'],
    apiThrottlingPolicy: 'Unlimited',
    authorizationHeader: 'Authorization',
    securityScheme: ['oauth2'],
    visibility: 'PUBLIC',
    subscriptionAvailability: 'ALL_TENANTS',
    isRevision: false,
    enableSchemaValidation: true,
    endpointConfig: {
      endpoint_type: 'http',
      sandbox_endpoints: { url: `${MI_URL}/subscriber-authorization/v1` },
      production_endpoints: { url: `${MI_URL}/subscriber-authorization/v1` }
    },
    scopes: SCOPES.map(scopeDefinition => ({
      scope: {
        name: scopeDefinition.key,
        displayName: scopeDefinition.name,
        description: scopeDefinition.description,
        bindings: scopeDefinition.roles
      },
      shared: false
    })),
    operations: OPERATIONS,
    additionalProperties,
    businessInformation: {
      businessOwner: 'Telco Digital Trust Product Office',
      businessOwnerEmail: 'api-platform@example.invalid',
      technicalOwner: 'Telco API Platform Security',
      technicalOwnerEmail: 'api-platform@example.invalid'
    }
  };
}

async function upsertApi(token) {
  let api = await listAndFindApi(token);
  let changed = false;
  let createdNow = false;

  if (!api) {
    try {
      const created = await request(
        `${APIM_URL}/api/am/publisher/v4/apis`,
        {
          method: 'POST',
          headers: bearer(
            token,
            {
              'content-type': 'application/json'
            }
          ),
          body: JSON.stringify(apiPayload())
        }
      );

      api = created.data;
      changed = true;
      createdNow = true;

      log(`Created API ${api.id}`);
    } catch (error) {
      const message = String(
        error?.message ||
        error ||
        ''
      );

      const duplicate =
        message.includes('HTTP 409') ||
        message.includes('"code":900300') ||
        message.includes('The API already exists');

      if (!duplicate) {
        throw error;
      }

      log(
        `${API_NAME}:${API_VERSION} already exists in APIM; ` +
        `recovering the existing API instead of failing.`
      );

      for (
        let attempt = 1;
        attempt <= 20 && !api;
        attempt += 1
      ) {
        await sleep(500);
        api = await listAndFindApi(token);
      }

      if (!api?.id) {
        throw new Error(
          `APIM reported that ${API_NAME}:${API_VERSION} already exists, ` +
          `but it could not be resolved by stored ID, name, context, or ` +
          `unfiltered Publisher pagination. Original error: ${message}`
        );
      }

      log(
        `Recovered existing API ${api.id} after create returned HTTP 409.`
      );
    }
  }

  const currentMarker =
    (api?.additionalProperties || [])
      .find(
        item =>
          item.name === 'SecurityControlModel'
      )
      ?.value;

  const currentScopeKeys = new Set(
    (api?.scopes || [])
      .map(scope => scope.key)
      .filter(Boolean)
  );

  const completeScopes = SCOPES.every(
    scope =>
      currentScopeKeys.has(scope.key)
  );

  const currentPolicies = new Set(
    Array.isArray(api?.policies)
      ? api.policies
      : []
  );

  const completePolicies = [
    'TelcoConsentRiskPartner',
    'TelcoConsentRiskOperations',
    'Unlimited'
  ].every(
    policy =>
      currentPolicies.has(policy)
  );

  const normalizedCurrentContext =
    String(api?.context || '')
      .replace(/\/+$/, '');

  const normalizedDesiredContext =
    String(API_CONTEXT)
      .replace(/\/+$/, '');

  const needsReconciliation =
    !createdNow &&
    (
      currentMarker !== MARKER ||
      !completeScopes ||
      !completePolicies ||
      normalizedCurrentContext !== normalizedDesiredContext ||
      String(api?.visibility || '').toUpperCase() !== 'PUBLIC'
    );

  if (needsReconciliation) {
    const updated = await request(
      `${APIM_URL}/api/am/publisher/v4/apis/${encodeURIComponent(api.id)}`,
      {
        method: 'PUT',
        headers: bearer(
          token,
          {
            'content-type': 'application/json'
          }
        ),
        body: JSON.stringify(apiPayload(api))
      }
    );

    api = updated.data || api;
    changed = true;

    log(
      `Reconciled existing API ${api.id} with the desired ` +
      `OAuth business-control configuration.`
    );
  } else if (!createdNow) {
    log(
      `API ${api.id} already carries ${MARKER}; ` +
      `the existing API will be reused.`
    );
  }

  const definition = fs.readFileSync(
    CONTRACT,
    'utf8'
  );

  const form = new FormData();
  form.set('apiDefinition', definition);

  await request(
    `${APIM_URL}/api/am/publisher/v4/apis/${encodeURIComponent(api.id)}/swagger`,
    {
      method: 'PUT',
      headers: bearer(token),
      body: form
    },
    [200]
  );

  log('Updated managed OpenAPI definition');

  /* OAUTH API DEPLOYMENT CONVERGENCE */

  /*
   * Do not create a revision merely because bootstrap ran again.
   * Create and deploy one only when the API has no current deployment.
   */
  const deploymentsResult = await request(
    `${APIM_URL}/api/am/publisher/v4/apis/${encodeURIComponent(api.id)}/deployments`,
    {
      headers: bearer(token)
    }
  );

  const deployments =
    deploymentsResult.data?.list ||
    deploymentsResult.data ||
    [];

  if (
    !Array.isArray(deployments) ||
    deployments.length === 0
  ) {
    const revision = await request(
      `${APIM_URL}/api/am/publisher/v4/apis/${encodeURIComponent(api.id)}/revisions`,
      {
        method: 'POST',
        headers: bearer(
          token,
          {
            'content-type': 'application/json'
          }
        ),
        body: JSON.stringify({
          description:
            'OAuth scopes, roles, consent and risk-based authorization'
        })
      }
    );

    await request(
      `${APIM_URL}/api/am/publisher/v4/apis/${encodeURIComponent(api.id)}` +
        `/deploy-revision?revisionId=${encodeURIComponent(revision.data.id)}`,
      {
        method: 'POST',
        headers: bearer(
          token,
          {
            'content-type': 'application/json'
          }
        ),
        body: JSON.stringify([
          {
            name: 'Default',
            vhost: 'localhost',
            displayOnDevportal: true
          }
        ])
      }
    );

    log(`Deployed revision ${revision.data.id}`);
  } else {
    log(
      `API already has ${deployments.length} deployment(s); ` +
      `preserving the currently deployed revision.`
    );
  }

  const refreshed = await request(
    `${APIM_URL}/api/am/publisher/v4/apis/${encodeURIComponent(api.id)}`,
    {
      headers: bearer(token)
    }
  );

  api = refreshed.data || api;

  if (
    String(
      api?.lifeCycleStatus ||
      ''
    ).toUpperCase() !== 'PUBLISHED'
  ) {
    await request(
      `${APIM_URL}/api/am/publisher/v4/apis/change-lifecycle` +
        `?action=Publish&apiId=${encodeURIComponent(api.id)}`,
      {
        method: 'POST',
        headers: bearer(token)
      },
      [200, 201]
    );

    log('Published API');
  } else {
    log('API is already PUBLISHED');
  }

  return api;
}

async function upsertDocument(token, apiId, document) {
  const base = `${APIM_URL}/api/am/publisher/v4/apis/${apiId}/documents`;
  const current = await request(`${base}?limit=100`, { headers: bearer(token) });
  const list = current.data?.list || [];
  let metadata = list.find(item => item.name === document.name);
  const payload = {
    name: document.name,
    summary: document.summary,
    type: 'HOWTO',
    sourceType: 'MARKDOWN',
    visibility: 'API_LEVEL'
  };
  if (metadata?.documentId || metadata?.id) {
    const id = metadata.documentId || metadata.id;
    metadata = (
      await request(`${base}/${encodeURIComponent(id)}`, {
        method: 'PUT',
        headers: bearer(token, { 'content-type': 'application/json' }),
        body: JSON.stringify(payload)
      })
    ).data;
  } else {
    metadata = (
      await request(base, {
        method: 'POST',
        headers: bearer(token, { 'content-type': 'application/json' }),
        body: JSON.stringify(payload)
      })
    ).data;
  }
  const id = metadata?.documentId || metadata?.id;
  if (!id) throw new Error(`Document ID missing for ${document.name}`);
  const form = new FormData();
  form.append('inlineContent', document.content);
  await request(`${base}/${encodeURIComponent(id)}/content`, {
    method: 'POST',
    headers: bearer(token),
    body: form
  });
  log(`Upserted document ${document.name}`);
}

async function ensureDocuments(token, api) {
  const documents = [
    {
      name: '10 - OAuth Scopes and Personas',
      summary: 'Role-bound scope matrix for partners and operator personas.',
      content: `# OAuth scopes and personas

| Scope | Partner | Operations | Product manager | Platform administrator |
|---|---:|---:|---:|---:|
| \`number-verification:read\` | Yes | Yes | No | Yes |
| \`sim-swap:read\` | Yes | Yes | No | Yes |
| \`device-location:verify\` | Yes | Yes | No | Yes |
| \`qod:request\` | Yes | Yes | No | Yes |
| \`commercial-usage:read\` | Own partner only | Yes | Yes | Yes |

WSO2 API Manager rejects a request before MI when the token does not carry the operation scope. MI receives a gateway-issued backend JWT and derives the authenticated persona and partner identity from its subject.`
    },
    {
      name: '11 - Consent Purpose Country and Partner Isolation',
      summary: 'Subscriber-data business controls and sandbox consent records.',
      content: `# Consent, purpose, country and partner isolation

Subscriber-related calls require \`partnerId\`, \`country\`, \`subscriberNumber\`, \`purpose\` and \`consentId\`.

Sandbox records:

- \`CONSENT-ALPHA-001\`: partner-alpha, BR, +5511999990001
- \`CONSENT-BETA-001\`: partner-beta, MX, +525512340001

The MI policy rejects an unauthorized country, consent/subject mismatch, unsupported purpose and cross-partner access. Partner responses always mask the subscriber number. Operations or platform administrators may request full data only for \`fraud-investigation\` with \`X-Data-Access: FULL\`.`
    },
    {
      name: '12 - Security Error and Verification Catalogue',
      summary: 'Expected OAuth and business-control rejection behavior.',
      content: `# Security error catalogue

- APIM 401: invalid or expired token
- APIM 403: required operation scope missing
- MI 401 \`AUTHENTICATED_SUBJECT_REQUIRED\`: backend JWT context absent
- MI 403 \`PERSONA_NOT_AUTHORIZED\`
- MI 403 \`PERSONA_CAPABILITY_FORBIDDEN\`
- MI 403 \`COUNTRY_NOT_AUTHORIZED\`
- MI 403 \`PARTNER_DATA_ISOLATION\`
- MI 403 \`CONSENT_OR_PURPOSE_REQUIRED\`
- MI 403 \`CONSENT_SUBJECT_MISMATCH\`
- MI 403 \`PURPOSE_NOT_PERMITTED\`
- MI 503 \`DOWNSTREAM_CONTROL_UNAVAILABLE\`

All MI responses return \`X-Correlation-ID\` and a normalized JSON body. The repository verification script executes the valid-scope, missing-scope, expired-token, unauthorized-country, cross-partner and masking scenarios.`
    }
  ];
  for (const document of documents) {
    await upsertDocument(token, api.id, document);
  }
}

const USER_STORE_SOAP_URL =
  `${APIM_URL}/services/RemoteUserStoreManagerService.RemoteUserStoreManagerServiceHttpsSoap11Endpoint/`;

function xmlEscape(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
}

function soapEnvelope(operation, body = '') {
  return `<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
                  xmlns:ser="http://service.ws.um.carbon.wso2.org"
                  xmlns:xsd="http://common.mgt.user.carbon.wso2.org/xsd">
  <soapenv:Header/>
  <soapenv:Body>
    <ser:${operation}>${body}</ser:${operation}>
  </soapenv:Body>
</soapenv:Envelope>`;
}

async function adminSoap(operation, body = '', accepted = [200, 202]) {
  const response = await request(
    USER_STORE_SOAP_URL,
    {
      method: 'POST',
      headers: {
        authorization: basic(`${USER}:${PASSWORD}`),
        accept: 'text/xml, application/soap+xml',
        'content-type': 'text/xml; charset=UTF-8',
        soapaction: `"urn:${operation}"`
      },
      body: soapEnvelope(operation, body)
    },
    accepted
  );

  const xml = typeof response.data === 'string'
    ? response.data
    : JSON.stringify(response.data ?? '');

  if (/<(?:[A-Za-z_][\w.-]*:)?Fault(?:\s|>)/i.test(xml)) {
    throw new Error(`RemoteUserStoreManagerService ${operation} returned a SOAP fault: ${xml.slice(0, 3000)}`);
  }

  return xml;
}

function soapBoolean(xml) {
  const match = String(xml).match(
    /<(?:[A-Za-z_][\w.-]*:)?return(?:\s[^>]*)?>(true|false)<\/(?:[A-Za-z_][\w.-]*:)?return>/i
  );
  return match?.[1]?.toLowerCase() === 'true';
}

function soapStringValues(xml) {
  const values = [];
  const pattern = /<(?:[A-Za-z_][\w.-]*:)?return(?:\s[^>]*)?>([^<]*)<\/(?:[A-Za-z_][\w.-]*:)?return>/gi;
  for (const match of String(xml).matchAll(pattern)) {
    values.push(match[1]);
  }
  return values;
}

async function existingRoleName(roleName) {
  for (const candidate of [`Internal/${roleName}`, roleName]) {
    const xml = await adminSoap(
      'isExistingRole',
      `<ser:roleName>${xmlEscape(candidate)}</ser:roleName>`,
      [200]
    );
    if (soapBoolean(xml)) return candidate;
  }
  return null;
}

async function ensureRole(roleName) {
  let resolved = await existingRoleName(roleName);
  if (!resolved) {
    await adminSoap(
      'addRole',
      `<ser:roleName>${xmlEscape(roleName)}</ser:roleName>`
    );

    for (let attempt = 1; attempt <= 20 && !resolved; attempt += 1) {
      await sleep(250);
      resolved = await existingRoleName(roleName);
    }

    if (!resolved) {
      throw new Error(`Role ${roleName} was not visible after RemoteUserStoreManagerService.addRole`);
    }
    log(`Created internal role ${resolved}`);
  } else {
    log(`Internal role already exists: ${resolved}`);
  }

  return {
    requestedName: roleName,
    userStoreRole: resolved,
    scopeRole: resolved.startsWith('Internal/') ? resolved : `Internal/${resolved}`
  };
}

async function userExists(username) {
  const xml = await adminSoap(
    'isExistingUser',
    `<ser:userName>${xmlEscape(username)}</ser:userName>`,
    [200]
  );
  return soapBoolean(xml);
}

async function userRoles(username) {
  const xml = await adminSoap(
    'getRoleListOfUser',
    `<ser:userName>${xmlEscape(username)}</ser:userName>`,
    [200]
  );
  return soapStringValues(xml);
}

function normalizedRoleName(value) {
  return String(value || '').replace(/^Internal\//, '');
}

function userHasRole(roles, role) {
  const expected = new Set([
    role.userStoreRole,
    role.requestedName,
    role.scopeRole
  ].filter(Boolean).map(normalizedRoleName));
  return roles.some(item => expected.has(normalizedRoleName(item)));
}

async function ensureUserRole(username, role) {
  let roles = await userRoles(username);
  if (userHasRole(roles, role)) return roles;

  let lastError;
  const candidates = [...new Set([
    role.userStoreRole,
    role.requestedName,
    role.scopeRole
  ].filter(Boolean))];

  for (const candidate of candidates) {
    try {
      await adminSoap(
        'updateRoleListOfUser',
        `<ser:userName>${xmlEscape(username)}</ser:userName>` +
        `<ser:newRoles>${xmlEscape(candidate)}</ser:newRoles>`
      );

      for (let attempt = 1; attempt <= 20; attempt += 1) {
        await sleep(250);
        roles = await userRoles(username);
        if (userHasRole(roles, role)) return roles;
      }
    } catch (error) {
      lastError = error;
    }
  }

  throw lastError || new Error(
    `Role ${role.userStoreRole} was not assigned to ${username}; observed roles=${JSON.stringify(roles)}`
  );
}

async function matchingUsers(username) {
  const xml = await adminSoap(
    'listUsers',
    `<ser:filter>*${xmlEscape(username)}*</ser:filter>` +
    '<ser:maxItemLimit>100</ser:maxItemLimit>',
    [200]
  );
  return soapStringValues(xml);
}

async function authenticateUser(username, password) {
  const xml = await adminSoap(
    'authenticate',
    `<ser:userName>${xmlEscape(username)}</ser:userName>` +
    `<ser:credential>${xmlEscape(password)}</ser:credential>`,
    [200]
  );
  return soapBoolean(xml);
}

async function ensureUserPassword(username, password) {
  if (await authenticateUser(username, password)) return;

  await adminSoap(
    'updateCredentialByAdmin',
    `<ser:userName>${xmlEscape(username)}</ser:userName>` +
    `<ser:newCredential>${xmlEscape(password)}</ser:newCredential>`
  );

  for (let attempt = 1; attempt <= 20; attempt += 1) {
    await sleep(250);
    if (await authenticateUser(username, password)) return;
  }

  throw new Error(`Credential verification failed for ${username}`);
}

async function applyPersonaClaims(persona) {
  const claims = [
    ['http://wso2.org/claims/emailaddress', `${persona.username}@example.invalid`],
    ['http://wso2.org/claims/givenname', persona.persona],
    ['http://wso2.org/claims/lastname', persona.partnerId],
    ['http://wso2.org/claims/organization', persona.partnerId],
    ['http://wso2.org/claims/country', persona.country]
  ];

  for (const [claimURI, value] of claims) {
    try {
      await adminSoap(
        'setUserClaimValue',
        `<ser:userName>${xmlEscape(persona.username)}</ser:userName>` +
        `<ser:claimURI>${xmlEscape(claimURI)}</ser:claimURI>` +
        `<ser:claimValue>${xmlEscape(value)}</ser:claimValue>` +
        '<ser:profileName>default</ser:profileName>'
      );
    } catch (error) {
      // Claims enrich the demo identity but are not the authorization source of truth.
      // The APIM role and MI persona registry remain authoritative.
      log(`Claim ${claimURI} was not applied to ${persona.username}: ${error.message}`);
    }
  }
}

async function recreateUser(persona, role) {
  if (await userExists(persona.username)) {
    await adminSoap(
      'deleteUser',
      `<ser:userName>${xmlEscape(persona.username)}</ser:userName>`
    );

    for (let attempt = 1; attempt <= 40; attempt += 1) {
      if (!(await userExists(persona.username))) break;
      await sleep(250);
    }

    if (await userExists(persona.username)) {
      throw new Error(`Existing user ${persona.username} was not deleted before recreation`);
    }
  }

  // RemoteUserStoreManagerService.addUser is a one-way operation and is
  // sensitive to both element order and role/claim values. Create the
  // principal first using only required identity data, then assign the
  // resolved role and optional profile claims through separate operations.
  await adminSoap(
    'addUser',
    `<ser:userName>${xmlEscape(persona.username)}</ser:userName>` +
    `<ser:credential>${xmlEscape(persona.password)}</ser:credential>` +
    '<ser:profileName>default</ser:profileName>' +
    '<ser:requirePasswordChange>false</ser:requirePasswordChange>'
  );

  for (let attempt = 1; attempt <= 40; attempt += 1) {
    if (await userExists(persona.username)) break;
    await sleep(250);
  }

  if (!(await userExists(persona.username))) {
    const visible = await matchingUsers(persona.username).catch(() => []);
    throw new Error(
      `User ${persona.username} was not visible after minimal addUser; matching users=${JSON.stringify(visible)}`
    );
  }

  await ensureUserPassword(persona.username, persona.password);
  const roles = await ensureUserRole(persona.username, role);
  await applyPersonaClaims(persona);

  log(
    `Provisioned ${persona.username} as ${persona.persona} with user-store role ` +
    `${role.userStoreRole} and APIM scope role ${role.scopeRole}`
  );

  return {
    ...persona,
    role: role.scopeRole,
    userStoreRole: role.userStoreRole,
    roles,
    userId: persona.username,
    groupId: role.scopeRole
  };
}

async function ensurePersonas() {
  const roles = new Map();
  for (const roleName of [...new Set(PERSONAS.map(item => item.role))]) {
    roles.set(roleName, await ensureRole(roleName));
  }

  const users = [];
  for (const persona of PERSONAS) {
    users.push(await recreateUser(persona, roles.get(persona.role)));
  }
  return users;
}

async function waitForDevportalApi(
  base,
  devportalToken,
  publisherApi
) {
  const publisherApiId = publisherApi?.id;

  for (let attempt = 1; attempt <= 60; attempt += 1) {
    if (publisherApiId) {
      const direct = await request(
        `${base}/apis/${publisherApiId}`,
        {
          headers: bearer(devportalToken)
        },
        [200, 404]
      );

      if (
        direct.status === 200
        && (direct.data?.id || direct.data?.apiId)
      ) {
        log(
          `DevPortal API visible by publisher UUID `
          + `${publisherApiId} on attempt ${attempt}`
        );

        return direct.data;
      }
    }

    const result = await request(
      `${base}/apis?limit=1000&query=${encodeURIComponent(
        `name:${API_NAME}`
      )}`,
      {
        headers: bearer(devportalToken)
      }
    );

    const list =
      result.data?.list
      || result.data?.data
      || [];

    const target = list.find(
      item =>
        item.name === API_NAME
        && String(item.version) === API_VERSION
    );

    if (target?.id || target?.apiId) {
      log(
        `DevPortal API visible by search on attempt `
        + `${attempt}: ${target.id || target.apiId}`
      );

      return target;
    }

    log(
      `Waiting for ${API_NAME}:${API_VERSION} `
      + `to appear in DevPortal (${attempt}/60)`
    );

    await sleep(2000);
  }

  throw new Error(
    `${API_NAME}:${API_VERSION} remained absent from `
    + `the DevPortal API after publication`
  );
}

async function recreateDemoApplication(devportalToken, api) {
  const base = `${APIM_URL}/api/am/devportal/v3`;

  const targetApi = await waitForDevportalApi(
    base,
    devportalToken,
    api
  );

  const applications = await request(`${base}/applications?limit=100`, {
    headers: bearer(devportalToken)
  });
  for (const existing of applications.data?.list || []) {
    if (['Telco OAuth Business Controls Demo', 'Telco OAuth Operations Controls Demo', 'Telco OAuth Expired Token Demo'].includes(existing.name)) {
      await request(`${base}/applications/${existing.applicationId || existing.id}`, {
        method: 'DELETE',
        headers: bearer(devportalToken)
      });
    }
  }
  const application = (
    await request(`${base}/applications`, {
      method: 'POST',
      headers: bearer(devportalToken, { 'content-type': 'application/json' }),
      body: JSON.stringify({
        name: 'Telco OAuth Business Controls Demo',
        throttlingPolicy: 'Unlimited',
        description: 'Shared OAuth client for role/scope/consent business-control verification.',
        tokenType: 'JWT'
      })
    })
  ).data;

  await request(`${base}/subscriptions`, {
    method: 'POST',
    headers: bearer(devportalToken, { 'content-type': 'application/json' }),
    body: JSON.stringify({
      applicationId: application.applicationId,
      apiId: targetApi.id || targetApi.apiId,
      throttlingPolicy: 'TelcoConsentRiskPartner'
    })
  });

  const keys = (
    await request(`${base}/applications/${application.applicationId}/generate-keys`, {
      method: 'POST',
      headers: bearer(devportalToken, { 'content-type': 'application/json' }),
      body: JSON.stringify({
        keyType: 'PRODUCTION',
        grantTypesToBeSupported: ['password', 'refresh_token', 'client_credentials'],
        callbackUrl: 'http://localhost:8080/callback',
        validityTime: 3600,
        scopes: SCOPES.map(scope => scope.key)
      })
    })
  ).data;

  if (!keys?.consumerKey || !keys?.consumerSecret) {
    throw new Error(`Application key generation did not return consumer credentials: ${JSON.stringify(keys)}`);
  }

  const operationsApplication = (
    await request(`${base}/applications`, {
      method: 'POST',
      headers: bearer(devportalToken, { 'content-type': 'application/json' }),
      body: JSON.stringify({
        name: 'Telco OAuth Operations Controls Demo',
        throttlingPolicy: 'Unlimited',
        description: 'Internal operations/product/platform client using the TelcoConsentRiskOperations subscription plan.',
        tokenType: 'JWT'
      })
    })
  ).data;
  await request(`${base}/subscriptions`, {
    method: 'POST',
    headers: bearer(devportalToken, { 'content-type': 'application/json' }),
    body: JSON.stringify({
      applicationId: operationsApplication.applicationId,
      apiId: targetApi.id || targetApi.apiId,
      throttlingPolicy: 'TelcoConsentRiskOperations'
    })
  });
  const operationsKeys = (
    await request(`${base}/applications/${operationsApplication.applicationId}/generate-keys`, {
      method: 'POST',
      headers: bearer(devportalToken, { 'content-type': 'application/json' }),
      body: JSON.stringify({
        keyType: 'PRODUCTION',
        grantTypesToBeSupported: ['password', 'refresh_token'],
        callbackUrl: 'http://localhost:8080/callback',
        validityTime: 3600,
        scopes: SCOPES.map(scope => scope.key)
      })
    })
  ).data;
  if (!operationsKeys?.consumerKey || !operationsKeys?.consumerSecret) {
    throw new Error(`Operations application key generation failed: ${JSON.stringify(operationsKeys)}`);
  }

  // A dedicated two-second client makes the expired-token demonstration
  // deterministic without changing the normal demo application's lifetime.
  const expiryApplication = (
    await request(`${base}/applications`, {
      method: 'POST',
      headers: bearer(devportalToken, { 'content-type': 'application/json' }),
      body: JSON.stringify({
        name: 'Telco OAuth Expired Token Demo',
        throttlingPolicy: 'Unlimited',
        description: 'Short-lived native APIM client used only to demonstrate token expiration.',
        tokenType: 'JWT'
      })
    })
  ).data;
  await request(`${base}/subscriptions`, {
    method: 'POST',
    headers: bearer(devportalToken, { 'content-type': 'application/json' }),
    body: JSON.stringify({
      applicationId: expiryApplication.applicationId,
      apiId: targetApi.id,
      throttlingPolicy: 'TelcoConsentRiskPartner'
    })
  });
  const expiryKeys = (
    await request(`${base}/applications/${expiryApplication.applicationId}/generate-keys`, {
      method: 'POST',
      headers: bearer(devportalToken, { 'content-type': 'application/json' }),
      body: JSON.stringify({
        keyType: 'PRODUCTION',
        grantTypesToBeSupported: ['password'],
        callbackUrl: 'http://localhost:8080/callback',
        validityTime: 2,
        scopes: SCOPES.map(scope => scope.key)
      })
    })
  ).data;
  if (!expiryKeys?.consumerKey || !expiryKeys?.consumerSecret) {
    throw new Error(`Short-lived application key generation failed: ${JSON.stringify(expiryKeys)}`);
  }

  log(`Created partner demo application and OAuth client ${keys.consumerKey}`);
  log(`Created operations demo application and OAuth client ${operationsKeys.consumerKey}`);
  log(`Created two-second expiry client ${expiryKeys.consumerKey}`);
  return {
    applicationId: application.applicationId,
    apiId: targetApi.id,
    consumerKey: keys.consumerKey,
    consumerSecret: keys.consumerSecret,
    subscriptionPolicy: 'TelcoConsentRiskPartner',
    operationsClient: {
      applicationId: operationsApplication.applicationId,
      consumerKey: operationsKeys.consumerKey,
      consumerSecret: operationsKeys.consumerSecret,
      subscriptionPolicy: 'TelcoConsentRiskOperations'
    },
    expiredTokenClient: {
      applicationId: expiryApplication.applicationId,
      consumerKey: expiryKeys.consumerKey,
      consumerSecret: expiryKeys.consumerSecret,
      validityTime: 2
    }
  };
}

async function main() {
  await waitForApim();

  // Scope role validation is enabled by default in APIM. Provision the
  // Internal/* roles and demo users through the Carbon user-store admin service
  // before the API local scopes are created or updated.
  const users = await ensurePersonas();

  const publisherToken = await managementToken(
    'apim:api_view apim:api_create apim:api_manage apim:api_update apim:api_publish apim:document_create apim:document_manage apim:document_update apim:document_delete'
  );
  const api = await upsertApi(publisherToken);
  await ensureDocuments(publisherToken, api);

  const devportalToken = await managementToken('apim:api_view apim:subscribe apim:app_manage apim:sub_manage');
  const application = await recreateDemoApplication(devportalToken, api);

  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(
    STATE_FILE,
    `${JSON.stringify(
      {
        marker: MARKER,
        generatedAt: new Date().toISOString(),
        api: {
          id: api.id,
          name: API_NAME,
          version: API_VERSION,
          context: API_CONTEXT,
          gatewayUrl: 'https://localhost:8243/subscriber-authorization/v1/1.0.0'
        },
        scopes: SCOPES,
        users,
        application,
        sandboxConsents: [
          {
            consentId: 'CONSENT-ALPHA-001',
            partnerId: 'partner-alpha',
            country: 'BR',
            subscriberNumber: '+5511999990001',
            status: 'ACTIVE'
          },
          {
            consentId: 'CONSENT-BETA-001',
            partnerId: 'partner-beta',
            country: 'MX',
            subscriberNumber: '+525512340001',
            status: 'ACTIVE'
          }
        ]
      },
      null,
      2
    )}\n`
  );
  log(`State written to ${STATE_FILE}`);
  log('OAuth scopes, personas, consent controls and verification client are ready');
}

main().catch(error => {
  console.error(`[oauth-business-controls] ${error.stack || error.message || error}`);
  process.exit(1);
});
