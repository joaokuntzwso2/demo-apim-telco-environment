const fs = require('fs');
const path = require('path');
const { fetch, FormData } = require('undici');

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const APIM_URL = process.env.WSO2_APIM_URL || 'https://wso2-apim:9443';
const USERNAME = process.env.APIM_USERNAME || 'admin';
const PASSWORD = process.env.APIM_PASSWORD || 'admin';

const RULESET_ROOT =
  process.env.APIM_GOVERNANCE_RULESET_ROOT ||
  '/workspace/artifacts/apim-admin/governance-rulesets';

const RULESETS = [
  {
    name: 'Telco REST Commercial Guardrails',
    description: 'Demo REST API governance rules for operation IDs, throttling documentation, contact ownership and OAuth-first security.',
    ruleType: 'API_DEFINITION',
    artifactType: 'REST_API',
    documentationLink: 'https://example.com/telco-rest-governance',
    provider: 'WSO2 Telco Demo',
    file: 'telco-rest-commercial-guardrails.json'
  },
  {
    name: 'Telco Async Event Guardrails',
    description: 'Demo AsyncAPI/SSE governance rules for event classification, retention, monetization and channel address quality.',
    ruleType: 'API_DEFINITION',
    artifactType: 'ASYNC_API',
    documentationLink: 'https://example.com/telco-event-governance',
    provider: 'WSO2 Telco Demo',
    file: 'telco-async-event-guardrails.json'
  },
  {
    name: 'Telco API Metadata Guardrails Demo Safe',
    description: 'Demo API metadata governance rules for product mapping, health check details and business ownership.',
    ruleType: 'API_METADATA',
    artifactType: 'REST_API',
    documentationLink: 'https://example.com/telco-metadata-governance',
    provider: 'WSO2 Telco Demo',
    file: 'telco-rest-metadata-guardrails.json'
  }
];

const LABELS = [
  {
    name: 'Telco Commercial Streaming APIs',
    description: 'Streaming APIs exposed as commercial telco products.'
  },
  {
    name: 'Telco Commercial APIs',
    description: 'APIs exposed as commercial telco products.'
  },
  {
    name: 'Telco Governed Streaming APIs',
    description: 'Selected AsyncAPI/SSE APIs that must comply with event governance rules.'
  }
];

