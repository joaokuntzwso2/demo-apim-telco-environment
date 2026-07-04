const fs = require('fs');
const path = require('path');
const { fetch } = require('undici');

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const APIM_URL = process.env.WSO2_APIM_URL || 'https://wso2-apim:9443';
const USERNAME = process.env.APIM_USERNAME || 'admin';
const PASSWORD = process.env.APIM_PASSWORD || 'admin';

const CUSTOM_POLICIES_FILE =
  process.env.SIDDHI_CUSTOM_POLICIES_FILE ||
  '/workspace/artifacts/apim-admin/custom-throttling-policies/telco-siddhi-custom-policies.json';

const STATE_FILE =
  process.env.SIDDHI_CUSTOM_POLICIES_STATE_FILE ||
  '/workspace/state/siddhi-custom-throttling-policies-upload.json';

const CUSTOM_POLICY_ENDPOINT = '/api/am/admin/v4/throttling/policies/custom';
const VALIDATE_ONLY = process.argv.includes('--validate-only');

function log(message) {
  console.log(`[APIM Siddhi custom policies] ${message}`);
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

  const response = await fetch(url, {
    method: opts.method || 'GET',
    headers,
    body
  });

  const text = await response.text();

  let data = text;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }

  if (!ok.includes(response.status)) {
    const rendered = typeof data === 'string' ? data : JSON.stringify(data, null, 2);
    throw new Error(`${opts.method || 'GET'} ${url} -> HTTP ${response.status}: ${rendered}`);
  }

  return {
    status: response.status,
    data
  };
}

