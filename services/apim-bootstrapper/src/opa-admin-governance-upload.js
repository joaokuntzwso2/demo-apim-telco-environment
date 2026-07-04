const fs = require('fs');
const path = require('path');
const { fetch, FormData } = require('undici');

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const APIM_URL = process.env.WSO2_APIM_URL || 'https://wso2-apim:9443';
const USERNAME = process.env.APIM_USERNAME || 'admin';
const PASSWORD = process.env.APIM_PASSWORD || 'admin';

const RULESET_ROOT = process.env.APIM_GOVERNANCE_RULESET_ROOT || '/workspace/artifacts/apim-admin/governance-rulesets';
const STATE_FILE = process.env.OPA_ADMIN_GOVERNANCE_STATE_FILE || '/workspace/state/opa-admin-governance-upload.json';

const RULESET = {
  name: 'Telco OPA External Governance Evidence',
  description: 'APIM-visible governance evidence for OPA policy-as-code validations covering commercial API Products, high-risk Open Gateway APIs and regional/federated gateway readiness.',
  ruleType: 'API_DEFINITION',
  artifactType: 'REST_API',
  documentationLink: 'https://example.com/telco-opa-governance',
  provider: 'WSO2 Telco Demo',
  file: 'telco-opa-governance-evidence.json'
};

const LABEL = {
  name: 'Telco OPA Governed APIs',
  description: 'APIs validated by the external OPA policy-as-code decision point and linked to APIM governance evidence.'
};

const POLICY = {
  name: 'Telco OPA External Governance Policy',
  description: 'Visible APIM governance policy showing that OPA validates commercial API product metadata, Open Gateway risk controls and federated gateway readiness.',
  rulesets: [RULESET.name],
  labels: [LABEL.name],
  governableStates: ['API_UPDATE', 'API_DEPLOY', 'API_PUBLISH'],
  actions: [
    { state: 'API_UPDATE', ruleSeverity: 'WARN', type: 'NOTIFY' },
    { state: 'API_DEPLOY', ruleSeverity: 'WARN', type: 'NOTIFY' },
    { state: 'API_PUBLISH', ruleSeverity: 'WARN', type: 'NOTIFY' }
  ]
};

const API_LABEL_ASSIGNMENTS = [
  'Customer360API',
  'NumberLifecycleAPI',
  'NetworkSliceAPI',
  'PartnerChargingAPI',
  'OpenGatewayNumberVerificationAPI',
  'OpenGatewaySimSwapRiskAPI',
  'OpenGatewayDeviceLocationVerificationAPI'
];

function log(message) {
  console.log(`[APIM OPA admin upload] ${message}`);
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

  return {
    status: res.status,
    data
  };
}

async function getAdminToken() {
  const dcr = await http(`${APIM_URL}/client-registration/v0.17/register`, {
    method: 'POST',
    basic: `${USERNAME}:${PASSWORD}`,
    json: {
      callbackUrl: 'http://localhost:8080/callback',
      clientName: `telco-demo-opa-admin-upload-${Date.now()}`,
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
      'apim:api_update',
      'apim:api_manage',
      'apim:gov_rule_read',
      'apim:gov_rule_manage',
      'apim:gov_rule_create',
      'apim:gov_rule_update',
      'apim:gov_policy_read',
      'apim:gov_policy_manage',
      'apim:gov_policy_create',
      'apim:gov_policy_update',
      'apim:label_view',
      'apim:label_create',
      'apim:label_update',
      'apim:label_manage'
    ].join(' ')
  );

  const token = await http(`${APIM_URL}/oauth2/token`, {
    method: 'POST',
    basic: `${dcr.data.clientId}:${dcr.data.clientSecret}`,
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded'
    },
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
  });

  return getList(result.data);
}

async function findRuleset(token, name) {
  const query = encodeURIComponent(`name:${name}`);

  const result = await http(`${APIM_URL}/api/am/governance/v1/rulesets?query=${query}&limit=100`, {
    bearer: token
  }, [200]);

  return byName(getList(result.data), name) || byName(await listRulesets(token), name);
}

