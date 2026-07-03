const fs = require('fs');
const { fetch } = require('undici');

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const APIM_URL = process.env.WSO2_APIM_URL || 'https://wso2-apim:9443';
const USERNAME = process.env.APIM_USERNAME || 'admin';
const PASSWORD = process.env.APIM_PASSWORD || 'admin';

const PROPERTIES_FILE =
  process.env.APIM_API_MONETIZATION_PROPERTIES_FILE ||
  '/workspace/artifacts/apim-admin/api-monetization-properties.json';

function log(message) {
  console.log(`[APIM Moesif monetization setup] ${message}`);
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

  return data;
}

async function getToken() {
  const dcr = await http(`${APIM_URL}/client-registration/v0.17/register`, {
    method: 'POST',
    basic: `${USERNAME}:${PASSWORD}`,
    json: {
      callbackUrl: 'http://localhost:8080/callback',
      clientName: `telco-demo-moesif-monetization-${Date.now()}`,
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
      'apim:api_view',
      'apim:api_manage',
      'apim:api_update',
      'apim:api_metadata_view'
    ].join(' ')
  );

  const token = await http(`${APIM_URL}/oauth2/token`, {
    method: 'POST',
    basic: `${dcr.clientId}:${dcr.clientSecret}`,
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: form.toString()
  }, [200]);

  return token.access_token;
}

async function listApis(token) {
  const result = await http(`${APIM_URL}/api/am/publisher/v4/apis?limit=1000`, {
    bearer: token
  });

  return result.list || result.data || [];
}

function upsertAdditionalProperties(api, properties) {
  const currentArray = Array.isArray(api.additionalProperties)
    ? api.additionalProperties
    : [];

  const currentMap = api.additionalPropertiesMap && typeof api.additionalPropertiesMap === 'object'
    ? api.additionalPropertiesMap
    : {};

  const byName = new Map();

  for (const item of currentArray) {
    if (item && item.name) {
      byName.set(String(item.name).toLowerCase(), {
        name: item.name,
        value: String(item.value ?? ''),
        display: item.display !== false
      });
    }
  }

  for (const [name, item] of Object.entries(currentMap)) {
    if (name && item) {
      byName.set(String(name).toLowerCase(), {
        name,
        value: String(item.value ?? item ?? ''),
        display: item.display !== false
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

  const arr = Array.from(byName.values());

  api.additionalProperties = arr;
  api.additionalPropertiesMap = Object.fromEntries(
    arr.map(item => [
      item.name,
      {
        name: item.name,
        value: item.value,
        display: item.display !== false
      }
    ])
  );

  return api;
}

async function main() {
  if (!fs.existsSync(PROPERTIES_FILE)) {
    log(`properties file not found: ${PROPERTIES_FILE}`);
    return;
  }

  const token = await getToken();
  const mappings = JSON.parse(fs.readFileSync(PROPERTIES_FILE, 'utf8'));
  const apis = await listApis(token);

  for (const mapping of mappings) {
    const summary = apis.find(api => api.name === mapping.apiName);

    if (!summary?.id) {
      log(`API not found, skipping: ${mapping.apiName}`);
      continue;
    }

    const api = await http(`${APIM_URL}/api/am/publisher/v4/apis/${summary.id}`, {
      bearer: token
    });

    const updated = upsertAdditionalProperties(api, mapping.properties);

    await http(`${APIM_URL}/api/am/publisher/v4/apis/${summary.id}`, {
      method: 'PUT',
      bearer: token,
      json: updated
    }, [200, 201, 202]);

    log(`stored Moesif export properties for ${mapping.apiName}`);
  }

  log('completed.');
}

main().catch(e => {
  console.error(`[APIM Moesif monetization setup] failed: ${e.stack || e.message}`);
  process.exitCode = 1;
});
