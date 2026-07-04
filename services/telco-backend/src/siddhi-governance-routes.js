const fs = require('fs');
const path = require('path');

function siddhiCors(req, res, next) {
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

function readFirst(candidates) {
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return {
        path: candidate,
        content: fs.readFileSync(candidate, 'utf8')
      };
    }
  }

  return null;
}

function extractQueryNames(text) {
  return [...String(text || '').matchAll(/@info\s*\(\s*name\s*=\s*['"]([^'"]+)['"]\s*\)/g)].map(match => match[1]);
}

function validateSiddhi(text, artifactPath) {
  const queryNames = extractQueryNames(text);

  const checks = [
    {
      id: 'qod-sla-degradation',
      name: 'QoD SLA degradation detection',
      pass: queryNames.includes('qodSlaDegradationValidation') && /NETWORK_SLA_DEGRADATION/.test(text),
      businessMeaning: 'Protects enterprise and network-slice customers by detecting SLA-impacting QoD events.'
    },
    {
      id: 'sim-swap-fraud-guard',
      name: 'SIM swap fraud guard',
      pass: queryNames.includes('simSwapFraudGuardValidation') && /RECENT_SIM_SWAP_HIGH_RISK/.test(text),
      businessMeaning: 'Protects banks, fintechs and digital channels using Open Gateway SIM swap risk signals.'
    },
    {
      id: 'partner-settlement-meter',
      name: 'Partner settlement metering',
      pass: queryNames.includes('partnerSettlementMeterValidation') && /estimatedRevenue/.test(text),
      businessMeaning: 'Aggregates billable partner events for Moesif billing, settlement and revenue sharing.'
    },
    {
      id: 'kafka-event-native-integration',
      name: 'Kafka event-native integration',
      pass: /@source\s*\(\s*type\s*=\s*['"]kafka['"]/s.test(text) && /@sink\s*\(\s*type\s*=\s*['"]kafka['"]/s.test(text),
      businessMeaning: 'Shows that the event logic is connected to the same Kafka event-native story used by the portal.'
    }
  ];

  const failed = checks.filter(check => !check.pass);

  return {
    allow: failed.length === 0,
    artifact: artifactPath,
    generatedAt: new Date().toISOString(),
    queryNames,
    validations: checks,
    deny: failed.map(check => `${check.name} failed.`),
    story: 'Siddhi validates the real-time telco event logic behind APIM products: QoD assurance, SIM swap fraud prevention and partner settlement metering.'
  };
}

function registerSiddhiGovernanceRoutes(app) {
  app.use('/api/v1/siddhi', siddhiCors);

  app.get('/api/v1/siddhi/governance/story', (req, res) => {
    res.json({
      name: 'Siddhi query validation for telco event-native APIs',
      story: 'Siddhi validates the real-time event processing logic behind telco API products. The demo uses it to prove that network assurance, fraud detection and settlement event logic are governed before APIM exposes them.',
      validations: [
        'QoD SLA degradation detection',
        'SIM swap fraud guard',
        'Partner settlement metering',
        'Kafka source and sink integration'
      ]
    });
  });

  app.get('/api/v1/siddhi/governance/evaluate', (req, res) => {
    try {
      const artifact = readFirst([
        '/workspace/artifacts/siddhi/telco-event-governance.siddhi',
        path.join(process.cwd(), 'artifacts/siddhi/telco-event-governance.siddhi'),
        path.join(__dirname, '../../../artifacts/siddhi/telco-event-governance.siddhi')
      ]);

      if (!artifact) {
        res.status(404).json({
          error: 'siddhi_artifact_not_found'
        });
        return;
      }

      res.json(validateSiddhi(artifact.content, artifact.path));
    } catch (error) {
      res.status(500).json({
        error: 'siddhi_validation_failed',
        message: error.message
      });
    }
  });
}

module.exports = {
  registerSiddhiGovernanceRoutes
};
