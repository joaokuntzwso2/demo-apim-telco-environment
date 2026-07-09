'use strict';

const { fetch, Agent } = require('undici');

const dispatcher = new Agent({
  connect: {
    rejectUnauthorized: false
  }
});

const APIM_URL =
  process.env.WSO2_APIM_URL ||
  process.env.APIM_URL ||
  'https://wso2-apim:9443';

const USERNAME =
  process.env.APIM_USERNAME ||
  process.env.APIM_USER ||
  'admin';

const PASSWORD =
  process.env.APIM_PASSWORD ||
  process.env.APIM_PASS ||
  'admin';

const PUBLISHER_API =
  `${APIM_URL}/api/am/publisher/v4`;

const DOCUMENTS = [
  {
    apiName: 'TelcoSupportAssistantAPI',
    apiVersion: '1.0.0',
    name: 'Telco AI Support Assistant Guide',
    type: 'HOWTO',
    summary:
      'Governed usage of the telco support assistant, AI safeguards, ' +
      'partner attribution and tool execution.',
    content: [
      '# Telco AI Support Assistant',
      '',
      'The assistant is an optional governed AI capability in the telco demo.',
      '',
      '## Governance controls',
      '',
      '- Token quota enforcement',
      '- Model-profile routing',
      '- Sensitive-data masking',
      '- Prompt-injection protection',
      '- Per-partner AI consumption tracking',
      '- Token and estimated-cost attribution',
      '',
      '## Agent operations',
      '',
      'The assistant does not access BSS or OSS systems directly.',
      'It invokes APIM-governed operations exposed by TelcoAgentToolsAPI.',
      '',
      'A caller must use the `telco_ai_support` OAuth scope.'
    ].join('\n')
  },
  {
    apiName: 'TelcoAgentToolsAPI',
    apiVersion: '1.0.0',
    name: 'Governed Telco Agent Tools',
    type: 'HOWTO',
    summary:
      'Governed tools available to the MI-based telco support agent.',
    content: [
      '# Governed Telco Agent Tools',
      '',
      'This API exposes controlled operations to AI agents and MCP clients.',
      '',
      '## Operations',
      '',
      '- Retrieve subscriber service status',
      '- Inspect an outage',
      '- Request a Quality-on-Demand session',
      '- Open a service ticket',
      '',
      'Each operation is protected by its own OAuth scope and invokes ' +
        'governed APIs rather than accessing BSS or OSS systems directly.'
    ].join('\n')
  }
];

function basic(username, password) {
  return `Basic ${Buffer.from(
    `${username}:${password}`
  ).toString('base64')}`;
}

async function readResponse(response, operation) {
  const text = await response.text();

  let body = {};

  if (text) {
    try {
      body = JSON.parse(text);
    } catch {
      body = text;
    }
  }

  if (!response.ok) {
    throw new Error(
      `${operation}: HTTP ${response.status} ` +
      `${typeof body === 'string' ? body : JSON.stringify(body)}`
    );
  }

  return body;
}

async function request(
  method,
  url,
  accessToken,
  body
) {
  const headers = {
    authorization: `Bearer ${accessToken}`,
    accept: 'application/json'
  };

  const options = {
    method,
    dispatcher,
    headers
  };

  if (body !== undefined) {
    headers['content-type'] = 'application/json';
    options.body = JSON.stringify(body);
  }

  return readResponse(
    await fetch(url, options),
    `${method} ${url}`
  );
}

async function obtainPublisherToken() {
  const dcrUrl =
    `${APIM_URL}/client-registration/v0.17/register`;

  const dcr = await readResponse(
    await fetch(dcrUrl, {
      method: 'POST',
      dispatcher,
      headers: {
        authorization: basic(USERNAME, PASSWORD),
        'content-type': 'application/json'
      },
      body: JSON.stringify({
        callbackUrl: 'http://localhost:8080/callback',
        clientName:
          `telco-ai-doc-bootstrap-${Date.now()}-` +
          Math.random().toString(16).slice(2),
        owner: USERNAME,
        grantType:
          'password refresh_token client_credentials',
        saasApp: true
      })
    }),
    `POST ${dcrUrl}`
  );

  if (!dcr.clientId || !dcr.clientSecret) {
    throw new Error(
      `DCR response did not contain client credentials: ` +
      JSON.stringify(dcr)
    );
  }

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
      'apim:app_manage',
      'apim:sub_manage',
      'apim:subscribe',
      'apim:api_key',
      'apim:api_generate_key'
    ].join(' ')
  );

  const tokenUrl = `${APIM_URL}/oauth2/token`;

  const token = await readResponse(
    await fetch(tokenUrl, {
      method: 'POST',
      dispatcher,
      headers: {
        authorization: basic(
          dcr.clientId,
          dcr.clientSecret
        ),
        'content-type':
          'application/x-www-form-urlencoded'
      },
      body: form.toString()
    }),
    `POST ${tokenUrl}`
  );

  if (!token.access_token) {
    throw new Error(
      `OAuth response did not contain access_token: ` +
      JSON.stringify(token)
    );
  }

  return token.access_token;
}

function responseList(response) {
  if (Array.isArray(response)) {
    return response;
  }

  return response.list || response.data || [];
}

async function findApi(accessToken, name, version) {
  const response = await request(
    'GET',
    `${PUBLISHER_API}/apis?limit=1000&offset=0`,
    accessToken
  );

  return responseList(response).find(api =>
    api.name === name &&
    String(api.version) === String(version)
  );
}

async function ensureDocument(accessToken, definition) {
  const api = await findApi(
    accessToken,
    definition.apiName,
    definition.apiVersion
  );

  if (!api) {
    throw new Error(
      `API not found: ${definition.apiName} ` +
      definition.apiVersion
    );
  }

  const documentsUrl =
    `${PUBLISHER_API}/apis/${api.id}/documents`;

  const existingResponse = await request(
    'GET',
    documentsUrl,
    accessToken
  );

  const existing = responseList(existingResponse).find(
    document => document.name === definition.name
  );

  if (existing) {
    console.log(
      `[Telco AI docs] already present: ` +
      `${definition.apiName} -> ${definition.name}`
    );
    return;
  }

  const created = await request(
    'POST',
    documentsUrl,
    accessToken,
    {
      name: definition.name,
      type: definition.type,
      summary: definition.summary,
      sourceType: 'INLINE',
      inlineContent: definition.content,
      visibility: 'API_LEVEL'
    }
  );

  console.log(
    `[Telco AI docs] created: ` +
    `${definition.apiName} -> ${definition.name}` +
    `${created.documentId ? ` (${created.documentId})` : ''}`
  );
}

async function main() {
  const accessToken = await obtainPublisherToken();

  for (const definition of DOCUMENTS) {
    await ensureDocument(accessToken, definition);
  }

  console.log(
    '[Telco AI docs] documentation provisioning completed.'
  );
}

main().catch(error => {
  console.error(
    `[Telco AI docs][FAIL] ${error.stack || error.message}`
  );
  process.exit(1);
});
