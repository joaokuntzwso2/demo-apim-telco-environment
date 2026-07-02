const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { fetch, Agent } = require('undici');
const YAML = require('yaml');
const { createSoapPassThroughApi } = require('./soap-publisher');

const dispatcher = new Agent({ connect: { rejectUnauthorized: false } });

const APIM_ENV = process.env.APIM_ENV || 'am47';
const APIM_URL = process.env.WSO2_APIM_URL || 'https://wso2-apim:9443';
const APIM_GATEWAY_URL = process.env.WSO2_APIM_GATEWAY_URL || 'https://wso2-apim:8243';
const APIM_TOKEN_URL = process.env.WSO2_APIM_TOKEN_URL || `${APIM_URL}/oauth2/token`;
const APIM_USER = process.env.APIM_USERNAME || 'admin';
const APIM_PASS = process.env.APIM_PASSWORD || 'admin';
const BACKEND_URL = process.env.TELCO_BACKEND_URL || 'http://telco-backend:8081';
const STATE_FILE = process.env.APIM_PORTAL_STATE_FILE || '/workspace/state/runtime.json';
const APP_NAME = process.env.PORTAL_APP_NAME || 'Regional Portal';

const artifactsRoot = '/workspace/artifacts';
const generatedRoot = '/workspace/generated';

const portalApis = [
  {
    id: 'telco-business-catalog',
    name: 'TelcoBusinessCatalogAPI',
    version: '1.0.0',
    importSpecCandidates: [
      'contracts/telco-business-catalog.openapi.yaml',
      'contracts/telco-business-catalog-api.openapi.yaml',
      'contracts/business-catalog.openapi.yaml',
      'telco-business-catalog.openapi.yaml',
      'telco-business-catalog-api.openapi.yaml',
      'business-catalog.openapi.yaml'
    ],
    context: '/telco-business-catalog/v1',
    routes: ['/health', '/metadata']
  },
  {
    id: 'customer360',
    name: 'Customer360API',
    version: '1.0.0',
    importSpecCandidates: [
      'contracts/customer360.openapi.yaml',
      'contracts/customer-360.openapi.yaml',
      'contracts/customer360-api.openapi.yaml',
      'customer360.openapi.yaml',
      'customer-360.openapi.yaml',
      'customer360-api.openapi.yaml'
    ],
    context: '/customer360/v1',
    routes: ['/api/v1/customers']
  },
  {
    id: 'number-lifecycle',
    name: 'NumberLifecycleAPI',
    version: '1.0.0',
    importSpecCandidates: [
      'contracts/number-lifecycle.openapi.yaml',
      'contracts/number-lifecycle-api.openapi.yaml',
      'number-lifecycle.openapi.yaml',
      'number-lifecycle-api.openapi.yaml'
    ],
    context: '/number-lifecycle/v1',
    routes: ['/api/v1/subscribers']
  },
  {
    id: 'network-slice',
    name: 'NetworkSliceAPI',
    version: '1.0.0',
    importSpecCandidates: [
      'contracts/network-slice.openapi.yaml',
      'contracts/network-slice-api.openapi.yaml',
      'network-slice.openapi.yaml',
      'network-slice-api.openapi.yaml'
    ],
    context: '/network-slice/v1',
    routes: ['/api/v1/network/slices', '/api/v1/network/cells']
  },
  {
    id: 'partner-charging',
    name: 'PartnerChargingAPI',
    version: '1.0.0',
    importSpecCandidates: [
      'contracts/partner-charging.openapi.yaml',
      'contracts/partner-charging-api.openapi.yaml',
      'partner-charging.openapi.yaml',
      'partner-charging-api.openapi.yaml'
    ],
    context: '/partner-charging/v1',
    routes: ['/api/v1/usage', '/api/v1/partners']
  },
  {
    id: 'billing-soap',
    name: 'BillingAdjustmentSOAP',
    version: '1.0.0',
    protocol: 'SOAP',
    type: 'SOAP',
    wsdlSpecCandidates: [
      'contracts/soap/billing-adjustment.wsdl',
      'soap/billing-adjustment.wsdl',
      'billing-adjustment.wsdl'
    ],
    context: '/billing-adjustment-soap',
    soapBackendPath: '/soap/billing-adjustment',
    routes: ['/soap/billing-adjustment']
  },
  {
    id: 'network-events',
    name: 'NetworkEventsStreamAPI',
    version: '1.0.0',
    importSpecCandidates: [
      'contracts/network-events-facade.openapi.yaml',
      'network-events-facade.openapi.yaml',
      'contracts/network-events.openapi.yaml',
      'network-events.openapi.yaml'
    ],
    supplementalSpecCandidates: [
      'contracts/network-events.asyncapi.yaml',
      'network-events.asyncapi.yaml'
    ],
    context: '/network-events/v1',
    routes: ['/events/network-events']
  }
];

