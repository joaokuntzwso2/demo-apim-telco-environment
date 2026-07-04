const fs = require('fs');
const path = require('path');

const OPA_URL = process.env.OPA_URL || 'http://opa:8181';

function readJson(candidates) {
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return JSON.parse(fs.readFileSync(candidate, 'utf8'));
    }
  }

  return null;
}

async function evaluateOpa(input) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 5000);

  try {
    const response = await fetch(`${OPA_URL}/v1/data/telco/apim/governance/decision`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ input }),
      signal: controller.signal
    });

    const text = await response.text();
    let data = {};

    try {
      data = text ? JSON.parse(text) : {};
    } catch {
      throw new Error(`OPA returned non-JSON response: ${text}`);
    }

    if (!response.ok) {
      throw new Error(`OPA HTTP ${response.status}: ${text}`);
    }

    return data.result || data;
  } catch (error) {
    if (error.name === 'AbortError') {
      throw new Error(`OPA request timed out after 5 seconds. Check that OPA is running and reachable at ${OPA_URL}.`);
    }

    throw error;
  } finally {
    clearTimeout(timeout);
  }
}


function opaCors(req, res, next) {
  const origin = req.headers.origin || '*';

  res.setHeader('Access-Control-Allow-Origin', origin);
  res.setHeader('Vary', 'Origin');
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-Requested-With');

  if (req.method === 'OPTIONS') {
    res.status(204).end();
    return;
  }

  next();
}

function registerOpaGovernanceRoutes(app) {
  app.use('/api/v1/opa', opaCors);
  app.get('/api/v1/opa/governance/story', (req, res) => {
    res.json({
      name: 'OPA policy-as-code governance for APIM',
      story: 'For a regional telco, API governance must be automated. OPA validates APIM product bundles, Open Gateway commercial controls and federated gateway readiness before the demo platform is used.',
      validations: [
        {
          id: 'commercial-api-product-metadata',
          name: 'Commercial API Product metadata',
          businessMeaning: 'Every sellable API product must have APIM product metadata, Moesif billing catalog metadata, plans, markets and settlement ownership.'
        },
        {
          id: 'high-risk-open-gateway-controls',
          name: 'High-risk Open Gateway controls',
          businessMeaning: 'Fraud, SIM swap and location APIs must have premium commercial guardrails and billable event/API meters.'
        },
        {
          id: 'regional-failover-readiness',
          name: 'Regional gateway failover readiness',
          businessMeaning: 'If a country gateway is degraded, the group must show a healthy federated runtime can absorb traffic without changing the central governance model.'
        }
      ]
    });
  });

  app.get('/api/v1/opa/governance/evaluate', async (req, res) => {
    try {
      const bundles = readJson([
        '/workspace/artifacts/apim-admin/api-product-bundles.json',
        path.join(process.cwd(), 'artifacts/apim-admin/api-product-bundles.json'),
        path.join(__dirname, '../../../artifacts/apim-admin/api-product-bundles.json')
      ]) || [];

      const dashboard = readJson([
        '/workspace/artifacts/regional-gateways/federated-gateway-dashboard.json',
        path.join(process.cwd(), 'artifacts/regional-gateways/federated-gateway-dashboard.json'),
        path.join(__dirname, '../../../artifacts/regional-gateways/federated-gateway-dashboard.json')
      ]);

      const validations = [];

      for (const bundle of bundles) {
        validations.push({
          kind: 'api_product_bundle',
          id: bundle.id,
          name: bundle.name,
          decision: await evaluateOpa({
            kind: 'api_product_bundle',
            bundle
          })
        });
      }

      if (dashboard) {
        validations.push({
          kind: 'regional_gateway_dashboard',
          id: dashboard.id,
          name: dashboard.name,
          decision: await evaluateOpa({
            kind: 'regional_gateway_dashboard',
            dashboard
          })
        });
      }

      res.json({
        opaUrl: OPA_URL,
        generatedAt: new Date().toISOString(),
        story: 'OPA is acting as a telco governance decision point for APIM productization, commercial controls and regional runtime readiness.',
        validations
      });
    } catch (error) {
      res.status(502).json({
        error: 'opa_evaluation_failed',
        message: error.message,
        opaUrl: OPA_URL
      });
    }
  });
}

module.exports = {
  registerOpaGovernanceRoutes
};
