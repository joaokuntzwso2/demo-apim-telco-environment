const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');
const { execFileSync } = require('child_process');
const { fetch, Agent } = require('undici');
const YAML = require('yaml');
const { createSoapPassThroughApi } = require('./soap-publisher'); const { importStreamingApi } = require('./streaming-publisher');

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

  { id: 'open-gateway-number-verification', name: 'OpenGatewayNumberVerificationAPI', version: '1.0.0', importSpecCandidates: [ 'contracts/openapi/open-gateway-number-verification.openapi.yaml', 'open-gateway-number-verification.openapi.yaml' ], context: '/open-gateway/number-verification/v1', routes: ['/api/v1/open-gateway/number-verification/verify'] },
  { id: 'open-gateway-sim-swap-risk', name: 'OpenGatewaySimSwapRiskAPI', version: '1.0.0', importSpecCandidates: [ 'contracts/openapi/open-gateway-sim-swap-risk.openapi.yaml', 'open-gateway-sim-swap-risk.openapi.yaml' ], context: '/open-gateway/sim-swap/v1', routes: ['/api/v1/open-gateway/sim-swap'] },
  { id: 'open-gateway-device-location-verification', name: 'OpenGatewayDeviceLocationVerificationAPI', version: '1.0.0', importSpecCandidates: [ 'contracts/openapi/open-gateway-device-location-verification.openapi.yaml', 'open-gateway-device-location-verification.openapi.yaml' ], context: '/open-gateway/device-location/v1', routes: ['/api/v1/open-gateway/device-location/verify'] },

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
  { id: 'network-events', name: 'NetworkEventsStreamAPI', version: '1.0.0', protocol: 'ASYNC', type: 'SSE', asyncapiSpecCandidates: [ 'contracts/asyncapi/network-events.asyncapi.yaml', 'contracts/network-events.asyncapi.yaml', 'network-events.asyncapi.yaml' ], context: '/network-events/v1', routes: ['/events/network-events'] }
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


function inferApiProduct(api, openapi = {}) {
  if (api.apiProduct) return api.apiProduct;
  if (openapi['x-telco-api-product']) return openapi['x-telco-api-product'];

  const productByApi = {
    TelcoBusinessCatalogAPI: 'Telco API Marketplace Catalog',
    Customer360API: 'Customer Experience Pack',
    NumberLifecycleAPI: 'Number Management Pack',
    NetworkSliceAPI: '5G Network Exposure Pack',
    PartnerChargingAPI: 'Partner Monetization Pack',
    BillingAdjustmentSOAP: 'Legacy BSS Modernization Pack',
    NetworkEventsStreamAPI: 'Network Event Streaming Pack',
    OpenGatewayNumberVerificationAPI: 'Open Gateway Fraud Prevention Pack',
    OpenGatewaySimSwapRiskAPI: 'Open Gateway Fraud Prevention Pack',
    OpenGatewayDeviceLocationVerificationAPI: 'Open Gateway Fraud Prevention Pack'
  };

  return productByApi[api.name] || String(api.name || 'Telco API Product').replace(/API$/g, ' Product');
}

function inferHealthPath(api, openapi = {}) {
  return api.healthPath || openapi['x-telco-health-path'] || '/health';
}

function inferHealthMethod(api, openapi = {}) {
  return api.healthMethod || openapi['x-telco-health-method'] || 'GET';
}

function buildGovernanceAdditionalProperties(api, openapi = {}) {
  return {
    health_path: inferHealthPath(api, openapi),
    health_method: inferHealthMethod(api, openapi),
    api_product: inferApiProduct(api, openapi)
  };
}