function log(message) {
  console.log(`[bootstrap] ${message}`);
}

function run(cmd, args, opts = {}) {
  const printable = `${cmd} ${args.join(' ')}`.replace(/-p\s+\S+/, '-p ********');
  log(`$ ${printable}`);

  try {
    const output = execFileSync(cmd, args, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: opts.timeout || 240000
    });

    if (output?.trim()) log(output.trim());
    return output || '';
  } catch (e) {
    const stdout = e.stdout?.toString?.().trim();
    const stderr = e.stderr?.toString?.().trim();
    if (stdout) log(stdout);
    if (stderr) log(stderr);

    if (opts.allowAlreadyExists && `${stdout}\n${stderr}`.includes('already exists')) {
      log('Already exists. Continuing.');
      return `${stdout}\n${stderr}`;
    }

    if (opts.allowFailure) {
      log(`Non-fatal command failure: ${printable}`);
      return `${stdout}\n${stderr}`;
    }

    throw new Error(`${printable} failed`);
  }
}

function safeName(name) {
  return name.replace(/[^a-z0-9]+/gi, '-').replace(/^-|-$/g, '').toLowerCase();
}

function loadYaml(file) {
  return YAML.parse(fs.readFileSync(file, 'utf8'));
}

function writeYaml(file, value) {
  fs.writeFileSync(file, YAML.stringify(value));
}

function normalizeName(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/api$/g, '')
    .replace(/[^a-z0-9]+/g, '');
}

function listFilesRecursive(dir) {
  if (!fs.existsSync(dir)) return [];

  const out = [];
  for (const item of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, item.name);
    if (item.isDirectory()) {
      out.push(...listFilesRecursive(full));
    } else {
      out.push(full);
    }
  }
  return out;
}

function findSpec(candidates, apiName, kind = 'openapi') {
  const tried = [];

  for (const candidate of candidates || []) {
    const possible = [
      path.join(artifactsRoot, candidate),
      path.join('/workspace', candidate),
      path.join('/workspace/contracts', candidate),
      path.join('/workspace/artifacts/contracts', candidate)
    ];

    for (const file of possible) {
      tried.push(file);
      if (fs.existsSync(file)) return file;
    }
  }

  const allFiles = [
    ...listFilesRecursive('/workspace/contracts'),
    ...listFilesRecursive('/workspace/artifacts')
  ];

  const apiKey = normalizeName(apiName);
  const candidateKeys = (candidates || []).map(normalizeName);

  const kindMatchers = {
    openapi: file => /\.openapi\.ya?ml$/i.test(file) || /openapi/i.test(file),
    asyncapi: file => /asyncapi/i.test(file),
    wsdl: file => /\.wsdl$/i.test(file)
  };

  const kindMatch = kindMatchers[kind] || (() => true);

  const match = allFiles.find(file => {
    const base = normalizeName(path.basename(file));
    return kindMatch(file) && (
      base.includes(apiKey) ||
      candidateKeys.some(key => key && base.includes(key)) ||
      candidateKeys.some(key => key && key.includes(base))
    );
  });

  if (match) return match;

  log(`Could not resolve ${kind} spec for ${apiName}. Tried exact paths:`);
  for (const file of tried) log(` - ${file}`);

  log('Available contract/artifact files:');
  for (const file of allFiles.sort()) log(` - ${file}`);

  return null;
}

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function waitForApim() {
  const url = `${APIM_URL}/services/Version`;

  for (let attempt = 1; attempt <= 90; attempt++) {
    try {
      const res = await fetch(url, { dispatcher });
      if (res.ok) {
        const txt = await res.text();
        log(`APIM is reachable: ${txt.replace(/\s+/g, ' ')}`);
        return;
      }
    } catch (_) {}

    log(`Waiting for APIM at ${url} (${attempt}/90)`);
    await sleep(5000);
  }

  throw new Error(`APIM did not become reachable at ${url}`);
}