async function createRuleset(token) {
  const filePath = path.join(RULESET_ROOT, RULESET.file);

  if (!fs.existsSync(filePath)) {
    throw new Error(`OPA APIM ruleset file not found: ${filePath}`);
  }

  const existing = await findRuleset(token, RULESET.name);

  if (existing?.id) {
    log(`ruleset already exists in APIM Admin: ${RULESET.name}`);
    return existing;
  }

  const content = fs.readFileSync(filePath, 'utf8');

  const form = new FormData();
  form.set('name', RULESET.name);
  form.set('description', RULESET.description);
  form.set('ruleCategory', 'SPECTRAL');
  form.set('ruleType', RULESET.ruleType);
  form.set('artifactType', RULESET.artifactType);
  form.set('documentationLink', RULESET.documentationLink);
  form.set('provider', RULESET.provider);
  form.set('rulesetContent', new Blob([content], { type: 'application/json' }), RULESET.file);

  const created = await http(`${APIM_URL}/api/am/governance/v1/rulesets`, {
    method: 'POST',
    bearer: token,
    body: form
  }, [200, 201, 202, 409]);

  if (created.status === 409) {
    log(`ruleset already exists in APIM Admin: ${RULESET.name}`);
    return findRuleset(token, RULESET.name);
  }

  log(`created APIM Admin ruleset: ${RULESET.name}`);
  return created.data;
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

async function createOrGetLabel(token) {
  const existing = await findLabel(token, LABEL.name);

  if (existing?.id) {
    log(`label already exists in APIM Admin: ${LABEL.name}`);
    return existing;
  }

  const created = await http(`${APIM_URL}/api/am/admin/v4/labels`, {
    method: 'POST',
    bearer: token,
    json: LABEL
  }, [200, 201, 202, 409]);

  if (created.status === 409) {
    return findLabel(token, LABEL.name);
  }

  log(`created APIM Admin label: ${LABEL.name}`);
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

async function createOrUpdatePolicy(token, ruleset, label) {
  if (!ruleset?.id) {
    throw new Error(`Ruleset ID was not resolved for ${RULESET.name}`);
  }

  if (!label?.id) {
    throw new Error(`Label ID was not resolved for ${LABEL.name}`);
  }

  const payload = {
    name: POLICY.name,
    description: POLICY.description,
    governableStates: POLICY.governableStates,
    actions: POLICY.actions,
    rulesets: [ruleset.id],
    labels: [label.id]
  };

  const existing = await findPolicy(token, POLICY.name);

  if (existing?.id) {
    const updated = Object.assign({}, existing, payload, {
      id: existing.id
    });

    await http(`${APIM_URL}/api/am/governance/v1/policies/${existing.id}`, {
      method: 'PUT',
      bearer: token,
      json: updated
    }, [200, 201, 202]);

    log(`updated APIM Admin governance policy: ${POLICY.name}`);
    return updated;
  }

  const created = await http(`${APIM_URL}/api/am/governance/v1/policies`, {
    method: 'POST',
    bearer: token,
    json: payload
  }, [200, 201, 202, 409]);

  if (created.status === 409) {
    log(`governance policy already exists in APIM Admin: ${POLICY.name}`);
    return findPolicy(token, POLICY.name);
  }

  log(`created APIM Admin governance policy: ${POLICY.name}`);
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

function upsertAdditionalProperties(api, properties) {
  const current = Array.isArray(api.additionalProperties) ? api.additionalProperties : [];
  const byName = new Map();

  for (const prop of current) {
    if (prop?.name) {
      byName.set(String(prop.name).toLowerCase(), {
        name: String(prop.name),
        value: String(prop.value ?? ''),
        display: prop.display !== false
      });
    }
  }

  for (const [name, value] of Object.entries(properties)) {
    byName.set(String(name).toLowerCase(), {
      name,
      value: String(value),
      display: true
    });
  }

  api.additionalProperties = Array.from(byName.values());
  return api;
}

async function attachLabelAndMetadataToApi(token, apiName, label) {
  const apiSummary = await findPublisherApiByName(token, apiName);

  if (!apiSummary?.id) {
    log(`API not found for OPA governance label, skipping: ${apiName}`);
    return {
      apiName,
      status: 'NOT_FOUND'
    };
  }

  const api = await http(`${APIM_URL}/api/am/publisher/v4/apis/${apiSummary.id}`, {
    bearer: token
  }, [200]);

  const currentLabels = await getApiLabels(token, apiSummary.id);

  if (!currentLabels.some(existing => existing.id === label.id || existing.name === label.name)) {
    await http(`${APIM_URL}/api/am/publisher/v4/apis/${apiSummary.id}/attach-labels`, {
      method: 'POST',
      bearer: token,
      json: {
        labels: [label.id]
      }
    }, [200, 201, 202]);

    log(`attached OPA governance label to API: ${apiName}`);
  } else {
    log(`API already has OPA governance label: ${apiName}`);
  }

  const updated = upsertAdditionalProperties(api.data, {
    OpaGovernanceDecisionPoint: 'OPA',
    OpaGovernancePolicy: POLICY.name,
    OpaCommercialProductValidation: 'enabled',
    OpaOpenGatewayRiskValidation: 'enabled',
    OpaRegionalGatewayValidation: 'enabled',
    OpaValidationStory: 'OPA validates commercial product metadata, high-risk Open Gateway controls and regional/federated gateway readiness.',
    OpaLastAdminUpload: new Date().toISOString()
  });

  await http(`${APIM_URL}/api/am/publisher/v4/apis/${apiSummary.id}`, {
    method: 'PUT',
    bearer: token,
    json: updated
  }, [200, 201, 202]);

  log(`attached OPA governance metadata to API: ${apiName}`);

  return {
    apiName,
    apiId: apiSummary.id,
    status: 'UPDATED'
  };
}

async function main() {
  const token = await getAdminToken();

  const ruleset = await createRuleset(token);
  const label = await createOrGetLabel(token);
  const policy = await createOrUpdatePolicy(token, ruleset, label);

  const assignments = [];

  for (const apiName of API_LABEL_ASSIGNMENTS) {
    assignments.push(await attachLabelAndMetadataToApi(token, apiName, label));
  }

  const state = {
    generatedAt: new Date().toISOString(),
    apimUrl: APIM_URL,
    ruleset: {
      name: RULESET.name,
      id: ruleset?.id || null
    },
    label: {
      name: LABEL.name,
      id: label?.id || null
    },
    policy: {
      name: POLICY.name,
      id: policy?.id || null
    },
    assignments,
    story: 'OPA is external policy-as-code. APIM Admin receives a visible governance ruleset and policy automatically so the telco platform team can see OPA governance evidence in the APIM admin/governance model.'
  };

  fs.mkdirSync(path.dirname(STATE_FILE), {
    recursive: true
  });

  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));

  log(`wrote APIM OPA admin upload state: ${STATE_FILE}`);
  log('completed.');
}

main().catch(error => {
  console.error(`[APIM OPA admin upload] failed: ${error.stack || error.message}`);
  process.exitCode = 1;
});
