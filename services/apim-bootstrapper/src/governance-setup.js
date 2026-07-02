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
    file: 'telco-rest-commercial-guardrails.json'
  },
  {
    name: 'Telco Async Event Guardrails',
    description: 'Demo AsyncAPI/SSE governance rules for event classification, retention, monetization and channel address quality.',
    ruleType: 'API_DEFINITION',
    artifactType: 'ASYNC_API',
    file: 'telco-async-event-guardrails.json'
  },
  {
    name: 'Telco API Metadata Guardrails',
    description: 'Demo API metadata governance rules for product mapping, health check details and business ownership.',
    ruleType: 'API_METADATA',
    artifactType: 'REST_API',
    file: 'telco-rest-metadata-guardrails.json'
  }
];

function log(message) {
  console.log(`[APIM governance setup] ${message}`);
}

async function http(url, opts = {}, ok = [200, 201, 202, 204, 409]) {
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
      'apim:api_publish'
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

async function listRulesets(token) {
  try {
    const result = await http(`${APIM_URL}/api/am/governance/v1/rulesets?limit=1000`, {
      bearer: token
    }, [200]);

    const list = result.data?.list || result.data?.data || result.data?.rulesets || [];
    return Array.isArray(list) ? list : [];
  } catch (e) {
    log(`could not list existing governance rulesets: ${e.message}`);
    return [];
  }
}

function rulesetExists(existing, name) {
  return existing.some(item => {
    const candidate =
      item.name ||
      item.rulesetName ||
      item.displayName ||
      item.title;
    return candidate === name;
  });
}

async function createRuleset(token, spec) {
  const filePath = path.join(RULESET_ROOT, spec.file);

  if (!fs.existsSync(filePath)) {
    log(`ruleset file missing, skipping: ${filePath}`);
    return;
  }

  const content = fs.readFileSync(filePath, 'utf8');
  const parsed = JSON.parse(content);

  const endpoint = `${APIM_URL}/api/am/governance/v1/rulesets`;

  const attempts = [
    {
      label: 'json-ruleContent',
      request: () => http(endpoint, {
        method: 'POST',
        bearer: token,
        json: {
          name: spec.name,
          description: spec.description,
          ruleType: spec.ruleType,
          artifactType: spec.artifactType,
          ruleContent: content
        }
      })
    },
    {
      label: 'json-rulesetContent',
      request: () => http(endpoint, {
        method: 'POST',
        bearer: token,
        json: {
          name: spec.name,
          description: spec.description,
          ruleType: spec.ruleType,
          artifactType: spec.artifactType,
          rulesetContent: content
        }
      })
    },
    {
      label: 'json-rules-object',
      request: () => http(endpoint, {
        method: 'POST',
        bearer: token,
        json: {
          name: spec.name,
          description: spec.description,
          ruleType: spec.ruleType,
          artifactType: spec.artifactType,
          rules: parsed.rules
        }
      })
    },
    {
      label: 'multipart-rulesetInfo-file',
      request: () => {
        const form = new FormData();
        form.set('rulesetInfo', JSON.stringify({
          name: spec.name,
          description: spec.description,
          ruleType: spec.ruleType,
          artifactType: spec.artifactType
        }));
        form.set('file', new Blob([content], { type: 'application/json' }), spec.file);

        return http(endpoint, {
          method: 'POST',
          bearer: token,
          body: form
        });
      }
    },
    {
      label: 'multipart-fields-file',
      request: () => {
        const form = new FormData();
        form.set('name', spec.name);
        form.set('description', spec.description);
        form.set('ruleType', spec.ruleType);
        form.set('artifactType', spec.artifactType);
        form.set('file', new Blob([content], { type: 'application/json' }), spec.file);

        return http(endpoint, {
          method: 'POST',
          bearer: token,
          body: form
        });
      }
    }
  ];

  let lastError = null;

  for (const attempt of attempts) {
    try {
      const result = await attempt.request();

      if (result.status === 409) {
        log(`ruleset already exists: ${spec.name}`);
        return;
      }

      log(`created ruleset: ${spec.name} via ${attempt.label}`);
      return;
    } catch (e) {
      lastError = e;
      log(`ruleset create attempt failed for ${spec.name} via ${attempt.label}: ${e.message}`);
    }
  }

  throw lastError || new Error(`Could not create ruleset ${spec.name}`);
}

async function main() {
  if (!fs.existsSync(RULESET_ROOT)) {
    log(`ruleset root does not exist: ${RULESET_ROOT}`);
    return;
  }

  const token = await getAdminToken();
  const existing = await listRulesets(token);

  for (const spec of RULESETS) {
    if (rulesetExists(existing, spec.name)) {
      log(`ruleset already exists: ${spec.name}`);
      continue;
    }

    await createRuleset(token, spec);
  }

  const after = await listRulesets(token);
  const telco = after
    .map(r => r.name || r.rulesetName || r.displayName || r.title)
    .filter(Boolean)
    .filter(name => name.includes('Telco'));

  log(`visible Telco rulesets: ${telco.length ? telco.join(', ') : 'none found by list API'}`);
  log('completed.');
}

main().catch(e => {
  console.error(`[APIM governance setup] failed: ${e.stack || e.message}`);
  process.exitCode = 1;
});

