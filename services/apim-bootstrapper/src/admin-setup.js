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


function normalizeBillingCycle(value) {
  const normalized = String(value || 'month').trim();

  const map = {
    MONTHLY: 'month',
    YEARLY: 'year',
    WEEKLY: 'week',
    DAILY: 'day',
    monthly: 'month',
    yearly: 'year',
    weekly: 'week',
    daily: 'day',
    month: 'month',
    year: 'year',
    week: 'week',
    day: 'day'
  };

  return map[normalized] || 'month';
}

function pricingAttributes(plan) {
  const pricing = Object.assign({}, plan.pricing || {});
  pricing.billingCycle = normalizeBillingCycle(pricing.billingCycle);
  const attrs = [];

  for (const [name, value] of Object.entries(pricing)) {
    if (value !== undefined && value !== null) {
      attrs.push({ name, value: String(value) });
    }
  }

  return attrs;
}

function monetizationInfo(plan) {
  const pricing = Object.assign({}, plan.pricing || {});
  pricing.billingCycle = normalizeBillingCycle(pricing.billingCycle);

  if (plan.billingPlan !== 'COMMERCIAL') {
    return {
      monetizationPlan: 'FIXEDRATE',
      properties: {
        billingType: pricing.billingType || 'FREE',
        billingCycle: normalizeBillingCycle(pricing.billingCycle),
        fixedPrice: pricing.fixedPrice || '0.00',
        pricePerRequest: pricing.pricePerRequest || '0.0000',
        currencyType: pricing.currencyType || 'USD'
      }
    };
  }

  return {
    monetizationPlan: 'FIXEDRATE',
    properties: {
      billingType: pricing.billingType || 'FIXED_RATE',
      billingCycle: normalizeBillingCycle(pricing.billingCycle),
      fixedPrice: pricing.fixedPrice || '0.00',
      pricePerRequest: pricing.pricePerRequest || pricing.pricePerEvent || '0.0000',
      pricePerEvent: pricing.pricePerEvent || pricing.pricePerRequest || '0.0000',
      currencyType: pricing.currencyType || 'USD',
      includedQuota: pricing.includedQuota || '',
      commercialSummary: pricing.commercialSummary || ''
    }
  };
}

function defaultLimit(plan) {
  const limitType = plan.limitType || 'REQUESTCOUNTLIMIT';

  if (limitType === 'EVENTCOUNTLIMIT') {
    return {
      type: 'EVENTCOUNTLIMIT',
      eventCount: {
        timeUnit: plan.timeUnit || 'min',
        unitTime: plan.unitTime || 1,
        eventCount: plan.eventCount || plan.requestCount || 1000
      }
    };
  }

  return {
    type: 'REQUESTCOUNTLIMIT',
    requestCount: {
      timeUnit: plan.timeUnit || 'min',
      unitTime: plan.unitTime || 1,
      requestCount: plan.requestCount || 1000
    }
  };
}

function toSubscriptionPolicy(plan, existing = {}) {
  return Object.assign({}, existing, {
    policyName: plan.policyName,
    displayName: plan.displayName || plan.policyName,
    description: plan.description || `${plan.displayName || plan.policyName} demo business plan`,
    isDeployed: true,
    graphQLMaxComplexity: plan.graphQLMaxComplexity || 0,
    graphQLMaxDepth: plan.graphQLMaxDepth || 0,
    defaultLimit: defaultLimit(plan),
    rateLimitCount: plan.rateLimitCount || 0,
    rateLimitTimeUnit: plan.rateLimitTimeUnit || 'min',
    customAttributes: pricingAttributes(plan),
    monetization: monetizationInfo(plan),
    stopOnQuotaReach: plan.stopOnQuotaReach !== false,
    billingPlan: plan.billingPlan || 'FREE',
    permissions: plan.permissions || existing.permissions
  });
}

async function loadExistingSubscriptionPolicies(token) {
  const result = await http(
    `${APIM_URL}/api/am/admin/v4/throttling/policies/subscription?limit=1000`,
    { bearer: token }
  );

  return result.list || result.data || [];
}