function configureApictl() {
  run('apictl', ['version']);
  run(
    'apictl',
    ['add', 'env', APIM_ENV, '--apim', APIM_URL, '--token', APIM_TOKEN_URL, '-k'],
    { allowAlreadyExists: true }
  );
  run('apictl', ['login', APIM_ENV, '-u', APIM_USER, '-p', APIM_PASS, '-k']);
  run('apictl', ['set', '--http-request-timeout', '240000'], { allowFailure: true });
}

function createProject(api) {
  const specPath = findSpec(api.importSpecCandidates, api.name, 'openapi');
  if (!specPath) {
    throw new Error(`No import OpenAPI contract found for ${api.name}. Tried: ${api.importSpecCandidates.join(', ')}`);
  }

  const projectDir = path.join(generatedRoot, `${safeName(api.name)}-${api.version}`);
  const definitionPath = path.join(generatedRoot, `${safeName(api.name)}-definition.yaml`);

  fs.rmSync(projectDir, { recursive: true, force: true });
  fs.mkdirSync(generatedRoot, { recursive: true });

  const openapi = loadYaml(specPath) || {};
  const context = api.context || openapi['x-wso2-basePath'] || `/${safeName(api.name)}/v1`;

  writeYaml(definitionPath, {
    type: 'api',
    version: 'v4.7.0',
    data: {
      name: api.name,
      version: api.version,
      context,
      lifeCycleStatus: 'CREATED',
      type: 'HTTP',
      transport: ['https'],
      visibility: 'PUBLIC',
      provider: APIM_USER,
      policies: ['Unlimited'],
      endpointImplementationType: 'ENDPOINT',
      endpointConfig: {
        endpoint_type: 'http',
        production_endpoints: {
          url: BACKEND_URL
        },
        sandbox_endpoints: {
          url: BACKEND_URL
        }
      }
    }
  });

  run('apictl', ['init', projectDir, '--oas', specPath, '--definition', definitionPath, '--force=true']);

  patchProject(projectDir, api, openapi, context);

  const generatedApiYaml = path.join(projectDir, 'api.yaml');
  if (fs.existsSync(generatedApiYaml)) {
    log(`Generated api.yaml for ${api.name}:`);
    log(fs.readFileSync(generatedApiYaml, 'utf8'));
  }

  return { projectDir, context, specPath };
}

function patchProject(projectDir, api, openapi, context) {
  const apiYaml = path.join(projectDir, 'api.yaml');

  if (fs.existsSync(apiYaml)) {
    const doc = loadYaml(apiYaml) || {};
    doc.type = doc.type || 'api';
    doc.version = 'v4.7.0';
    doc.data = doc.data || {};

    doc.data.name = api.name;
    doc.data.version = api.version;
    doc.data.context = context;
    doc.data.lifeCycleStatus = 'CREATED';
    doc.data.type = 'HTTP';
    doc.data.provider = APIM_USER;
    doc.data.visibility = 'PUBLIC';
    doc.data.transport = ['https'];
    doc.data.policies = doc.data.policies?.length ? doc.data.policies : ['Unlimited'];
    doc.data.endpointImplementationType = 'ENDPOINT';
    doc.data.endpointConfig = {
      endpoint_type: 'http',
      production_endpoints: { url: BACKEND_URL },
      sandbox_endpoints: { url: BACKEND_URL }
    };

    // APIM 4.7 import expects additionalPropertiesMap to be a JSON object.
    // Some APICTL-generated projects may contain it as an empty string, which causes:
    // Expected BEGIN_OBJECT but was STRING at path $.additionalPropertiesMap.
    if (
      doc.data.additionalPropertiesMap === '' ||
      doc.data.additionalPropertiesMap === null ||
      typeof doc.data.additionalPropertiesMap !== 'object' ||
      Array.isArray(doc.data.additionalPropertiesMap)
    ) {
      doc.data.additionalPropertiesMap = {};
    }

    writeYaml(apiYaml, doc);
  }

  const depEnv = path.join(projectDir, 'deployment_environments.yaml');

  // APIM default all-in-one gateway environment is named "Default".
  // APICTL needs deploymentEnvironment to match the configured Gateway environment,
  // otherwise APIM imports only the working copy and does not deploy a revision.
  writeYaml(depEnv, {
    type: 'deployment_environments',
    version: 'v4.7.0',
    data: [
      {
        name: 'Default',
        deploymentEnvironment: 'Default',
        displayOnDevportal: true,
        deploymentVhost: 'localhost'
      }
    ]
  });

  let supplemental = null;
  if (api.supplementalSpecCandidates && api.supplementalSpecCandidates.length) {
    const supplementalKind = api.supplementalSpecCandidates.some(item => item.includes('wsdl')) ? 'wsdl' : 'asyncapi';
    supplemental = findSpec(api.supplementalSpecCandidates, api.name, supplementalKind);
  }

  if (supplemental) {
    const docsDir = path.join(projectDir, 'Docs');
    fs.mkdirSync(docsDir, { recursive: true });
    fs.copyFileSync(supplemental, path.join(docsDir, path.basename(supplemental)));
  }
}