const GOVERNANCE_POLICIES = [
  {
    name: 'Telco Commercial REST API Policy',
    description: 'Validates REST APIs used as commercial telco products before deploy and publish.',
    rulesets: ['Telco REST Commercial Guardrails'],
    labels: ['Telco Commercial APIs'],
    governableStates: ['API_CREATE', 'API_UPDATE', 'API_DEPLOY', 'API_PUBLISH'],
    actions: [
      { state: 'API_CREATE', ruleSeverity: 'ERROR', type: 'NOTIFY' },
      { state: 'API_UPDATE', ruleSeverity: 'ERROR', type: 'NOTIFY' },
      { state: 'API_DEPLOY', ruleSeverity: 'ERROR', type: 'BLOCK' },
      { state: 'API_PUBLISH', ruleSeverity: 'ERROR', type: 'BLOCK' },
      { state: 'API_DEPLOY', ruleSeverity: 'WARN', type: 'NOTIFY' },
      { state: 'API_PUBLISH', ruleSeverity: 'WARN', type: 'NOTIFY' }
    ]
  },
  {
    name: 'Telco Product Metadata Policy',
    description: 'Validates commercial metadata such as API product, owner and health check information.',
    rulesets: ['Telco API Metadata Guardrails Demo Safe'],
    labels: ['Telco Commercial APIs'],
    governableStates: ['API_UPDATE', 'API_DEPLOY', 'API_PUBLISH'],
    actions: [
      { state: 'API_UPDATE', ruleSeverity: 'ERROR', type: 'NOTIFY' },
      { state: 'API_DEPLOY', ruleSeverity: 'ERROR', type: 'BLOCK' },
      { state: 'API_PUBLISH', ruleSeverity: 'ERROR', type: 'BLOCK' },
      { state: 'API_DEPLOY', ruleSeverity: 'WARN', type: 'NOTIFY' },
      { state: 'API_PUBLISH', ruleSeverity: 'WARN', type: 'NOTIFY' }
    ]
  },
  {
    name: 'Telco Commercial Streaming API Policy',
    description: 'Commercial governance for streaming APIs, using AsyncAPI-compatible rules only.',
    rulesets: ['Telco Async Event Guardrails'],
    labels: ['Telco Commercial Streaming APIs'],
    governableStates: ['API_CREATE', 'API_UPDATE', 'API_DEPLOY', 'API_PUBLISH'],
    actions: [
      { state: 'API_CREATE', ruleSeverity: 'ERROR', type: 'NOTIFY' },
      { state: 'API_UPDATE', ruleSeverity: 'ERROR', type: 'NOTIFY' },
      { state: 'API_DEPLOY', ruleSeverity: 'ERROR', type: 'BLOCK' },
      { state: 'API_PUBLISH', ruleSeverity: 'ERROR', type: 'BLOCK' },
      { state: 'API_CREATE', ruleSeverity: 'WARN', type: 'NOTIFY' },
      { state: 'API_UPDATE', ruleSeverity: 'WARN', type: 'NOTIFY' },
      { state: 'API_DEPLOY', ruleSeverity: 'WARN', type: 'NOTIFY' },
      { state: 'API_PUBLISH', ruleSeverity: 'WARN', type: 'NOTIFY' }
    ]
  },
  {
    name: 'Telco Selected Async API Policy',
    description: 'Applies AsyncAPI/SSE event governance only to selected streaming APIs with the Telco Governed Streaming APIs label.',
    rulesets: ['Telco Async Event Guardrails'],
    labels: ['Telco Governed Streaming APIs'],
    governableStates: ['API_CREATE', 'API_UPDATE', 'API_DEPLOY', 'API_PUBLISH'],
    actions: [
      { state: 'API_CREATE', ruleSeverity: 'ERROR', type: 'NOTIFY' },
      { state: 'API_CREATE', ruleSeverity: 'WARN', type: 'NOTIFY' },
      { state: 'API_CREATE', ruleSeverity: 'INFO', type: 'NOTIFY' },

      { state: 'API_UPDATE', ruleSeverity: 'ERROR', type: 'NOTIFY' },
      { state: 'API_UPDATE', ruleSeverity: 'WARN', type: 'NOTIFY' },
      { state: 'API_UPDATE', ruleSeverity: 'INFO', type: 'NOTIFY' },

      { state: 'API_DEPLOY', ruleSeverity: 'ERROR', type: 'BLOCK' },
      { state: 'API_PUBLISH', ruleSeverity: 'ERROR', type: 'BLOCK' },

      { state: 'API_DEPLOY', ruleSeverity: 'WARN', type: 'NOTIFY' },
      { state: 'API_PUBLISH', ruleSeverity: 'WARN', type: 'NOTIFY' },

      { state: 'API_DEPLOY', ruleSeverity: 'INFO', type: 'NOTIFY' },
      { state: 'API_PUBLISH', ruleSeverity: 'INFO', type: 'NOTIFY' }
    ]
  }
];

const REST_API_LABEL_ASSIGNMENTS = [
  'TelcoBusinessCatalogAPI',
  'Customer360API',
  'NumberLifecycleAPI',
  'NetworkSliceAPI',
  'PartnerChargingAPI',
  'OpenGatewayNumberVerificationAPI',
  'OpenGatewaySimSwapRiskAPI',
  'OpenGatewayDeviceLocationVerificationAPI'
];

const ASYNC_API_LABEL_ASSIGNMENTS = [
  'NetworkEventsStreamAPI',
  'CandidateDroneInspectionEventsAPI'
];

function log(message) {
  console.log(`[APIM governance setup] ${message}`);
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
    const rendered = typeof data === 'string' ? data : JSON.stringify(data);
    throw new Error(`${opts.method || 'GET'} ${url} -> HTTP ${res.status}: ${rendered}`);
  }

  return { status: res.status, data };
}

async function getAdminToken() {
  const dcr = await http(`${APIM_URL}/client-registration/v0.17/register`, {
    method: 'POST',
    basic: `${USERNAME}:${PASSWORD}`,
    json: {
      callbackUrl: 'http://localhost:8080/callback',
      clientName: `telco-demo-governance-setup-${Date.now()}`,
      owner: USERNAME,
      grantType: 'password refresh_token client_credentials',
      saasApp: true
    }
  }, [200, 201]);

  const form = new URLSearchParams();
  form.set('grant_type', 'password');
  form.set('username', USERNAME);
  form.set('password', PASSWORD);
  form.set(
    'scope',
    [
      'apim:admin',
      'apim:api_view',
      'apim:api_create',
      'apim:api_manage',
      'apim:api_publish',
      'apim:api_update',
      'apim:api_metadata_view',
      'apim:gov_rule_read',
      'apim:gov_rule_manage',
      'apim:gov_rule_create',
      'apim:gov_rule_update',
      'apim:gov_policy_read',
      'apim:gov_policy_manage',
      'apim:gov_policy_create',
      'apim:gov_policy_update',
      'apim:gov_result_read',
      'apim:label_view',
      'apim:label_create',
      'apim:label_update',
      'apim:label_manage'
    ].join(' ')
  );

  const token = await http(`${APIM_URL}/oauth2/token`, {
    method: 'POST',
    basic: `${dcr.data.clientId}:${dcr.data.clientSecret}`,
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: form.toString()
  }, [200]);

  return token.data.access_token;
}

