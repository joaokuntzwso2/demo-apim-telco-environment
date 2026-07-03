const fs = require('fs');
const path = require('path');

function loadDashboardArtifact() {
  const candidates = [
    path.join(__dirname, '../../../artifacts/regional-gateways/federated-gateway-dashboard.json'),
    path.join(process.cwd(), 'artifacts/regional-gateways/federated-gateway-dashboard.json'),
    '/workspace/artifacts/regional-gateways/federated-gateway-dashboard.json'
  ];

  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return JSON.parse(fs.readFileSync(candidate, 'utf8'));
    }
  }

  return null;
}

function buildRuntimeEvent(runtime) {
  return {
    eventId: `gw-${runtime.id}-${Date.now()}`,
    eventType: 'FEDERATED_GATEWAY_HEALTH_SIGNAL',
    runtimeId: runtime.id,
    country: runtime.country,
    region: runtime.region,
    runtimeType: runtime.runtimeType,
    status: runtime.status,
    latencyMs: runtime.latencyMs,
    availabilityPct: runtime.availabilityPct,
    commercial: {
      billable: false,
      meter: 'gateway_observability_signal',
      businessContext: runtime.businessFocus
    },
    governance: {
      model: 'central governance, federated runtime execution',
      policy: 'Regional Gateway Operating Model',
      controlPlane: 'WSO2 API Manager'
    },
    producedAt: new Date().toISOString()
  };
}

function registerRegionalGatewayRoutes(app) {
  app.get('/api/v1/regional-gateways/dashboard', (req, res) => {
    const artifact = loadDashboardArtifact();

    if (!artifact) {
      return res.status(404).json({
        error: 'regional_gateway_dashboard_not_found'
      });
    }

    res.json({
      ...artifact,
      generatedAt: new Date().toISOString(),
      runtimeSignals: artifact.federatedRuntimes.map(buildRuntimeEvent)
    });
  });

  app.get('/api/v1/regional-gateways/runtimes', (req, res) => {
    const artifact = loadDashboardArtifact();

    if (!artifact) {
      return res.status(404).json({
        error: 'regional_gateway_dashboard_not_found'
      });
    }

    res.json({
      runtimes: artifact.federatedRuntimes,
      executiveKpis: artifact.executiveKpis
    });
  });

  app.post('/api/v1/regional-gateways/simulate-failover', (req, res) => {
    const artifact = loadDashboardArtifact();

    if (!artifact) {
      return res.status(404).json({
        error: 'regional_gateway_dashboard_not_found'
      });
    }

    const sourceRuntime = req.body?.sourceRuntime || 'co-andes';
    const targetRuntime = req.body?.targetRuntime || 'br-southeast';

    const source = artifact.federatedRuntimes.find(item => item.id === sourceRuntime);
    const target = artifact.federatedRuntimes.find(item => item.id === targetRuntime);

    res.status(202).json({
      accepted: true,
      scenario: 'regional_gateway_failover',
      story: 'A regional runtime is degraded, so traffic for selected partner APIs is routed to a healthy federated runtime while central governance remains unchanged.',
      sourceRuntime: source || { id: sourceRuntime, status: 'Unknown' },
      targetRuntime: target || { id: targetRuntime, status: 'Unknown' },
      businessImpact: {
        continuity: 'Partner API traffic remains available',
        governance: 'No policy duplication required',
        commercialModel: 'Subscriptions, throttling and billing metadata remain consistent'
      },
      recommendedActions: [
        'Notify regional platform operations',
        'Shift selected partner traffic to healthy runtime',
        'Keep central API product and subscription model unchanged',
        'Review latency and SLA metrics after failover'
      ],
      producedAt: new Date().toISOString()
    });
  });
}

module.exports = {
  registerRegionalGatewayRoutes
};