async function publisherRestRequest(method, url, token, body = null, okStatuses = [200, 201, 202, 204]) {
  const res = await fetch(url, {
    method,
    dispatcher,
    headers: {
      authorization: `Bearer ${token}`,
      ...(body ? { 'content-type': 'application/json' } : {})
    },
    body: body ? JSON.stringify(body) : undefined
  });

  const text = await res.text();
  let data = null;

  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }

  if (!okStatuses.includes(res.status)) {
    throw new Error(`${method} ${url} failed: ${res.status} ${typeof data === 'string' ? data : JSON.stringify(data)}`);
  }

  return data;
}

async function findPublisherApiForBootstrap(api, token) {
  const expectedName = api.name;
  const expectedVersion = api.version;
  const expectedContext = api.context;

  async function search(query) {
    const encoded = encodeURIComponent(query);
    const data = await publisherRestRequest(
      'GET',
      `${APIM_URL}/api/am/publisher/v4/apis?query=${encoded}&limit=100`,
      token
    );

    return data?.list || data?.data || [];
  }

  async function listAll() {
    const data = await publisherRestRequest(
      'GET',
      `${APIM_URL}/api/am/publisher/v4/apis?limit=100`,
      token
    );

    return data?.list || data?.data || [];
  }

  for (let attempt = 1; attempt <= 30; attempt++) {
    const candidates = [
      ...(await search(expectedName)),
      ...(await search(`name:${expectedName}`)),
      ...(await listAll())
    ];

    const exact = candidates.find(item =>
      item.name === expectedName &&
      (!item.version || item.version === expectedVersion)
    );

    if (exact?.id) {
      log(`Publisher API found by name: ${expectedName}:${expectedVersion} (${exact.id})`);
      return exact;
    }

    const byContext = candidates.find(item =>
      expectedContext &&
      item.context === expectedContext &&
      (!item.version || item.version === expectedVersion)
    );

    if (byContext?.id) {
      log(`Publisher API found by context: ${expectedContext}:${expectedVersion} -> ${byContext.name} (${byContext.id})`);
      return byContext;
    }

    log(`Waiting for ${expectedName}:${expectedVersion} to appear in Publisher (${attempt}/30)`);
    await sleep(2000);
  }

  const all = await listAll();
  log(`Publisher APIs currently visible: ${all.map(item => `${item.name}:${item.version || '-'}:${item.context || '-'}`).join(', ') || '(none)'}`);

  throw new Error(`Could not find imported API in Publisher: ${expectedName}:${expectedVersion}`);
}

async function publishApiWithPublisherRest(api) {
  const token = await getAdminToken();
  const publisherApi = await findPublisherApiForBootstrap(api, token);

  const currentStatus = publisherApi.lifeCycleStatus || publisherApi.lifeCycleStatusName || publisherApi.status;
  if (currentStatus === 'PUBLISHED') {
    log(`${publisherApi.name} is already PUBLISHED.`);
    return publisherApi;
  }

  log(`Publishing ${publisherApi.name}:${publisherApi.version || api.version} through Publisher REST API. Current status: ${currentStatus || 'unknown'}`);

  await publisherRestRequest(
    'POST',
    `${APIM_URL}/api/am/publisher/v4/apis/change-lifecycle?apiId=${publisherApi.id}&action=Publish`,
    token,
    null,
    [200, 201, 202]
  );

  log(`${publisherApi.name} published successfully through Publisher REST API.`);
  return publisherApi;
}