function getList(data) {
  if (!data) return [];
  if (Array.isArray(data)) return data;
  if (Array.isArray(data.list)) return data.list;
  if (Array.isArray(data.data)) return data.data;
  if (Array.isArray(data.rulesets)) return data.rulesets;
  return [];
}

function byName(list, name) {
  return list.find(item => (
    item.name ||
    item.rulesetName ||
    item.displayName ||
    item.title
  ) === name);
}

async function listRulesets(token) {
  const result = await http(`${APIM_URL}/api/am/governance/v1/rulesets?limit=1000`, {
    bearer: token
  }, [200]);

  return getList(result.data);
}

async function findRuleset(token, name) {
  const query = encodeURIComponent(`name:${name}`);
  const result = await http(`${APIM_URL}/api/am/governance/v1/rulesets?query=${query}&limit=100`, {
    bearer: token
  }, [200]);

  return byName(getList(result.data), name) || byName(await listRulesets(token), name);
}

async function createRuleset(token, spec) {
  const filePath = path.join(RULESET_ROOT, spec.file);

  if (!fs.existsSync(filePath)) {
    log(`ruleset file missing, skipping: ${filePath}`);
    return;
  }

  if (await findRuleset(token, spec.name)) {
    log(`ruleset already exists: ${spec.name}`);
    return;
  }

  const content = fs.readFileSync(filePath, 'utf8');

  const form = new FormData();
  form.set('name', spec.name);
  form.set('description', spec.description);
  form.set('ruleCategory', 'SPECTRAL');
  form.set('ruleType', spec.ruleType);
  form.set('artifactType', spec.artifactType);
  form.set('documentationLink', spec.documentationLink);
  form.set('provider', spec.provider);
  form.set('rulesetContent', new Blob([content], { type: 'application/json' }), spec.file);

  const result = await http(`${APIM_URL}/api/am/governance/v1/rulesets`, {
    method: 'POST',
    bearer: token,
    body: form
  }, [200, 201, 202, 409]);

  if (result.status === 409) {
    log(`ruleset already exists: ${spec.name}`);
    return;
  }

  log(`created ruleset: ${spec.name}`);
}

async function listLabels(token) {
  const result = await http(`${APIM_URL}/api/am/admin/v4/labels`, {
    bearer: token
  }, [200]);

  return getList(result.data);
}

async function findLabel(token, name) {
  return byName(await listLabels(token), name);
}

async function createOrGetLabel(token, spec) {
  const existing = await findLabel(token, spec.name);

  if (existing) {
    log(`label already exists: ${spec.name}`);
    return existing;
  }

  const created = await http(`${APIM_URL}/api/am/admin/v4/labels`, {
    method: 'POST',
    bearer: token,
    json: {
      name: spec.name,
      description: spec.description
    }
  }, [200, 201, 202, 409]);

  if (created.status === 409) {
    const afterConflict = await findLabel(token, spec.name);
    if (afterConflict) return afterConflict;
  }

  log(`created label: ${spec.name}`);
  return created.data;
}

async function listPolicies(token) {
  const result = await http(`${APIM_URL}/api/am/governance/v1/policies?limit=1000`, {
    bearer: token
  }, [200]);

  return getList(result.data);
}

async function findPolicy(token, name) {
  const query = encodeURIComponent(`name:${name}`);
  const result = await http(`${APIM_URL}/api/am/governance/v1/policies?query=${query}&limit=100`, {
    bearer: token
  }, [200]);

  return byName(getList(result.data), name) || byName(await listPolicies(token), name);
}