async function createOrUpdateCommercialPlans(token) {
  if (!fs.existsSync(COMMERCIAL_PLANS_FILE)) {
    log(`commercial plans file not found: ${COMMERCIAL_PLANS_FILE}`);
    return [];
  }

  const plans = JSON.parse(fs.readFileSync(COMMERCIAL_PLANS_FILE, 'utf8'));
  const existing = await loadExistingSubscriptionPolicies(token);

  const existingByName = new Map(
    existing.map(policy => [policy.policyName || policy.name, policy])
  );

  for (const plan of plans) {
    const existingPolicy = existingByName.get(plan.policyName);
    const payload = toSubscriptionPolicy(plan, existingPolicy || {});

    if (existingPolicy) {
      const policyId = existingPolicy.policyId || existingPolicy.id;

      if (!policyId) {
        log(`subscription policy exists but has no policyId, skipping update: ${plan.policyName}`);
        continue;
      }

      await http(`${APIM_URL}/api/am/admin/v4/throttling/policies/subscription/${policyId}`, {
        method: 'PUT',
        bearer: token,
        json: payload
      });

      log(`updated subscription policy pricing: ${plan.policyName}`);
      continue;
    }

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


function apiMonetizationProperties(apiName, planNames) {
  const isStreaming = apiName.includes('NetworkEvents') || apiName.includes('Stream');

  return {
    ConnectedAccountKey: 'acct_telco_demo_admin',
    RevenueShareModel: isStreaming ? 'EVENT_STREAM_REVENUE_SHARE' : 'API_PRODUCT_REVENUE_SHARE',
    SettlementOwner: 'Telco Marketplace Finance',
    ProductLine: isStreaming ? 'Streaming Event APIs' : 'Commercial Telco APIs',
    BillingCatalogReference: planNames.join(',')
  };
}

async function enablePublisherMonetizationProperties(token) {
  const apis = await listPublisherApis(token);

  for (const apiSummary of apis) {
    const planNames = API_PLAN_ASSIGNMENTS[apiSummary.name];

    if (!planNames || !apiSummary.id) {
      continue;
    }

    const hasCommercialPlan = planNames.some(plan => plan !== 'TelcoFreeTrial');

    if (!hasCommercialPlan) {
      continue;
    }

    const properties = apiMonetizationProperties(apiSummary.name, planNames);

    try {
      await http(`${APIM_URL}/api/am/publisher/v4/apis/${apiSummary.id}/monetize`, {
        method: 'POST',
        bearer: token,
        json: {
          enabled: true,
          properties
        }
      }, [200, 201, 202, 204]);

      log(`enabled API-level monetization properties for ${apiSummary.name}`);
    } catch (e) {
      log(`monetize endpoint failed for ${apiSummary.name}; falling back to API update: ${e.message}`);

      try {
        const api = await http(`${APIM_URL}/api/am/publisher/v4/apis/${apiSummary.id}`, {
          bearer: token
        });

        api.monetization = {
          enabled: true,
          properties
        };

        await http(`${APIM_URL}/api/am/publisher/v4/apis/${apiSummary.id}`, {
          method: 'PUT',
          bearer: token,
          json: api
        }, [200, 201, 202]);

        log(`updated API monetization object for ${apiSummary.name}`);
      } catch (fallbackError) {
        log(`could not update API-level monetization for ${apiSummary.name}: ${fallbackError.message}`);
      }
    }
  }
}


async function bestEffortEnableMonetizationLabels(token) {
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

      await http(url, { method: 'PUT', bearer: token, json: settings }, [200, 201, 202, 204]);

      log(`enabled monetization labels through ${url}`);
      return;
    } catch (e) {
      log(`monetization settings endpoint not available at ${url}`);
    }
  }

  log('commercial pricing attributes are configured; enable monetization labels manually in Admin → Settings → Advanced if needed.');
}

async function main() {
  await sleep(3000);

  const token = await getAdminToken();

  await createOrUpdateCommercialPlans(token);
  await attachPlansToPublishedApis(token);
  await enablePublisherMonetizationProperties(token);
  await bestEffortEnableMonetizationLabels(token);

  log('completed.');
}

main().catch(e => {
  console.error(`[APIM admin setup] failed: ${e.stack || e.message}`);
  process.exitCode = 1;
});