function upsertApiCustomProperties(apiObject, properties) {
  const currentArray = Array.isArray(apiObject.additionalProperties)
    ? apiObject.additionalProperties
    : [];

  const currentMap = apiObject.additionalPropertiesMap && typeof apiObject.additionalPropertiesMap === 'object' && !Array.isArray(apiObject.additionalPropertiesMap)
    ? apiObject.additionalPropertiesMap
    : {};

  const byName = new Map();

  for (const item of currentArray) {
    if (item && item.name) {
      byName.set(String(item.name).toLowerCase(), {
        name: String(item.name),
        value: String(item.value ?? ''),
        display: item.display !== false
      });
    }
  }

  for (const [name, value] of Object.entries(currentMap)) {
    if (!name) continue;

    if (value && typeof value === 'object' && !Array.isArray(value)) {
      byName.set(String(name).toLowerCase(), {
        name: String(value.name || name),
        value: String(value.value ?? ''),
        display: value.display !== false
      });
    } else {
      byName.set(String(name).toLowerCase(), {
        name: String(name),
        value: String(value ?? ''),
        display: true
      });
    }
  }

  for (const [name, value] of Object.entries(properties)) {
    byName.set(String(name).toLowerCase(), {
      name: String(name),
      value: String(value),
      display: true
    });
  }

  const arr = Array.from(byName.values());

  apiObject.additionalProperties = arr;
  apiObject.additionalPropertiesMap = Object.fromEntries(
    arr.map(item => [
      item.name,
      {
        name: item.name,
        value: item.value,
        display: item.display !== false
      }
    ])
  );

  return apiObject;
}

function upsertBusinessInformation(apiObject, openapi = {}) {
  const contact = openapi.info?.contact || {};

  apiObject.businessInformation = {
    ...(apiObject.businessInformation || {}),
    businessOwner: apiObject.businessInformation?.businessOwner || contact.name || 'Telco API Product Office',
    businessOwnerEmail: apiObject.businessInformation?.businessOwnerEmail || contact.email || 'telco-api-product-office@example.com'
  };

  return apiObject;
}

async function ensurePublisherGovernanceMetadata(api, publisherApi, token) {
  const full = await publisherRestRequest(
    'GET',
    `${APIM_URL}/api/am/publisher/v4/apis/${publisherApi.id}`,
    token
  );

  const properties = buildGovernanceAdditionalProperties(api, {});

  upsertApiCustomProperties(full, properties);
  upsertBusinessInformation(full, {});

  await publisherRestRequest(
    'PUT',
    `${APIM_URL}/api/am/publisher/v4/apis/${publisherApi.id}`,
    token,
    full,
    [200, 201, 202]
  );

  log(`Governance metadata prepared for ${publisherApi.name}: ${JSON.stringify(properties)}`);

  return full;
}


// BEGIN GENERATED PROJECT GOVERNANCE METADATA PATCH
function inferGeneratedApiProduct(api) {
  const productByApi = {
    TelcoBusinessCatalogAPI: 'Telco API Marketplace Catalog',
    Customer360API: 'Customer Experience Pack',
    NumberLifecycleAPI: 'Number Management Pack',
    NetworkSliceAPI: '5G Network Exposure Pack',
    PartnerChargingAPI: 'Partner Monetization Pack',
    BillingAdjustmentSOAP: 'Legacy BSS Modernization Pack',
    NetworkEventsStreamAPI: 'Network Event Streaming Pack',
    OpenGatewayNumberVerificationAPI: 'Open Gateway Fraud Prevention Pack',
    OpenGatewaySimSwapRiskAPI: 'Open Gateway Fraud Prevention Pack',
    OpenGatewayDeviceLocationVerificationAPI: 'Open Gateway Fraud Prevention Pack'
  };

  return api.apiProduct || productByApi[api.name] || String(api.name || 'Telco API Product').replace(/API$/g, ' Product');
}

function governanceAdditionalPropertiesFor(api, openapi = {}) {
  return {
    health_path: String(api.healthPath || openapi['x-telco-health-path'] || '/health'),
    health_method: String(api.healthMethod || openapi['x-telco-health-method'] || 'GET'),
    api_product: String(api.apiProduct || openapi['x-telco-api-product'] || inferGeneratedApiProduct(api))
  };
}