async function createOrUpdatePolicy(token, spec, rulesetByName, labelByName) {
  const rulesets = spec.rulesets.map(name => {
    const ruleset = rulesetByName.get(name);
    if (!ruleset?.id) {
      throw new Error(`Ruleset not found or missing id: ${name}`);
    }
    return ruleset.id;
  });

  const labels = spec.labels.map(name => {
    const label = labelByName.get(name);
    if (!label?.id) {
      throw new Error(`Label not found or missing id: ${name}`);
    }
    return label.id;
  });

  const payload = {
    name: spec.name,
    description: spec.description,
    governableStates: spec.governableStates,
    actions: spec.actions,
    rulesets,
    labels
  };

  const existing = await findPolicy(token, spec.name);

  if (existing?.id) {
    const updated = Object.assign({}, existing, payload, { id: existing.id });

    await http(`${APIM_URL}/api/am/governance/v1/policies/${existing.id}`, {
      method: 'PUT',
      bearer: token,
      json: updated
    }, [200, 201, 202]);

    log(`updated governance policy: ${spec.name}`);
    return updated;
  }

  const created = await http(`${APIM_URL}/api/am/governance/v1/policies`, {
    method: 'POST',
    bearer: token,
    json: payload
  }, [200, 201, 202, 409]);

  if (created.status === 409) {
    log(`governance policy already exists: ${spec.name}`);
    return findPolicy(token, spec.name);
  }

  log(`created governance policy: ${spec.name}`);
  return created.data;
}

async function findPublisherApiByName(token, name) {
  const query = encodeURIComponent(`name:${name}`);

  const result = await http(`${APIM_URL}/api/am/publisher/v4/apis?query=${query}&limit=100`, {
    bearer: token
  }, [200]);

  const list = getList(result.data);
  return list.find(api => api.name === name) || null;
}

async function getApiLabels(token, apiId) {
  const result = await http(`${APIM_URL}/api/am/publisher/v4/apis/${apiId}/labels`, {
    bearer: token
  }, [200, 404]);

  if (result.status === 404) return [];
  return getList(result.data);
}

async function attachLabelToApi(token, apiName, label, expectedTypes = []) {
  const api = await findPublisherApiByName(token, apiName);

  if (!api?.id) {
    log(`API not found for label assignment, skipping: ${apiName}`);
    return;
  }

  const apiType = String(api.type || '').toUpperCase();

  if (expectedTypes.length && !expectedTypes.includes(apiType)) {
    log(`API ${apiName} is type=${apiType}; expected one of ${expectedTypes.join(', ')}. Skipping label ${label.name}.`);
    return;
  }

  const currentLabels = await getApiLabels(token, api.id);

  if (currentLabels.some(existing => existing.id === label.id || existing.name === label.name)) {
    log(`API ${apiName} already has label: ${label.name}`);
    return;
  }

  await http(`${APIM_URL}/api/am/publisher/v4/apis/${api.id}/attach-labels`, {
    method: 'POST',
    bearer: token,
    json: {
      labels: [label.id]
    }
  }, [200, 201, 202]);

  log(`attached label ${label.name} to ${apiName}`);
}

async function main() {
  if (!fs.existsSync(RULESET_ROOT)) {
    throw new Error(`ruleset root does not exist: ${RULESET_ROOT}`);
  }

  const token = await getAdminToken();

  for (const spec of RULESETS) {
    await createRuleset(token, spec);
  }

  const rulesetByName = new Map();
  for (const spec of RULESETS) {
    const ruleset = await findRuleset(token, spec.name);
    if (!ruleset?.id) {
      throw new Error(`Could not resolve ruleset id for ${spec.name}`);
    }
    rulesetByName.set(spec.name, ruleset);
  }

  const labelByName = new Map();
  for (const spec of LABELS) {
    const label = await createOrGetLabel(token, spec);
    if (!label?.id) {
      throw new Error(`Could not resolve label id for ${spec.name}`);
    }
    labelByName.set(spec.name, label);
  }

  for (const spec of GOVERNANCE_POLICIES) {
    await createOrUpdatePolicy(token, spec, rulesetByName, labelByName);
  }

  const commercialLabel = labelByName.get('Telco Commercial APIs');
  for (const apiName of REST_API_LABEL_ASSIGNMENTS) {
    await attachLabelToApi(token, apiName, commercialLabel, ['HTTP']);
  }

  const asyncLabel = labelByName.get('Telco Governed Streaming APIs');
  for (const apiName of ASYNC_API_LABEL_ASSIGNMENTS) {
    await attachLabelToApi(token, apiName, asyncLabel, ['SSE', 'ASYNC', 'WEBSUB', 'WEBHOOK', 'WS']);
  }

  log('completed.');
}

main().catch(e => {
  console.error(`[APIM governance setup] failed: ${e.stack || e.message}`);
  process.exitCode = 1;
});