async function importAndPublishApi(api) {
  if (api.type === 'SOAP' || api.protocol === 'SOAP') {
    return importAndPublishSoapApi(api);
  }
  const { projectDir, context, specPath } = createProject(api);

  run('apictl', ['import', 'api', '--file', projectDir, '--environment', APIM_ENV, '--dry-run', '-k']);

  // Normal path: the project contains deployment_environments.yaml, so APICTL import
  // creates/updates the API and deploys a revision to the configured Gateway environment.
  // Do not use --rotate-revision by default; that flag is only useful when the revision limit is reached.
  try {
    run('apictl', ['import', 'api', '--file', projectDir, '--environment', APIM_ENV, '--update=true', '-k']);
  } catch (e) {
    log(`Normal import failed for ${api.name}. Trying revision rotation fallback.`);
    run('apictl', ['import', 'api', '--file', projectDir, '--environment', APIM_ENV, '--update=true', '--rotate-revision', '-k']);
  }
  await publishApiWithPublisherRest(api);

  return {
    id: api.id,
    name: api.name,
    version: api.version,
    context,
    gatewayBaseUrl: `${APIM_GATEWAY_URL}${context}`,
    spec: specPath,
    routes: api.routes
  };
}

async function dcrRegister() {
  const url = `${APIM_URL}/client-registration/v0.17/register`;
  const body = {
    callbackUrl: 'http://localhost:8080/callback',
    clientName: `regional-portal-bootstrap-${Date.now()}`,
    owner: APIM_USER,
    grantType: 'password refresh_token client_credentials',
    saasApp: true
  };

  const res = await fetch(url, {
    method: 'POST',
    dispatcher,
    headers: {
      authorization: `Basic ${Buffer.from(`${APIM_USER}:${APIM_PASS}`).toString('base64')}`,
      'content-type': 'application/json'
    },
    body: JSON.stringify(body)
  });

  if (!res.ok) {
    throw new Error(`DCR failed: ${res.status} ${await res.text()}`);
  }

  return res.json();
}

async function getAdminToken() {
  const client = await dcrRegister();
  const scope = [
    // Publisher API scopes
    'apim:api_view',
    'apim:api_create',
    'apim:api_update',
    'apim:api_delete',
    'apim:api_manage',
    'apim:api_publish',
    'apim:api_import_export',

    // DevPortal application/subscription/key scopes
    'apim:app_manage',
    'apim:sub_manage',
    'apim:subscribe',
    'apim:api_key',
    'apim:api_generate_key'
  ].join(' ');

  const params = new URLSearchParams({
    grant_type: 'password',
    username: APIM_USER,
    password: APIM_PASS,
    scope
  });

  const res = await fetch(APIM_TOKEN_URL, {
    method: 'POST',
    dispatcher,
    headers: {
      authorization: `Basic ${Buffer.from(`${client.clientId}:${client.clientSecret}`).toString('base64')}`,
      'content-type': 'application/x-www-form-urlencoded'
    },
    body: params
  });

  if (!res.ok) {
    throw new Error(`Admin token request failed: ${res.status} ${await res.text()}`);
  }

  const token = await res.json();
  return token.access_token;
}

async function apiRequest(method, url, token, body) {
  const res = await fetch(url, {
    method,
    dispatcher,
    headers: {
      authorization: `Bearer ${token}`,
      ...(body ? { 'content-type': 'application/json' } : {})
    },
    body: body ? JSON.stringify(body) : undefined
  });

  const text = await res.text();
  let data = null;

  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }

  if (!res.ok && res.status !== 409) {
    throw new Error(`${method} ${url} failed: ${res.status} ${typeof data === 'string' ? data : JSON.stringify(data)}`);
  }

  return { status: res.status, data };
}