function mergeAdditionalPropertiesArray(existing, properties) {
  const byName = new Map();

  for (const item of Array.isArray(existing) ? existing : []) {
    if (!item || !item.name) continue;

    byName.set(String(item.name), {
      name: String(item.name),
      value: String(item.value ?? ''),
      display: item.display !== false
    });
  }

  for (const [name, value] of Object.entries(properties)) {
    byName.set(String(name), {
      name: String(name),
      value: String(value),
      display: true
    });
  }

  return Array.from(byName.values());
}

function writeGovernanceApiParams(projectDir, api, openapi = {}) {
  const paramsPath = path.join(projectDir, 'api_params.yaml');
  const envName = process.env.APICTL_ENV || process.env.APIM_ENV || 'am47';
  const governanceProperties = governanceAdditionalPropertiesFor(api, openapi);

  const params = fs.existsSync(paramsPath)
    ? (yaml.load(fs.readFileSync(paramsPath, 'utf8')) || {})
    : {};

  if (!Array.isArray(params.environments)) {
    params.environments = [];
  }

  let env = params.environments.find(item => item && item.name === envName);

  if (!env) {
    env = { name: envName };
    params.environments.push(env);
  }

  env.additionalProperties = mergeAdditionalPropertiesArray(
    env.additionalProperties,
    governanceProperties
  );

  fs.writeFileSync(
    paramsPath,
    yaml.dump(params, { lineWidth: -1, noRefs: true }),
    'utf8'
  );

  log(`Injected governance metadata into api_params.yaml for ${api.name}: ${JSON.stringify(governanceProperties)}`);
}

function applyGeneratedProjectGovernanceMetadata(projectDir, api, openapi = {}) {
  const apiYamlPath = path.join(projectDir, 'api.yaml');

  if (fs.existsSync(apiYamlPath)) {
    const doc = yaml.load(fs.readFileSync(apiYamlPath, 'utf8')) || {};

    if (!doc.data || typeof doc.data !== 'object') {
      doc.data = {};
    }

    // Do not inject governance custom properties directly into api.yaml.
    // APICTL/APIM import expects these through api_params.yaml additionalProperties.
    delete doc.data.additionalPropertiesMap;

    doc.data.businessInformation = {
      ...(doc.data.businessInformation || {}),
      businessOwner:
        doc.data.businessInformation?.businessOwner ||
        openapi.info?.contact?.name ||
        'Telco API Product Office',
      businessOwnerEmail:
        doc.data.businessInformation?.businessOwnerEmail ||
        openapi.info?.contact?.email ||
        'telco-api-product-office@example.com',
      technicalOwner:
        doc.data.businessInformation?.technicalOwner ||
        'Telco API Platform Team',
      technicalOwnerEmail:
        doc.data.businessInformation?.technicalOwnerEmail ||
        'telco-api-platform@example.com'
    };

    fs.writeFileSync(
      apiYamlPath,
      yaml.dump(doc, { lineWidth: -1, noRefs: true }),
      'utf8'
    );
  }

  writeGovernanceApiParams(projectDir, api, openapi);
}
// END GENERATED PROJECT GOVERNANCE METADATA PATCH





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


  applyGeneratedProjectGovernanceMetadata(projectDir, api, openapi);
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


// BEGIN ROBUST GOVERNANCE METADATA PATCH
function inferGovernedApiProduct(api) {
  const productByApi = {
    TelcoBusinessCatalogAPI: 'Telco API Marketplace Catalog',
    Customer360API: 'Customer Experience Pack',
    NumberLifecycleAPI: 'Number Management Pack',
    NetworkSliceAPI: '5G Network Exposure Pack',
    PartnerChargingAPI: 'Partner Monetization Pack',
    BillingAdjustmentSOAP: 'Legacy BSS Modernization Pack',
    NetworkEventsStreamAPI: 'Network Event Streaming Pack',
    OpenGatewayNumberVerificationAPI: 'Open Gateway Fraud Prevention Pack',
    OpenGatewaySimSwapRiskAPI: 'Open Gateway Fraud Prevention Pack',
    OpenGatewayDeviceLocationVerificationAPI: 'Open Gateway Fraud Prevention Pack'
  };

  return productByApi[api.name] || String(api.name || 'Telco API Product').replace(/API$/g, ' Product');
}

