const fs = require('fs');
const path = require('path');

const SIDDHI_FILE = process.env.SIDDHI_GOVERNANCE_FILE || '/workspace/artifacts/siddhi/telco-event-governance.siddhi';
const STATE_FILE = process.env.SIDDHI_GOVERNANCE_STATE_FILE || '/workspace/state/siddhi-governance-results.json';

function log(message) {
  console.log(`[APIM Siddhi governance] ${message}`);
}

function normalize(text) {
  return String(text || '').replace(/\r\n/g, '\n');
}

function has(text, pattern) {
  return pattern.test(text);
}

function extractQueryNames(text) {
  return [...text.matchAll(/@info\s*\(\s*name\s*=\s*['"]([^'"]+)['"]\s*\)/g)].map(match => match[1]);
}

function validateSiddhiApp(text) {
  const normalized = normalize(text);
  const queryNames = extractQueryNames(normalized);

  const validations = [
    {
      id: 'siddhi-app-name',
      name: 'Siddhi application name',
      story: 'The telco event logic must be packaged as a named Siddhi app before being promoted with the APIM demo.',
      pass: has(normalized, /@App:name\s*\(\s*['"]TelcoEventGovernanceApp['"]\s*\)/)
    },
    {
      id: 'kafka-source-and-sink',
      name: 'Kafka source and sink integration',
      story: 'Event-native telco products must consume and emit Kafka events for network, fraud and settlement workflows.',
      pass:
        has(normalized, /@source\s*\(\s*type\s*=\s*['"]kafka['"]/s) &&
        has(normalized, /@sink\s*\(\s*type\s*=\s*['"]kafka['"]/s)
    },
    {
      id: 'qod-sla-degradation-query',
      name: 'QoD SLA degradation query',
      story: 'Network SLA degradation must be detected from latency, packet-loss or critical severity events.',
      pass:
        queryNames.includes('qodSlaDegradationValidation') &&
        has(normalized, /latencyMs\s*>\s*120\.0/) &&
        has(normalized, /packetLossPct\s*>\s*1\.5/) &&
        has(normalized, /NETWORK_SLA_DEGRADATION/)
    },
    {
      id: 'sim-swap-fraud-query',
      name: 'SIM swap fraud guard query',
      story: 'Recent SIM swap events with high risk must trigger step-up authentication or transaction denial.',
      pass:
        queryNames.includes('simSwapFraudGuardValidation') &&
        has(normalized, /simSwapAgeHours\s*<\s*24\.0/) &&
        has(normalized, /riskScore\s*>=\s*80\.0/) &&
        has(normalized, /RECENT_SIM_SWAP_HIGH_RISK/)
    },
    {
      id: 'partner-settlement-query',
      name: 'Partner settlement aggregation query',
      story: 'Billable partner events must be aggregated into settlement windows for API monetization and revenue sharing.',
      pass:
        queryNames.includes('partnerSettlementMeterValidation') &&
        has(normalized, /sum\s*\(\s*billableUnits\s*\)/) &&
        has(normalized, /sum\s*\(\s*billableUnits\s*\*\s*unitPrice\s*\)/) &&
        has(normalized, /group\s+by\s+partnerId\s*,\s*productKey\s*,\s*apiProduct\s*,\s*country/i)
    },
    {
      id: 'windowing-required',
      name: 'Streaming windowing controls',
      story: 'Real-time telco decisions must use explicit windows so SLA, fraud and settlement logic is bounded and explainable.',
      pass:
        has(normalized, /#window\.timeBatch\s*\(\s*1\s+min\s*\)/) &&
        has(normalized, /#window\.time\s*\(\s*5\s+min\s*\)/) &&
        has(normalized, /#window\.timeBatch\s*\(\s*15\s+min\s*\)/)
    }
  ];

  const failed = validations.filter(item => !item.pass);
  const passed = validations.filter(item => item.pass);

  return {
    allow: failed.length === 0,
    generatedAt: new Date().toISOString(),
    artifact: SIDDHI_FILE,
    queryNames,
    validationCount: validations.length,
    passedCount: passed.length,
    failedCount: failed.length,
    validations,
    deny: failed.map(item => `${item.name} failed.`),
    story: 'Siddhi validation proves that the event-native telco product logic for QoD assurance, SIM swap fraud and partner settlement is governed before APIM exposes or monetizes it.'
  };
}

function main() {
  if (!fs.existsSync(SIDDHI_FILE)) {
    throw new Error(`Siddhi governance artifact not found: ${SIDDHI_FILE}`);
  }

  const text = fs.readFileSync(SIDDHI_FILE, 'utf8');
  const result = validateSiddhiApp(text);

  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify(result, null, 2));

  for (const validation of result.validations) {
    log(`${validation.pass ? 'PASS' : 'DENY'} ${validation.name}`);
  }

  log(`wrote Siddhi validation results to ${STATE_FILE}`);
  log(`summary: validations=${result.validationCount}, passed=${result.passedCount}, failed=${result.failedCount}`);

  if (!result.allow && String(process.env.SIDDHI_FAIL_ON_DENY || 'false').toLowerCase() === 'true') {
    throw new Error(`Siddhi governance denied ${result.failedCount} validation(s).`);
  }
}

main();
