'use strict';

const fs = require('fs');
const path = require('path');
const { fetch, Agent } = require('undici');

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const dispatcher = new Agent({ connect: { rejectUnauthorized: false } });
const OPA_URL =
  process.env.CENTRAL_POLICY_OPA_URL ||
  'http://opa:8181/v1/data/telco/central_policy/decision';
const CATALOG_FILE =
  process.env.CENTRAL_POLICY_CATALOG_FILE ||
  '/workspace/artifacts/apim-admin/central-policy-catalog.json';
const STATE_FILE =
  process.env.CENTRAL_POLICY_PREFLIGHT_STATE_FILE ||
  '/workspace/state/central-policy-preflight.json';
const FAIL_ON_DENY =
  String(process.env.CENTRAL_POLICY_FAIL_ON_DENY || 'true').toLowerCase() === 'true';

function log(message) {
  console.log(`[Central Policy Preflight] ${message}`);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function requestDecision(descriptor) {
  let lastError;
  for (let attempt = 1; attempt <= 30; attempt += 1) {
    try {
      const response = await fetch(OPA_URL, {
        method: 'POST',
        dispatcher,
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ input: descriptor }),
        signal: AbortSignal.timeout(5000),
      });
      const text = await response.text();
      let payload;
      try {
        payload = text ? JSON.parse(text) : null;
      } catch {
        payload = null;
      }
      if (!response.ok || !payload?.result) {
        throw new Error(`HTTP ${response.status}: ${text}`);
      }
      return payload.result;
    } catch (error) {
      lastError = error;
      log(
        `Waiting for OPA decision endpoint for ${descriptor.apiName} ` +
          `(${attempt}/30): ${error.message}`,
      );
      await sleep(2000);
    }
  }
  throw new Error(
    `OPA decision endpoint unavailable for ${descriptor.apiName}: ` +
      `${lastError?.message || 'unknown error'}`,
  );
}

async function main() {
  if (!fs.existsSync(CATALOG_FILE)) {
    throw new Error(`Central policy catalog is missing: ${CATALOG_FILE}`);
  }
  const catalog = JSON.parse(fs.readFileSync(CATALOG_FILE, 'utf8'));
  if (!Array.isArray(catalog.descriptors) || catalog.descriptors.length === 0) {
    throw new Error('Central policy catalog contains no descriptors.');
  }

  const state = {
    status: 'READY',
    generatedAt: new Date().toISOString(),
    failOnDeny: FAIL_ON_DENY,
    policyVersion: catalog.policyVersion,
    groupPolicyVersion: catalog.groupPolicyVersion,
    decisions: [],
  };

  for (const descriptor of catalog.descriptors) {
    const decision = await requestDecision(descriptor);
    const blocking = Array.isArray(decision.blocking) ? decision.blocking : [];
    const advisories = Array.isArray(decision.advisories)
      ? decision.advisories
      : [];
    log(
      `${descriptor.apiName}: ${decision.decisionStatus}; ` +
        `blocking=${blocking.length}; advisories=${advisories.length}`,
    );
    for (const advisory of advisories) {
      log(
        `ADVISORY ${descriptor.apiName} ${advisory.code}: ` +
          `${advisory.message}`,
      );
    }
    state.decisions.push({
      apiName: descriptor.apiName,
      country: descriptor.country,
      riskClassification: descriptor.riskClassification,
      allow: Boolean(decision.allow),
      decisionStatus: decision.decisionStatus,
      blockingCount: blocking.length,
      advisoryCount: advisories.length,
      blocking,
      advisories,
    });
    if (!decision.allow && FAIL_ON_DENY) {
      throw new Error(
        `Blocking central-policy denial for ${descriptor.apiName}: ` +
          blocking.map(item => `${item.code}: ${item.message}`).join('; '),
      );
    }
  }

  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(STATE_FILE, `${JSON.stringify(state, null, 2)}\n`);
  log(
    `READY: ${state.decisions.length} production descriptors passed the ` +
      `blocking gate; advisory findings remained report-only.`,
  );
}

main().catch(error => {
  console.error(
    `[Central Policy Preflight] failed: ${error.stack || error.message}`,
  );
  try {
    fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
    fs.writeFileSync(
      STATE_FILE,
      `${JSON.stringify(
        {
          status: 'FAILED',
          generatedAt: new Date().toISOString(),
          failOnDeny: FAIL_ON_DENY,
          error: error.message,
        },
        null,
        2,
      )}\n`,
    );
  } catch {
    // Preserve the original error.
  }
  process.exit(1);
});