function governedMetadataFor(api) {
  return {
    health_path: api.healthPath || '/health',
    health_method: api.healthMethod || 'GET',
    api_product: api.apiProduct || inferGovernedApiProduct(api)
  };
}

function normalizeApiPropertiesForGovernance(apiObject, properties) {
  const currentArray = Array.isArray(apiObject.additionalProperties)
    ? apiObject.additionalProperties
    : [];

  const currentMap = apiObject.additionalPropertiesMap && typeof apiObject.additionalPropertiesMap === 'object' && !Array.isArray(apiObject.additionalPropertiesMap)
    ? apiObject.additionalPropertiesMap
    : {};

  const byName = new Map();

  for (const item of currentArray) {
    if (!item || !item.name) continue;

    byName.set(String(item.name), String(item.value ?? ''));
  }

  for (const [name, rawValue] of Object.entries(currentMap)) {
    if (!name) continue;

    if (rawValue && typeof rawValue === 'object' && !Array.isArray(rawValue)) {
      byName.set(String(name), String(rawValue.value ?? ''));
    } else {
      byName.set(String(name), String(rawValue ?? ''));
    }
  }

  for (const [name, value] of Object.entries(properties)) {
    byName.set(String(name), String(value));
  }

  apiObject.additionalProperties = Array.from(byName.entries()).map(([name, value]) => ({
    name,
    value,
    display: true
  }));

  // Governance rules evaluate this as a simple map.
  apiObject.additionalPropertiesMap = Object.fromEntries(byName.entries());

  apiObject.businessInformation = {
    ...(apiObject.businessInformation || {}),
    businessOwner: apiObject.businessInformation?.businessOwner || 'Telco API Product Office',
    businessOwnerEmail: apiObject.businessInformation?.businessOwnerEmail || 'telco-api-product-office@example.com',
    technicalOwner: apiObject.businessInformation?.technicalOwner || 'Telco API Platform Team',
    technicalOwnerEmail: apiObject.businessInformation?.technicalOwnerEmail || 'telco-api-platform@example.com'
  };

  return apiObject;
}


function sanitizeOpenGatewayScopesForApim(value) {
  if (typeof value === 'string') {
    return value
      .replace(/opengateway:number-verification/g, 'opengateway_number_verification')
      .replace(/opengateway:sim-swap/g, 'opengateway_sim_swap')
      .replace(/opengateway:device-location/g, 'opengateway_device_location');
  }

  if (Array.isArray(value)) {
    for (let i = 0; i < value.length; i += 1) {
      value[i] = sanitizeOpenGatewayScopesForApim(value[i]);
    }
    return value;
  }

  if (value && typeof value === 'object') {
    for (const key of Object.keys(value)) {
      value[key] = sanitizeOpenGatewayScopesForApim(value[key]);
    }
    return value;
  }

  return value;
}

async function ensureGovernanceMetadataBeforePublish(api, publisherApi, token) {
  const metadata = governedMetadataFor(api);

  const fullApi = await publisherRestRequest(
    'GET',
    `${APIM_URL}/api/am/publisher/v4/apis/${publisherApi.id}`,
    token
  );

  sanitizeOpenGatewayScopesForApim(fullApi);
  normalizeApiPropertiesForGovernance(fullApi, metadata);

  await publisherRestRequest(
    'PUT',
    `${APIM_URL}/api/am/publisher/v4/apis/${publisherApi.id}`,
    token,
    fullApi,
    [200, 201, 202]
  );

  const verified = await publisherRestRequest(
    'GET',
    `${APIM_URL}/api/am/publisher/v4/apis/${publisherApi.id}`,
    token
  );

  const map = verified.additionalPropertiesMap || {};
  const verifiedMap = {
    health_path: map.health_path,
    health_method: map.health_method,
    api_product: map.api_product
  };

  log(`Governance metadata prepared for ${publisherApi.name}: ${JSON.stringify(verifiedMap)}`);

  return verified;
}
// END ROBUST GOVERNANCE METADATA PATCH