async function getAdminToken() {
  const dcr = await http(`${APIM_URL}/client-registration/v0.17/register`, {
    method: 'POST',
    basic: `${USERNAME}:${PASSWORD}`,
    json: {
      callbackUrl: 'http://localhost:8080/callback',
      clientName: `telco-demo-siddhi-custom-policies-${Date.now()}`,
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
    'apim:admin',
    'apim:tier_view',
    'apim:tier_manage',
    'apim:admin_tier_view',
    'apim:admin_tier_manage',
    'apim:admin_tier_create',
    'apim:admin_tier_update'
  ].join(' '));

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
  if (Array.isArray(data.policies)) return data.policies;
  return [];
}

function getPolicyId(policy) {
  return policy?.policyId || policy?.id || policy?.ruleId || null;
}

async function listCustomPolicies(token) {
  const result = await http(`${APIM_URL}${CUSTOM_POLICY_ENDPOINT}?limit=1000`, {
    bearer: token
  }, [200]);

  return getList(result.data);
}

async function findCustomPolicy(token, policyName) {
  const list = await listCustomPolicies(token);
  return list.find(item => item.policyName === policyName || item.name === policyName) || null;
}

function validatePolicyShape(policy) {
  const failures = [];

  if (!policy.policyName) failures.push('policyName is required');
  if (!policy.description) failures.push('description is required');
  if (!policy.keyTemplate) failures.push('keyTemplate is required');
  if (!policy.siddhiQuery) failures.push('siddhiQuery is required');

  if (!String(policy.siddhiQuery || '').includes('RequestStream')) {
    failures.push('siddhiQuery must read from RequestStream');
  }

  if (!String(policy.siddhiQuery || '').includes('EligibilityStream')) {
    failures.push('siddhiQuery must insert into EligibilityStream');
  }

  if (!String(policy.siddhiQuery || '').includes('ResultStream')) {
    failures.push('siddhiQuery must insert into ResultStream');
  }

  if (!String(policy.siddhiQuery || '').includes('throttleKey')) {
    failures.push('siddhiQuery must generate throttleKey');
  }

  if (!String(policy.siddhiQuery || '').includes('#throttler:timeBatch')) {
    failures.push('siddhiQuery must use #throttler:timeBatch');
  }

  return failures;
}

async function createOrUpdateCustomPolicy(token, policy) {
  const shapeFailures = validatePolicyShape(policy);

  if (shapeFailures.length) {
    throw new Error(`Invalid custom policy ${policy.policyName}: ${shapeFailures.join(', ')}`);
  }

  const payload = {
    policyName: policy.policyName,
    displayName: policy.displayName || policy.policyName,
    description: policy.description,
    keyTemplate: policy.keyTemplate,
    siddhiQuery: policy.siddhiQuery,
    isDeployed: policy.isDeployed !== false
  };

  const existing = await findCustomPolicy(token, policy.policyName);
  const existingId = getPolicyId(existing);

  if (existingId) {
    await http(`${APIM_URL}${CUSTOM_POLICY_ENDPOINT}/${existingId}`, {
      method: 'PUT',
      bearer: token,
      json: Object.assign({}, existing, payload, {
        policyId: existingId
      })
    }, [200, 201, 202]);

    log(`updated Admin Custom Policy: ${policy.policyName}`);

    return {
      policyName: policy.policyName,
      policyId: existingId,
      action: 'UPDATED'
    };
  }

  const created = await http(`${APIM_URL}${CUSTOM_POLICY_ENDPOINT}`, {
    method: 'POST',
    bearer: token,
    json: payload
  }, [200, 201, 202, 409]);

  if (created.status === 409) {
    const found = await findCustomPolicy(token, policy.policyName);
    log(`Admin Custom Policy already exists: ${policy.policyName}`);

    return {
      policyName: policy.policyName,
      policyId: getPolicyId(found),
      action: 'EXISTS'
    };
  }

  log(`created Admin Custom Policy: ${policy.policyName}`);

  return {
    policyName: policy.policyName,
    policyId: getPolicyId(created.data),
    action: 'CREATED'
  };
}

function readPolicies() {
  if (!fs.existsSync(CUSTOM_POLICIES_FILE)) {
    throw new Error(`Custom Siddhi policies file not found: ${CUSTOM_POLICIES_FILE}`);
  }

  const parsed = JSON.parse(fs.readFileSync(CUSTOM_POLICIES_FILE, 'utf8'));

  if (!Array.isArray(parsed) || parsed.length === 0) {
    throw new Error(`Custom Siddhi policies file must contain a non-empty array.`);
  }

  return parsed;
}

async function validateUploadedPolicies(token, expectedPolicies) {
  const adminPolicies = await listCustomPolicies(token);

  return expectedPolicies.map(expected => {
    const found = adminPolicies.find(item => item.policyName === expected.policyName || item.name === expected.policyName);
    const foundQuery = String(found?.siddhiQuery || '');

    const checks = {
      existsInAdmin: Boolean(found),
      hasPolicyId: Boolean(getPolicyId(found)),
      keyTemplateMatches: found?.keyTemplate === expected.keyTemplate,
      hasRequestStream: foundQuery.includes('RequestStream'),
      hasEligibilityStream: foundQuery.includes('EligibilityStream'),
      hasResultStream: foundQuery.includes('ResultStream'),
      hasThrottleKey: foundQuery.includes('throttleKey'),
      hasThrottlerWindow: foundQuery.includes('#throttler:timeBatch')
    };

    return {
      policyName: expected.policyName,
      displayName: expected.displayName,
      policyId: getPolicyId(found),
      allow: Object.values(checks).every(Boolean),
      checks,
      businessStory: expected.businessStory
    };
  });
}

async function main() {
  const expectedPolicies = readPolicies();
  const token = await getAdminToken();

  const uploads = [];

  if (!VALIDATE_ONLY) {
    for (const policy of expectedPolicies) {
      uploads.push(await createOrUpdateCustomPolicy(token, policy));
    }
  } else {
    log('validate-only mode; skipping create/update.');
  }

  const validations = await validateUploadedPolicies(token, expectedPolicies);
  const failures = validations.filter(item => !item.allow);

  for (const validation of validations) {
    log(`${validation.allow ? 'PASS' : 'FAIL'} ${validation.policyName}`);
  }

  const state = {
    generatedAt: new Date().toISOString(),
    apimUrl: APIM_URL,
    endpoint: CUSTOM_POLICY_ENDPOINT,
    mode: VALIDATE_ONLY ? 'validate-only' : 'upload-and-validate',
    uploads,
    validations,
    allow: failures.length === 0,
    story: 'Siddhi custom throttling policies are uploaded into APIM Admin under Rate Limiting Policies > Custom Policies to make event-governance controls visible as native APIM custom policies.'
  };

  fs.mkdirSync(path.dirname(STATE_FILE), {
    recursive: true
  });

  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));

  log(`wrote state: ${STATE_FILE}`);
  log(`summary: policies=${validations.length}, failures=${failures.length}`);

  if (failures.length) {
    throw new Error(`Siddhi custom policy validation failed for: ${failures.map(item => item.policyName).join(', ')}`);
  }
}

main().catch(error => {
  console.error(`[APIM Siddhi custom policies] failed: ${error.stack || error.message}`);
  process.exitCode = 1;
});