async function findDevportalApiId(api, token) {
  const apiName = api.name;
  const expectedVersion = api.version;

  async function searchDevportal(query) {
    const encoded = encodeURIComponent(query);
    const res = await apiRequest(
      'GET',
      `${APIM_URL}/api/am/devportal/v3/apis?query=${encoded}&limit=100`,
      token
    );

    return res.data?.list || res.data?.data || [];
  }

  async function listDevportalPage(offset = 0) {
    const res = await apiRequest(
      'GET',
      `${APIM_URL}/api/am/devportal/v3/apis?limit=100&offset=${offset}`,
      token
    );

    return res.data?.list || res.data?.data || [];
  }

  function matchApi(list) {
    return list.find(item =>
      item.name === apiName &&
      (!item.version || item.version === expectedVersion)
    );
  }

  for (let attempt = 1; attempt <= 30; attempt++) {
    const candidates = [
      ...(await searchDevportal(apiName)),
      ...(await searchDevportal(`name:${apiName}`)),
      ...(await listDevportalPage(0))
    ];

    const match = matchApi(candidates);

    if (match?.id) {
      log(`DevPortal API found: ${apiName} (${match.id})`);
      return match.id;
    }

    log(`Waiting for ${apiName} to appear in DevPortal (${attempt}/30)`);
    await sleep(2000);
  }

  // Last diagnostic pass.
  const all = await listDevportalPage(0);
  log(`Published APIs currently visible in DevPortal: ${all.map(item => `${item.name}:${item.version || '-'}`).join(', ') || '(none)'}`);

  throw new Error(`Could not find published API in DevPortal: ${apiName}`);
}

async function getOrCreateApplication(token) {
  const query = encodeURIComponent(APP_NAME);
  const existing = await apiRequest('GET', `${APIM_URL}/api/am/devportal/v3/applications?query=${query}`, token);
  const list = existing.data?.list || existing.data?.data || [];
  const found = list.find(app => app.name === APP_NAME);

  if (found?.applicationId || found?.id) {
    const id = found.applicationId || found.id;
    log(`Using existing DevPortal application: ${APP_NAME} (${id})`);
    return id;
  }

  const created = await apiRequest('POST', `${APIM_URL}/api/am/devportal/v3/applications`, token, {
    name: APP_NAME,
    throttlingPolicy: 'Unlimited',
    description: 'Server-side application used by the Regional Telco API Business Portal demo.'
  });

  const id = created.data?.applicationId || created.data?.id;
  if (!id) throw new Error(`Application creation did not return an ID: ${JSON.stringify(created.data)}`);

  log(`Created DevPortal application: ${APP_NAME} (${id})`);
  return id;
}

async function subscribeApplicationToApi(applicationId, apiId, apiName, token) {
  for (let attempt = 1; attempt <= 5; attempt++) {
    const response = await apiRequest('POST', `${APIM_URL}/api/am/devportal/v3/subscriptions`, token, {
      applicationId,
      apiId,
      throttlingPolicy: 'Unlimited'
    });

    if (response.status === 409) {
      log(`Subscription already exists: ${APP_NAME} -> ${apiName}`);
      return;
    }

    if (response.status >= 200 && response.status < 300) {
      log(`Subscribed ${APP_NAME} to ${apiName}`);
      return;
    }

    log(`Subscription attempt ${attempt}/5 failed for ${apiName}. Retrying.`);
    await sleep(2000);
  }

  throw new Error(`Could not subscribe ${APP_NAME} to ${apiName}`);
}