// BEGIN PUBLISHER PRE-PUBLISH GOVERNANCE METADATA PATCH
function inferPublisherGovernanceApiProduct(api) {
  const productByApi = {
    TelcoBusinessCatalogAPI: 'Telco API Marketplace Catalog',
    Customer360API: 'Customer Experience Pack',
    NumberLifecycleAPI: 'Number Management Pack',
    NetworkSliceAPI: '5G Network Exposure Pack',
    PartnerChargingAPI: 'Partner Monetization Pack',
    BillingAdjustmentSOAP: 'Legacy BSS Modernization Pack',
    NetworkEventsStreamAPI: 'Network Event Streaming Pack',
    OpenGatewayNumberVerificationAPI: 'Open Gateway Fraud Prevention Pack',
    OpenGatewaySimSwapRiskAPI: 'Open Gateway Fraud Prevention Pack',
    OpenGatewayDeviceLocationVerificationAPI: 'Open Gateway Fraud Prevention Pack'
  };

  return api.apiProduct || productByApi[api.name] || String(api.name || 'Telco API Product').replace(/API$/g, ' Product');
}

function publisherGovernanceMetadataFor(api) {
  return {
    health_path: String(api.healthPath || '/health'),
    health_method: String(api.healthMethod || 'GET'),
    api_product: String(inferPublisherGovernanceApiProduct(api))
  };
}

function normalizePublisherAdditionalPropertyValue(raw) {
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
    return {
      value: String(raw.value ?? ''),
      display: raw.display !== false
    };
  }

  return {
    value: String(raw ?? ''),
    display: true
  };
}

function upsertPublisherGovernanceProperties(apiObject, properties) {
  const currentArray = Array.isArray(apiObject.additionalProperties)
    ? apiObject.additionalProperties
    : [];

  const currentMap =
    apiObject.additionalPropertiesMap &&
    typeof apiObject.additionalPropertiesMap === 'object' &&
    !Array.isArray(apiObject.additionalPropertiesMap)
      ? apiObject.additionalPropertiesMap
      : {};

  const byName = new Map();

  for (const item of currentArray) {
    if (!item || !item.name) continue;

    byName.set(String(item.name), {
      name: String(item.name),
      value: String(item.value ?? ''),
      display: item.display !== false
    });
  }

  for (const [name, raw] of Object.entries(currentMap)) {
    if (!name) continue;

    const normalized = normalizePublisherAdditionalPropertyValue(raw);

    byName.set(String(name), {
      name: String(name),
      value: normalized.value,
      display: normalized.display
    });
  }

  for (const [name, value] of Object.entries(properties)) {
    byName.set(String(name), {
      name: String(name),
      value: String(value),
      display: true
    });
  }

  const arr = Array.from(byName.values());

  apiObject.additionalProperties = arr;

  // Publisher PUT expects APIInfoAdditionalPropertiesMapDTO objects here.
  apiObject.additionalPropertiesMap = Object.fromEntries(
    arr.map(item => [
      item.name,
      {
        name: item.name,
        value: item.value,
        display: item.display !== false
      }
    ])
  );

  apiObject.businessInformation = {
    ...(apiObject.businessInformation || {}),
    businessOwner: apiObject.businessInformation?.businessOwner || 'Telco API Product Office',
    businessOwnerEmail: apiObject.businessInformation?.businessOwnerEmail || 'telco-api-product-office@example.com',
    technicalOwner: apiObject.businessInformation?.technicalOwner || 'Telco API Platform Team',
    technicalOwnerEmail: apiObject.businessInformation?.technicalOwnerEmail || 'telco-api-platform@example.com'
  };

  return apiObject;
}

