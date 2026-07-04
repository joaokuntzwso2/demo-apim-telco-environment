const fs = require('fs');
const path = require('path');
const { fetch } = require('undici');

const OPA_ENABLED = String(process.env.OPA_ENABLED || 'false').toLowerCase() === 'true';
const OPA_URL = process.env.OPA_URL || 'http://opa:8181';
const OPA_FAIL_ON_DENY = String(process.env.OPA_FAIL_ON_DENY || 'false').toLowerCase() === 'true';

const BUNDLES_FILE = process.env.APIM_API_PRODUCT_BUNDLES_FILE || '/workspace/artifacts/apim-admin/api-product-bundles.json';
const REGIONAL_GATEWAYS_FILE = process.env.REGIONAL_GATEWAYS_FILE || '/workspace/artifacts/regional-gateways/federated-gateway-dashboard.json';
const STATE_FILE = process.env.OPA_GOVERNANCE_STATE_FILE || '/workspace/state/opa-governance-results.json';

function log(message) {
  console.log(`[APIM OPA governance] ${message}`);
}

function readJson(file) {
  if (!fs.existsSync(file)) {
    return null;
  }

  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

async function evaluate(input) {
  const res = await fetch(`${OPA_URL}/v1/data/telco/apim/governance/decision`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ input })
  });

  const text = await res.text();
  let data;

  try {
    data = text ? JSON.parse(text) : {};
  } catch {
    throw new Error(`OPA returned non-JSON response: ${text}`);
  }

  if (!res.ok) {
    throw new Error(`OPA HTTP ${res.status}: ${JSON.stringify(data)}`);
  }

  return data.result || data;
}

async function main() {
  if (!OPA_ENABLED) {
    log('OPA is disabled. Set OPA_ENABLED=true to run policy-as-code validations.');
    return;
  }

  const results = {
    generatedAt: new Date().toISOString(),
    opaUrl: OPA_URL,
    validations: []
  };

  const bundles = readJson(BUNDLES_FILE) || [];

  for (const bundle of bundles) {
    const decision = await evaluate({
      kind: 'api_product_bundle',
      bundle
    });

    const denied = Array.isArray(decision.deny) && decision.deny.length > 0;

    results.validations.push({
      kind: 'api_product_bundle',
      name: bundle.name,
      id: bundle.id,
      allow: decision.allow === true,
      deny: decision.deny || [],
      warn: decision.warn || [],
      story: decision.story
    });

    if (denied) {
      log(`DENY bundle ${bundle.name}: ${decision.deny.join(' | ')}`);
    } else {
      log(`PASS bundle ${bundle.name}`);
    }
  }

  const regionalDashboard = readJson(REGIONAL_GATEWAYS_FILE);

  if (regionalDashboard) {
    const decision = await evaluate({
      kind: 'regional_gateway_dashboard',
      dashboard: regionalDashboard
    });

    const denied = Array.isArray(decision.deny) && decision.deny.length > 0;

    results.validations.push({
      kind: 'regional_gateway_dashboard',
      name: regionalDashboard.name,
      allow: decision.allow === true,
      deny: decision.deny || [],
      warn: decision.warn || [],
      story: decision.story
    });

    if (denied) {
      log(`DENY regional gateway dashboard: ${decision.deny.join(' | ')}`);
    } else {
      log(`PASS regional gateway dashboard`);
    }
  } else {
    log(`Regional gateway artifact not found: ${REGIONAL_GATEWAYS_FILE}`);
  }

  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify(results, null, 2));

  const denies = results.validations.flatMap(item => item.deny || []);

  log(`wrote OPA validation results to ${STATE_FILE}`);
  log(`summary: validations=${results.validations.length}, denies=${denies.length}`);

  if (OPA_FAIL_ON_DENY && denies.length) {
    throw new Error(`OPA governance denied ${denies.length} item(s).`);
  }
}

main().catch(error => {
  console.error(`[APIM OPA governance] failed: ${error.stack || error.message}`);
  process.exitCode = 1;
});
