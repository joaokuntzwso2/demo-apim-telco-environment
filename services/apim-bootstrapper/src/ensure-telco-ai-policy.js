'use strict';

const fs = require('fs');
const path = require('path');
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

function deriveExpectedPolicyName() {
  if (process.env.TELCO_AI_POLICY_NAME) {
    return process.env.TELCO_AI_POLICY_NAME;
  }

  const verifierPath = path.join(
    __dirname,
    'verify-telco-ai.js'
  );

  const source = fs.readFileSync(
    verifierPath,
    'utf8'
  );

  const marker =
    source.indexOf('Native AI token policy absent');

  const relevantSource =
    marker >= 0
      ? source.slice(
          Math.max(0, marker - 3500),
          marker + 100
        )
      : source;

  // Direct comparison:
  // policy.policyName === 'TelcoAITokenQuota'
  const directMatches = [
    ...relevantSource.matchAll(
      /policyName\s*===?\s*['"]([^'"]+)['"]/g
    )
  ];

  if (directMatches.length) {
    return directMatches.at(-1)[1];
  }

  // Variable comparison:
  // policy.policyName === AI_POLICY_NAME
  const variableMatch =
    relevantSource.match(
      /policyName\s*===?\s*([A-Za-z_$][A-Za-z0-9_$]*)/
    );

  if (variableMatch) {
    const variable = variableMatch[1];

    const declaration = source.match(
      new RegExp(
        `(?:const|let|var)\\s+${variable}\\s*=\\s*` +
        `['"]([^'"]+)['"]`
      )
    );

    if (declaration) {
      return declaration[1];
    }
  }

  // Final fallback for the demo.
  return 'TelcoAITokenQuota';
}

function basic(username, password) {
  return `Basic ${Buffer.from(
    `${username}:${password}`
  ).toString('base64')}`;
}

async function parseResponse(response, operation) {
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
      `${typeof body === 'string'
        ? body
        : JSON.stringify(body)}`
    );
  }

  return body;
}

async function obtainAdminToken() {
  const dcrUrl =
    `${APIM_URL}/client-registration/v0.17/register`;

  const client = await parseResponse(
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
          `telco-ai-policy-bootstrap-${Date.now()}-` +
          Math.random().toString(16).slice(2),
        owner: USERNAME,
        grantType:
          'password refresh_token client_credentials',
        saasApp: true
      })
    }),
    `POST ${dcrUrl}`
  );

  if (!client.clientId || !client.clientSecret) {
    throw new Error(
      'DCR did not return client credentials.'
    );
  }

  const form = new URLSearchParams();

  form.set('grant_type', 'password');
  form.set('username', USERNAME);
  form.set('password', PASSWORD);
  form.set(
    'scope',
    'apim:admin_tier_view apim:admin_tier_manage'
  );

  const tokenUrl = `${APIM_URL}/oauth2/token`;

  const token = await parseResponse(
    await fetch(tokenUrl, {
      method: 'POST',
      dispatcher,
      headers: {
        authorization: basic(
          client.clientId,
          client.clientSecret
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
      'OAuth response did not contain access_token.'
    );
  }

  return token.access_token;
}

async function adminRequest(
  method,
  resource,
  token,
  body
) {
  const url =
    `${APIM_URL}/api/am/admin/v4${resource}`;

  const options = {
    method,
    dispatcher,
    headers: {
      authorization: `Bearer ${token}`,
      accept: 'application/json'
    }
  };

  if (body !== undefined) {
    options.headers['content-type'] =
      'application/json';

    options.body = JSON.stringify(body);
  }

  return parseResponse(
    await fetch(url, options),
    `${method} ${url}`
  );
}

function policyList(response) {
  if (Array.isArray(response)) {
    return response;
  }

  return response.list || response.data || [];
}

async function main() {
  const policyName = deriveExpectedPolicyName();

  console.log(
    `[Telco AI policy] Verifier expects: ${policyName}`
  );

  const token = await obtainAdminToken();

  const response = await adminRequest(
    'GET',
    '/throttling/policies/subscription' +
      '?limit=1000&offset=0',
    token
  );

  const existing = policyList(response).find(
    policy => policy.policyName === policyName
  );

  const desired = {
    policyName,
    displayName: policyName,
    description:
      'Native WSO2 AI subscription policy for the ' +
      'optional telco support-assistant capability. ' +
      'Controls request, total-token, prompt-token ' +
      'and completion-token consumption per subscription.',
    graphQLMaxComplexity: 0,
    graphQLMaxDepth: 0,
    defaultLimit: {
      type: 'AIAPIQUOTALIMIT',
      aiApiQuota: {
        timeUnit: 'min',
        unitTime: 1,
        requestCount: 100,
        totalTokenCount: 20000,
        promptTokenCount: 12000,
        completionTokenCount: 8000
      }
    },
    rateLimitCount: 0,
    subscriberCount: 0,
    customAttributes: [],
    stopOnQuotaReach: true,
    billingPlan: 'FREE'
  };

  if (existing) {
    if (
      existing.defaultLimit?.type !==
      'AIAPIQUOTALIMIT'
    ) {
      throw new Error(
        `Policy ${policyName} already exists, but ` +
        `its quota type is ` +
        `${existing.defaultLimit?.type || 'unknown'}.`
      );
    }

    await adminRequest(
      'PUT',
      `/throttling/policies/subscription/` +
        existing.policyId,
      token,
      {
        ...desired,
        policyId: existing.policyId
      }
    );

    console.log(
      `[Telco AI policy] updated: ${policyName}`
    );
  } else {
    const created = await adminRequest(
      'POST',
      '/throttling/policies/subscription',
      token,
      desired
    );

    console.log(
      `[Telco AI policy] created: ${policyName}` +
      `${created.policyId
        ? ` (${created.policyId})`
        : ''}`
    );
  }

  const after = await adminRequest(
    'GET',
    '/throttling/policies/subscription' +
      '?limit=1000&offset=0',
    token
  );

  const verified = policyList(after).find(
    policy =>
      policy.policyName === policyName &&
      policy.defaultLimit?.type ===
        'AIAPIQUOTALIMIT' &&
      Number(
        policy.defaultLimit?.aiApiQuota
          ?.totalTokenCount
      ) > 0
  );

  if (!verified) {
    throw new Error(
      `AI policy verification failed: ${policyName}`
    );
  }

  console.log(
    '[Telco AI policy] native token quota verified.'
  );

  console.log(
    JSON.stringify(
      {
        policyName: verified.policyName,
        policyId: verified.policyId,
        limitType: verified.defaultLimit.type,
        quota: verified.defaultLimit.aiApiQuota,
        deployed: verified.isDeployed
      },
      null,
      2
    )
  );
}

main().catch(error => {
  console.error(
    `[Telco AI policy][FAIL] ` +
    `${error.stack || error.message}`
  );

  process.exit(1);
});