async function ensurePublisherGovernanceMetadataBeforePublish(api, publisherApi, token) {
  const metadata = publisherGovernanceMetadataFor(api);

  const fullApi = await publisherRestRequest(
    'GET',
    `${APIM_URL}/api/am/publisher/v4/apis/${publisherApi.id}`,
    token
  );

  upsertPublisherGovernanceProperties(fullApi, metadata);

  await publisherRestRequest(
    'PUT',
    `${APIM_URL}/api/am/publisher/v4/apis/${publisherApi.id}`,
    token,
    fullApi,
    [200, 201, 202]
  );

  const verified = await publisherRestRequest(
    'GET',
    `${APIM_URL}/api/am/publisher/v4/apis/${publisherApi.id}`,
    token
  );

  const verifiedMap = verified.additionalPropertiesMap || {};

  log(`Publisher governance metadata prepared for ${publisherApi.name}: ${JSON.stringify({
    health_path: verifiedMap.health_path,
    health_method: verifiedMap.health_method,
    api_product: verifiedMap.api_product
  })}`);
}
// END PUBLISHER PRE-PUBLISH GOVERNANCE METADATA PATCH



// BEGIN MINIMAL PUBLISHER CUSTOM PROPERTY PATCH
function inferTelcoGovernanceProduct(api) {
  const productByApi = {
    TelcoBusinessCatalogAPI: 'Telco API Marketplace Catalog',
    Customer360API: 'Customer Experience Pack',
    NumberLifecycleAPI: 'Number Management Pack',
    NetworkSliceAPI: '5G Network Exposure Pack',
    PartnerChargingAPI: 'Partner Monetization Pack',
    BillingAdjustmentSOAP: 'Legacy BSS Modernization Pack',
    NetworkEventsStreamAPI: 'Network Event Streaming Pack',
    OpenGatewayNumberVerificationAPI: 'Open Gateway Fraud Prevention Pack',
    OpenGatewaySimSwapRiskAPI: 'Open Gateway Fraud Prevention Pack',
    OpenGatewayDeviceLocationVerificationAPI: 'Open Gateway Fraud Prevention Pack'
  };

  return api.apiProduct || productByApi[api.name] || String(api.name || 'Telco API Product').replace(/API$/g, ' Product');
}

function telcoGovernanceProperties(api) {
  return {
    health_path: String(api.healthPath || '/health'),
    health_method: String(api.healthMethod || 'GET'),
    api_product: String(inferTelcoGovernanceProduct(api))
  };
}

function mergeMinimalAdditionalProperties(apiObject, properties) {
  const existing = Array.isArray(apiObject.additionalProperties)
    ? apiObject.additionalProperties
    : [];

  const byName = new Map();

  for (const item of existing) {
    if (!item || !item.name) continue;

    byName.set(String(item.name), {
      name: String(item.name),
      value: String(item.value ?? ''),
      display: item.display !== false
    });
  }

  for (const [name, value] of Object.entries(properties)) {
    byName.set(String(name), {
      name,
      value: String(value),
      display: true
    });
  }

  apiObject.additionalProperties = Array.from(byName.values());

  // Important:
  // Do not send additionalPropertiesMap in Publisher PUT.
  // APIM derives it internally from additionalProperties.
  delete apiObject.additionalPropertiesMap;

  apiObject.businessInformation = {
    ...(apiObject.businessInformation || {}),
    businessOwner: apiObject.businessInformation?.businessOwner || 'Telco API Product Office',
    businessOwnerEmail: apiObject.businessInformation?.businessOwnerEmail || 'telco-api-product-office@example.com',
    technicalOwner: apiObject.businessInformation?.technicalOwner || 'Telco API Platform Team',
    technicalOwnerEmail: apiObject.businessInformation?.technicalOwnerEmail || 'telco-api-platform@example.com'
  };

  return apiObject;
}

function getPropertyFromArray(apiObject, name) {
  const item = (apiObject.additionalProperties || []).find(p => p && p.name === name);
  return item ? item.value : undefined;
}