async function generateProductionKeys(applicationId, token) {
  const endpoint = `${APIM_URL}/api/am/devportal/v3/applications/${applicationId}/generate-keys`;

  const candidateBodies = [
    {
      keyType: 'PRODUCTION',
      validityTime: 3600,
      callbackUrl: 'http://localhost:8080/callback',
      scopes: []
    },
    {
      keyType: 'PRODUCTION',
      validityTime: 3600,
      callbackUrl: 'http://localhost:8080/callback'
    },
    {
      keyType: 'PRODUCTION',
      validityTime: 3600
    },
    {
      keyType: 'PRODUCTION'
    }
  ];

  let lastError = null;

  for (const body of candidateBodies) {
    log(`Generating production keys using payload: ${JSON.stringify(body)}`);

    const res = await fetch(endpoint, {
      method: 'POST',
      dispatcher,
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json'
      },
      body: JSON.stringify(body)
    });

    const text = await res.text();
    let data = null;

    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      data = text;
    }

    if (!res.ok) {
      lastError = `${res.status} ${typeof data === 'string' ? data : JSON.stringify(data)}`;
      log(`Production key generation attempt failed: ${lastError}`);

      // Try the next smaller payload when APIM rejects unknown request properties.
      if (res.status === 400) {
        continue;
      }

      // Also continue on conflict/server-side idempotency issues; the next payload may still work.
      if (res.status === 409 || res.status >= 500) {
        continue;
      }

      continue;
    }

    const keyMapping = data?.keyMapping || data || {};
    const consumerKey =
      keyMapping.consumerKey ||
      keyMapping.consumer_key ||
      data?.consumerKey ||
      data?.consumer_key;

    const consumerSecret =
      keyMapping.consumerSecret ||
      keyMapping.consumer_secret ||
      data?.consumerSecret ||
      data?.consumer_secret;

    const accessToken =
      keyMapping.accessToken ||
      keyMapping.access_token ||
      data?.accessToken ||
      data?.access_token ||
      null;

    if (!consumerKey || !consumerSecret) {
      lastError = `Successful response did not include consumerKey/consumerSecret: ${JSON.stringify(data)}`;
      log(lastError);
      continue;
    }

    log(`Generated production keys for ${APP_NAME}`);
    return { consumerKey, consumerSecret, accessToken };
  }

  throw new Error(`Production key generation failed for ${APP_NAME}. Last error: ${lastError}`);
}


async function importAndPublishSoapApi(api) {
  const token = await getAdminToken();
  const wsdlPath = findSpec(api.wsdlSpecCandidates || api.supplementalSpecCandidates || [], api.name, 'wsdl');

  if (!wsdlPath) {
    throw new Error(`No WSDL found for SOAP API ${api.name}`);
  }

  const endpointUrl = `${BACKEND_URL}${api.soapBackendPath || '/soap/billing-adjustment'}`;

  const created = createSoapPassThroughApi({
    apimUrl: APIM_URL,
    token,
    name: api.name,
    version: api.version,
    context: api.context,
    endpointUrl,
    wsdlPath,
    publish: true,
    deploy: true,
    deleteExisting: true,
    log
  });

  return {
    id: api.id,
    name: api.name,
    version: api.version,
    protocol: 'SOAP',
    contractType: 'SOAP/WSDL pass-through',
    context: api.context,
    gatewayBaseUrl: `${APIM_GATEWAY_URL}${api.context}`,
    spec: wsdlPath,
    routes: api.routes || []
  };
}

async function main() {
  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify({
    status: 'BOOTSTRAPPING',
    updatedAt: new Date().toISOString()
  }, null, 2));

  await waitForApim();
  configureApictl();

  const importedApis = [];

  for (const api of portalApis) {
    log(`Importing, deploying and publishing ${api.name}`);
    importedApis.push(await importAndPublishApi(api));
  }

  const adminToken = await getAdminToken();
  const applicationId = await getOrCreateApplication(adminToken);

  for (const api of portalApis) {
    const apiId = await findDevportalApiId(api, adminToken);
    await subscribeApplicationToApi(applicationId, apiId, api.name, adminToken);
  }

  const keys = await generateProductionKeys(applicationId, adminToken);

  const runtime = {
    status: 'READY',
    updatedAt: new Date().toISOString(),
    apim: {
      publisherUrl: `${APIM_URL}/publisher`,
      devportalUrl: `${APIM_URL}/devportal`,
      gatewayUrl: APIM_GATEWAY_URL,
      tokenUrl: APIM_TOKEN_URL
    },
    application: {
      name: APP_NAME,
      applicationId,
      keyType: 'PRODUCTION',
      consumerKey: keys.consumerKey,
      consumerSecret: keys.consumerSecret
    },
    apis: importedApis
  };

  fs.writeFileSync(STATE_FILE, JSON.stringify(runtime, null, 2));
  log(`Bootstrap complete. Runtime state written to ${STATE_FILE}`);
}

main().catch(err => {
  console.error(`[bootstrap] FAILED: ${err.stack || err.message}`);

  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify({
    status: 'FAILED',
    error: err.message,
    updatedAt: new Date().toISOString()
  }, null, 2));

  process.exit(1);
});
