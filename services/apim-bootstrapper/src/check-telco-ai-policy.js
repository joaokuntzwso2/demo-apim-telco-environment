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

const JSON_MODE =
  process.argv.includes('--json');

function basic(username, password) {
  return `Basic ${Buffer.from(
    `${username}:${password}`
  ).toString('base64')}`;
}

async function readJson(response, operation) {
  const text = await response.text();

  if (!response.ok) {
    throw new Error(
      `${operation}: HTTP ${response.status} ${text}`
    );
  }

  return text ? JSON.parse(text) : {};
}

async function main() {
  const dcrUrl =
    `${APIM_URL}/client-registration/v0.17/register`;

  const client = await readJson(
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
          `telco-ai-policy-check-${Date.now()}-` +
          Math.random().toString(16).slice(2),
        owner: USERNAME,
        grantType:
          'password refresh_token client_credentials',
        saasApp: true
      })
    }),
    `POST ${dcrUrl}`
  );

  const form = new URLSearchParams();

  form.set('grant_type', 'password');
  form.set('username', USERNAME);
  form.set('password', PASSWORD);
  form.set(
    'scope',
    'apim:admin_tier_view apim:admin_tier_manage'
  );

  const tokenUrl = `${APIM_URL}/oauth2/token`;

  const token = await readJson(
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

  const policiesUrl =
    `${APIM_URL}/api/am/admin/v4/` +
    'throttling/policies/subscription' +
    '?limit=1000&offset=0';

  const response = await readJson(
    await fetch(policiesUrl, {
      dispatcher,
      headers: {
        authorization:
          `Bearer ${token.access_token}`,
        accept: 'application/json'
      }
    }),
    `GET ${policiesUrl}`
  );

  const policies = Array.isArray(response)
    ? response
    : response.list || response.data || [];

  const policy = policies.find(item =>
    item.policyName === 'TelcoAITokenQuota' &&
    item.defaultLimit?.type ===
      'AIAPIQUOTALIMIT' &&
    Number(
      item.defaultLimit?.aiApiQuota
        ?.totalTokenCount || 0
    ) > 0
  );

  if (!policy) {
    throw new Error(
      'TelcoAITokenQuota with AIAPIQUOTALIMIT was not found.'
    );
  }

  if (JSON_MODE) {
    process.stdout.write(
      JSON.stringify(policies)
    );
    return;
  }

  console.log(
    '[telco-ai-policy-check][PASS] ' +
    'Native AI token policy is present'
  );

  console.log(
    JSON.stringify(
      {
        policyName: policy.policyName,
        policyId: policy.policyId,
        limitType: policy.defaultLimit.type,
        quota: policy.defaultLimit.aiApiQuota,
        deployed: policy.isDeployed
      },
      null,
      2
    )
  );
}

main().catch(error => {
  console.error(
    `[telco-ai-policy-check][FAIL] ` +
    `${error.stack || error.message}`
  );

  process.exit(1);
});