async function ensureMinimalPublisherCustomPropertiesBeforePublish(api, publisherApi, token) {
  const properties = telcoGovernanceProperties(api);

  const fullApi = await publisherRestRequest(
    'GET',
    `${APIM_URL}/api/am/publisher/v4/apis/${publisherApi.id}`,
    token
  );

  mergeMinimalAdditionalProperties(fullApi, properties);

  await publisherRestRequest(
    'PUT',
    `${APIM_URL}/api/am/publisher/v4/apis/${publisherApi.id}`,
    token,
    fullApi,
    [200, 201, 202]
  );

  const verified = await publisherRestRequest(
    'GET',
    `${APIM_URL}/api/am/publisher/v4/apis/${publisherApi.id}`,
    token
  );

  const verification = {
    health_path: getPropertyFromArray(verified, 'health_path'),
    health_method: getPropertyFromArray(verified, 'health_method'),
    api_product: getPropertyFromArray(verified, 'api_product'),
    map_health_path: verified.additionalPropertiesMap?.health_path,
    map_health_method: verified.additionalPropertiesMap?.health_method,
    map_api_product: verified.additionalPropertiesMap?.api_product
  };

  log(`Verified Publisher custom properties for ${publisherApi.name}: ${JSON.stringify(verification)}`);

  if (!verification.health_path || !verification.health_method || !verification.api_product) {
    log(
      `Governance custom properties are not visible through Publisher REST for ${publisherApi.name}; ` +
      `continuing because the metadata governance rules are demo-safe WARN rules. ` +
      `Verification: ${JSON.stringify(verification)}`
    );
  }
}
// END MINIMAL PUBLISHER CUSTOM PROPERTY PATCH


async function publishApiWithPublisherRest(api) {
  const token = await getAdminToken();
  const publisherApi = await findPublisherApiForBootstrap(api, token);

  const currentStatus = publisherApi.lifeCycleStatus || publisherApi.lifeCycleStatusName || publisherApi.status;
  if (currentStatus === 'PUBLISHED') {
    log(`${publisherApi.name} is already PUBLISHED.`);
    return publisherApi;
  }

  log(`Publishing ${publisherApi.name}:${publisherApi.version || api.version} through Publisher REST API. Current status: ${currentStatus || 'unknown'}`);

  // Required for telco governance rules before lifecycle Publish.
  await ensureMinimalPublisherCustomPropertiesBeforePublish(api, publisherApi, token);

  // Required for telco governance rules before lifecycle Publish.




  await publisherRestRequest(
    'POST',
    `${APIM_URL}/api/am/publisher/v4/apis/change-lifecycle?apiId=${publisherApi.id}&action=Publish`,
    token,
    null,
    [200, 201, 202]
  );

  log(`${publisherApi.name} published successfully through Publisher REST API.`);
  return publisherApi;}


async function importAndPublishStreamingApi(api) {
  const token = await getAdminToken();
  const asyncapiPath = findSpec(
    api.asyncapiSpecCandidates || api.importSpecCandidates || api.supplementalSpecCandidates || [],
    api.name,
    'asyncapi'
  );

  if (!asyncapiPath) {
    throw new Error(`No AsyncAPI contract found for streaming API ${api.name}`);
  }

  const created = importStreamingApi({
    apimUrl: APIM_URL,
    token,
    name: api.name,
    version: api.version,
    context: api.context,
    asyncapiPath,
    endpointUrl: BACKEND_URL,
    type: api.type || api.protocol || 'SSE',
    deleteExisting: true,
    deploy: true,
    publish: true,
    log
  });

  return {
    id: api.id,
    name: api.name,
    version: api.version,
    protocol: api.protocol || api.type || 'SSE',
    contractType: 'AsyncAPI/SSE',
    context: api.context,
    gatewayBaseUrl: `${APIM_GATEWAY_URL}${api.context}`,
    spec: asyncapiPath,
    routes: api.routes || []
  };
} async function importAndPublishApi(api) { if (api.type === 'SSE' || api.protocol === 'SSE' || api.type === 'ASYNC' || api.protocol === 'ASYNC') { return importAndPublishStreamingApi(api); }
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

  if (


    String(lastError || '').includes('901409') ||


    String(lastError || '').includes('Key Mappings already exists')


  ) {


    log(`Production key mapping already exists for ${APP_NAME}; reusing existing mapping and continuing.`);


    return {


      keyType: 'PRODUCTION',


      reused: true,


      message: 'Key Mappings already exists'


    };


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
