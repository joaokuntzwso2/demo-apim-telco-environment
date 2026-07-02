const fs = require('fs');
const path = require('path');
const { fetch } = require('undici');

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const APIM_URL = process.env.WSO2_APIM_URL || 'https://wso2-apim:9443';
const USERNAME = process.env.APIM_USERNAME || 'admin';
const PASSWORD = process.env.APIM_PASSWORD || 'admin';

const COMMERCIAL_PLANS_FILE =
  process.env.APIM_COMMERCIAL_PLANS_FILE ||
  '/workspace/artifacts/apim-admin/commercial-plans.json';

const API_PLAN_ASSIGNMENTS = {
  TelcoBusinessCatalogAPI: ['TelcoFreeTrial', 'TelcoPartnerStandard', 'TelcoPartnerPremium'],
  Customer360API: ['TelcoFreeTrial', 'TelcoPartnerStandard', 'TelcoPartnerPremium'],
  NumberLifecycleAPI: ['TelcoFreeTrial', 'TelcoPartnerStandard', 'TelcoPartnerPremium'],
  NetworkSliceAPI: ['TelcoPartnerStandard', 'TelcoPartnerPremium'],
  PartnerChargingAPI: ['TelcoPartnerStandard', 'TelcoPartnerPremium'],
  BillingAdjustmentSOAP: ['TelcoFreeTrial', 'TelcoPartnerStandard'],
  NetworkEventsStreamAPI: ['TelcoFreeTrial', 'TelcoEventStreamPremium']
};

function log(message) {
  console.log(`[APIM admin setup] ${message}`);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
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

async function getAdminToken() {
  const dcr = await http(`${APIM_URL}/client-registration/v0.17/register`, {
    method: 'POST',
    basic: `${USERNAME}:${PASSWORD}`,
    json: {
      callbackUrl: 'http://localhost:8080/callback',
      clientName: `telco-demo-admin-setup-${Date.now()}`,
      owner: USERNAME,
      grantType: 'password refresh_token client_credentials',
      saasApp: true
    }
  });

  const form = new URLSearchParams();
  form.set('grant_type', 'password');
  form.set('username', USERNAME);
  form.set('password', PASSWORD);
  form.set(
    'scope',
    [
      'apim:admin',
      'apim:tier_view',
      'apim:tier_manage',
      'apim:admin_tier_view',
      'apim:admin_tier_manage',
      'apim:admin_tier_create',
      'apim:admin_tier_update',
      'apim:api_view',
      'apim:api_create',
      'apim:api_manage',
      'apim:api_publish',
      'apim:subscription_view'
    ].join(' ')
  );

  const token = await http(`${APIM_URL}/oauth2/token`, {
    method: 'POST',
    basic: `${dcr.clientId}:${dcr.clientSecret}`,
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: form.toString()
  });

  return token.access_token;
}

function toSubscriptionPolicy(plan) {
  return {
    policyName: plan.policyName,
    displayName: plan.displayName || plan.policyName,
    description: plan.description || `${plan.displayName || plan.policyName} demo business plan`,
    isDeployed: true,
    graphQLMaxComplexity: plan.graphQLMaxComplexity || 0,
    graphQLMaxDepth: plan.graphQLMaxDepth || 0,
    defaultLimit: {
      type: 'REQUESTCOUNTLIMIT',
      requestCount: {
        timeUnit: plan.timeUnit || 'min',
        unitTime: plan.unitTime || 1,
        requestCount: plan.requestCount || 1000
      }
    },
    rateLimitCount: 0,
    customAttributes: [],
    stopOnQuotaReach: plan.stopOnQuotaReach !== false,
    billingPlan: plan.billingPlan || 'FREE'
  };
}

async function loadExistingSubscriptionPolicies(token) {
  const result = await http(
    `${APIM_URL}/api/am/admin/v4/throttling/policies/subscription?limit=1000`,
    { bearer: token }
  );

  return result.list || result.data || [];
}

async function createCommercialPlans(token) {
  if (!fs.existsSync(COMMERCIAL_PLANS_FILE)) {
    log(`commercial plans file not found: ${COMMERCIAL_PLANS_FILE}`);
    return [];
  }

  const plans = JSON.parse(fs.readFileSync(COMMERCIAL_PLANS_FILE, 'utf8'));
  const existing = await loadExistingSubscriptionPolicies(token);
  const existingNames = new Set(existing.map(p => p.policyName || p.name));

  for (const plan of plans) {
    if (existingNames.has(plan.policyName)) {
      log(`subscription policy already exists: ${plan.policyName}`);
      continue;
    }

    const payload = toSubscriptionPolicy(plan);

    await http(`${APIM_URL}/api/am/admin/v4/throttling/policies/subscription`, {
      method: 'POST',
      bearer: token,
      json: payload
    });

    log(`created subscription policy: ${plan.policyName} (${plan.billingPlan})`);
  }

  return plans.map(p => p.policyName);
}

async function listPublisherApis(token) {
  const result = await http(`${APIM_URL}/api/am/publisher/v4/apis?limit=1000`, {
    bearer: token
  });

  return result.list || result.data || [];
}

async function attachPlansToPublishedApis(token) {
  const apis = await listPublisherApis(token);

  for (const apiSummary of apis) {
    const planNames = API_PLAN_ASSIGNMENTS[apiSummary.name];

    if (!planNames || !apiSummary.id) {
      continue;
    }

    try {
      const api = await http(`${APIM_URL}/api/am/publisher/v4/apis/${apiSummary.id}`, {
        bearer: token
      });

      const current = Array.isArray(api.policies) ? api.policies : [];
      const updated = Array.from(new Set([...current, ...planNames]));

      api.policies = updated;

      await http(`${APIM_URL}/api/am/publisher/v4/apis/${apiSummary.id}`, {
        method: 'PUT',
        bearer: token,
        json: api
      });

      log(`attached plans to ${apiSummary.name}: ${planNames.join(', ')}`);
    } catch (e) {
      log(`could not attach plans to ${apiSummary.name}: ${e.message}`);
    }
  }
}

async function bestEffortEnableMonetizationLabels(token) {
  // This is intentionally best-effort because the tenant advanced-settings API
  // has varied across APIM versions. Commercial plans are created even if this
  // endpoint is unavailable.
  const candidates = [
    `${APIM_URL}/api/am/admin/v4/settings`,
    `${APIM_URL}/api/am/admin/v4/settings/advanced`
  ];

  for (const url of candidates) {
    try {
      const settings = await http(url, { bearer: token }, [200]);
      if (!settings || typeof settings !== 'object' || Array.isArray(settings)) {
        continue;
      }

      settings.EnableMonetization = true;
      settings.IsUnlimitedTierPaid = false;

      await http(url, {
        method: 'PUT',
        bearer: token,
        json: settings
      }, [200, 201, 202, 204]);

      log(`enabled monetization labels through ${url}`);
      return;
    } catch (e) {
      log(`monetization settings endpoint not available at ${url}`);
    }
  }

  log('commercial plans are available; enable monetization labels manually in Admin → Settings → Advanced if needed.');
}

async function main() {
  // APIM is already up by the time bootstrap.js finishes, but give the indexers
  // and admin APIs a small grace period.
  await sleep(3000);

  const token = await getAdminToken();

  await createCommercialPlans(token);
  await attachPlansToPublishedApis(token);
  await bestEffortEnableMonetizationLabels(token);

  log('completed.');
}

main().catch(e => {
  console.error(`[APIM admin setup] failed: ${e.stack || e.message}`);
  process.exitCode = 1;
});
