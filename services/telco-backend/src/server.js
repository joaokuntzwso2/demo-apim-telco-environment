const express = require('express');
const { registerSiddhiGovernanceRoutes } = require('./siddhi-governance-routes');
const { registerOpaGovernanceRoutes } = require('./opa-governance-routes');
const { registerDemoArtifactRoutes } = require('./demo-artifact-routes');
const { registerRegionalGatewayRoutes } = require('./regional-gateway-routes');
const { registerKafkaRoutes } = require('./kafka-routes'); const { graphql, buildSchema } = require('graphql');
const cors = require('cors');
const morgan = require('morgan');
const http = require('http');
const { WebSocketServer } = require('ws');

const app = express();
registerSiddhiGovernanceRoutes(app);
registerOpaGovernanceRoutes(app);
registerDemoArtifactRoutes(app);
const port = Number(process.env.PORT || 8081);
const brand = process.env.MOCK_TELCO_BRAND || 'Regional Telco Group';

app.use(cors());
app.use(morgan('tiny'));
app.use(express.json({ limit: '2mb' }));
registerRegionalGatewayRoutes(app);
registerKafkaRoutes(app);
app.use(express.text({ type: ['text/xml', 'application/xml', '*/xml'], limit: '2mb' }));

const countries = [
  { code: 'MX', name: 'Mexico', brand: 'Operator MX', region: 'North LATAM', currency: 'MXN', subscribers: 82200000 },
  { code: 'BR', name: 'Brazil', brand: 'Operator BR', region: 'South LATAM', currency: 'BRL', subscribers: 65800000 },
  { code: 'CO', name: 'Colombia', brand: 'Operator CO', region: 'Andean', currency: 'COP', subscribers: 38400000 },
  { code: 'AR', name: 'Argentina', brand: 'Operator AR', region: 'South LATAM', currency: 'ARS', subscribers: 27100000 },
  { code: 'PE', name: 'Peru', brand: 'Operator PE', region: 'Andean', currency: 'PEN', subscribers: 14000000 },
  { code: 'CL', name: 'Chile', brand: 'Operator CL', region: 'South LATAM', currency: 'CLP', subscribers: 7100000 },
  { code: 'EC', name: 'Ecuador', brand: 'Operator EC', region: 'Andean', currency: 'USD', subscribers: 9600000 },
  { code: 'GT', name: 'Guatemala', brand: 'Operator GT', region: 'Central America', currency: 'GTQ', subscribers: 9200000 },
  { code: 'HN', name: 'Honduras', brand: 'Operator HN', region: 'Central America', currency: 'HNL', subscribers: 5500000 },
  { code: 'SV', name: 'El Salvador', brand: 'Operator SV', region: 'Central America', currency: 'USD', subscribers: 4100000 },
  { code: 'DO', name: 'Dominican Republic', brand: 'Operator DO', region: 'Caribbean', currency: 'DOP', subscribers: 7600000 },
  { code: 'PR', name: 'Puerto Rico', brand: 'Operator PR', region: 'Caribbean', currency: 'USD', subscribers: 3100000 }
];

const partners = [
  { id: 'banking-superapp', name: 'Continental SuperApp Bank', segment: 'Fintech', tier: 'Platinum', country: 'MX' },
  { id: 'ride-hailing', name: 'UrbanMove Mobility', segment: 'Mobility', tier: 'Gold', country: 'BR' },
  { id: 'iot-energy', name: 'Andes Smart Energy', segment: 'IoT', tier: 'Gold', country: 'CO' },
  { id: 'retail-marketplace', name: 'Digital Retail Partner', segment: 'Retail', tier: 'Enterprise', country: 'AR' }
];

const monetizationPlans = [
  { id: 'sandbox', name: 'Sandbox', price: 0, currency: 'USD', quota: '10k calls/month', overage: 0, target: 'Developers and testing' },
  { id: 'growth', name: 'Growth', price: 2500, currency: 'USD', quota: '5M calls/month', overage: 0.0009, target: 'Regional partner launches' },
  { id: 'enterprise-latam', name: 'Enterprise LATAM', price: 22000, currency: 'USD', quota: '150M calls/month', overage: 0.00035, target: 'Multi-country strategic partners' },
  { id: 'network-premium', name: 'Network Premium', price: 45000, currency: 'USD', quota: 'Reserved slice + QoD events', overage: 0.0021, target: 'Low-latency and 5G use cases' }
];

const apiProducts = [
  {
    id: 'partner-growth-pack',
    name: 'Partner Growth Pack',
    description: 'Customer consent, eligibility, number verification, usage balance and partner settlement.',
    apis: ['Customer360API', 'NumberLifecycleAPI', 'PartnerChargingAPI'],
    plan: 'enterprise-latam',
    markets: ['MX', 'BR', 'CO', 'AR']
  },
  {
    id: 'network-monetization-pack',
    name: 'Network Monetization Pack',
    description: '5G slice reservation, QoD telemetry, network alarms and SLA event streams.',
    apis: ['NetworkSliceAPI', 'NetworkEventsStreamAPI'],
    plan: 'network-premium',
    markets: ['BR', 'MX', 'CO', 'CL']
  },
  {
    id: 'legacy-billing-pack',
    name: 'Legacy Billing Pack',
    description: 'SOAP-based BSS billing adjustment wrapped for governed access.',
    apis: ['BillingAdjustmentSOAP'],
    plan: 'growth',
    markets: ['MX', 'BR', 'AR', 'CO', 'PE']
  }
];

const customers = {
  '+525512340001': {
    msisdn: '+525512340001', country: 'MX', segment: 'Postpaid Premium', lifecycle: 'Active',
    name: 'Mariana Torres', consent: { marketing: true, analytics: true, partnerDataShare: true },
    plan: '5G Max Plus', arpu: 58.7, riskScore: 12, network: { rat: '5G-SA', cellId: 'MX-MEX-5G-0042' }
  },
  '+551199990001': {
    msisdn: '+551199990001', country: 'BR', segment: 'Postpaid Consumer', lifecycle: 'Active',
    name: 'Lucas Andrade', consent: { marketing: false, analytics: true, partnerDataShare: false },
    plan: '5G Control Plan', arpu: 31.2, riskScore: 23, network: { rat: '5G-NSA', cellId: 'BR-SP-5G-0097' }
  },
  '+573001230001': {
    msisdn: '+573001230001', country: 'CO', segment: 'Enterprise IoT', lifecycle: 'Suspended',
    name: 'Andes Energy Meter 8821', consent: { marketing: false, analytics: true, partnerDataShare: true },
    plan: 'IoT Managed Connectivity', arpu: 4.8, riskScore: 8, network: { rat: 'LTE-M', cellId: 'CO-BOG-LTE-0219' }
  }
};

function randomOf(items) { return items[Math.floor(Math.random() * items.length)]; }
function nowIso() { return new Date().toISOString(); }

function networkEvent(type = null) {
  const country = randomOf(countries);
  const eventTypes = ['slice.utilization.high', 'qod.latency.breach', 'cell.congestion.warning', 'roaming.partner.degradation', 'charging.reconciliation.completed'];
  const selectedType = type || randomOf(eventTypes);
  return {
    id: `evt-${Date.now()}-${Math.floor(Math.random() * 10000)}`,
    timestamp: nowIso(),
    eventType: selectedType,
    severity: selectedType.includes('breach') ? 'critical' : selectedType.includes('warning') ? 'warning' : 'info',
    country: country.code,
    market: country.name,
    region: country.region,
    cellId: `${country.code}-${Math.floor(Math.random() * 999).toString().padStart(3, '0')}`,
    sliceId: randomOf(['urllc-qod-gold', 'iot-massive-bronze', 'consumer-video-silver', 'enterprise-private-5g']),
    latencyMs: Math.floor(8 + Math.random() * 90),
    utilizationPct: Math.floor(45 + Math.random() * 55),
    partnerId: randomOf(partners).id,
    monetizationImpactUsd: Number((Math.random() * 2800).toFixed(2))
  };
}

app.get('/health', (req, res) => {
  res.json({ ok: true, service: 'telco-bss-oss-mock', brand, protocols: ['REST', 'SOAP', 'SSE', 'WebSocket', 'WebHook'], timestamp: nowIso() });
});

app.get('/metadata', (req, res) => {
  res.json({ brand, countries, partners, apiProducts, apiProductBundles: apiProducts, monetizationPlans, moesifExport: { artifact: '/api/v1/moesif/export', staticArtifact: '/exports/moesif-api-product-export.json', format: 'moesif.billing_catalog.export' } });
});

app.get('/api/v1/countries', (req, res) => res.json({ countries }));
app.get('/api/v1/partners', (req, res) => res.json({ partners }));
app.get('/api/v1/products', (req, res) => res.json({ apiProducts })); app.get('/api/v1/api-product-bundles', (req, res) => res.json({ apiProductBundles: apiProducts })); app.get('/api/v1/moesif/export', (req, res) => res.json(buildMoesifExportArtifact()));
app.get('/api/v1/monetization/plans', (req, res) => res.json({ plans: monetizationPlans }));

app.get('/api/v1/customers/:msisdn/profile', (req, res) => {
  const msisdn = decodeURIComponent(req.params.msisdn);
  const customer = customers[msisdn] || randomOf(Object.values(customers));
  res.json({ customer, correlationId: req.headers['x-correlation-id'] || `corr-${Date.now()}` });
});

app.get('/api/v1/customers/:msisdn/consent', (req, res) => {
  const msisdn = decodeURIComponent(req.params.msisdn);
  const customer = customers[msisdn] || randomOf(Object.values(customers));
  res.json({ msisdn, country: customer.country, consent: customer.consent, source: 'central-consent-ledger', lastUpdated: nowIso() });
});

app.post('/api/v1/customers/:msisdn/consent', (req, res) => {
  const msisdn = decodeURIComponent(req.params.msisdn);
  const customer = customers[msisdn] || randomOf(Object.values(customers));
  customer.consent = { ...customer.consent, ...req.body };
  res.status(202).json({ accepted: true, msisdn, consent: customer.consent, auditId: `aud-${Date.now()}` });
});

app.get('/api/v1/subscribers/:msisdn/eligibility', (req, res) => {
  const msisdn = decodeURIComponent(req.params.msisdn);
  const product = req.query.product || '5g-sa';
  const customer = customers[msisdn] || randomOf(Object.values(customers));
  const eligible = customer.lifecycle === 'Active' && customer.riskScore < 25;
  res.json({ msisdn, product, eligible, reason: eligible ? 'Subscriber active and risk accepted' : 'Lifecycle or risk constraint', network: customer.network });
});

app.get('/api/v1/device/:imei/eligibility', (req, res) => {
  const tac = req.params.imei.slice(0, 8);
  res.json({ imei: req.params.imei, tac, supports5gSA: ['35976210', '86740010', '35391811'].includes(tac), eSIM: true, volte: true, deviceFinancingRisk: 'LOW' });
});

app.get('/api/v1/number-portability/:msisdn', (req, res) => {
  res.json({ msisdn: decodeURIComponent(req.params.msisdn), portable: true, currentOperator: randomOf(['Operator Alpha', 'Operator Beta', 'Operator Gamma', 'Operator Delta', 'Operator Epsilon']), validationWindowMinutes: 15, otpRequired: true });
});

app.get('/api/v1/network/cells/:cellId/status', (req, res) => {
  const country = randomOf(countries);
  res.json({ cellId: req.params.cellId, country: country.code, status: randomOf(['GREEN', 'AMBER', 'RED']), utilizationPct: Math.floor(Math.random() * 100), avgLatencyMs: Math.floor(8 + Math.random() * 80), activeSessions: Math.floor(1000 + Math.random() * 120000) });
});

app.get('/api/v1/network/slices', (req, res) => {
  res.json({ slices: ['urllc-qod-gold', 'iot-massive-bronze', 'consumer-video-silver', 'enterprise-private-5g'].map((id, i) => ({ id, status: i === 0 ? 'RESERVED' : 'AVAILABLE', maxLatencyMs: [12, 80, 35, 20][i], maxThroughputMbps: [500, 20, 250, 1000][i], monetizationPlan: i === 0 ? 'network-premium' : 'enterprise-latam' })) });
});


// BEGIN OPEN GATEWAY / CAMARA DEMO ROUTES
function normalizeOpenGatewayMsisdn(value) {
  return decodeURIComponent(String(value || '+525512340001')).replace(/\s+/g, '');
}

function openGatewayCustomer(msisdn) {
  return customers[msisdn] || randomOf(Object.values(customers));
}

function openGatewayDecision(score) {
  if (score >= 80) return 'ALLOW';
  if (score >= 55) return 'STEP_UP';
  return 'BLOCK';
}

function openGatewayPartner(req) {
  return req.headers['x-partner-id'] || req.body?.partnerId || req.query.partnerId || 'digital-bank-demo';
}

app.post('/api/v1/open-gateway/number-verification/verify', (req, res) => {
  const msisdn = normalizeOpenGatewayMsisdn(req.body?.phoneNumber || req.body?.msisdn);
  const customer = openGatewayCustomer(msisdn);
  const country = countries.find(c => c.code === customer.country) || randomOf(countries);
  const verified = customer.msisdn === msisdn || customer.lifecycle === 'Active';
  const confidence = verified ? Number((0.88 + Math.random() * 0.11).toFixed(2)) : Number((0.25 + Math.random() * 0.35).toFixed(2));
  const trustScore = Math.round(confidence * 100) - (customer.riskScore > 20 ? 8 : 0);

  res.json({
    apiFamily: 'GSMA Open Gateway / CAMARA-style',
    capability: 'Number Verification',
    partnerId: openGatewayPartner(req),
    transactionId: req.body?.transactionId || `txn-${Date.now()}`,
    msisdn,
    country: country.code,
    operatorBrand: country.brand,
    subscriberStatus: customer.lifecycle?.toUpperCase?.() || 'UNKNOWN',
    verified,
    confidence,
    trustScore,
    riskSignals: verified ? ['NETWORK_NUMBER_MATCH', 'SUBSCRIBER_ACTIVE'] : ['NETWORK_NUMBER_MISMATCH'],
    decision: openGatewayDecision(trustScore),
    correlationId: req.headers['x-correlation-id'] || `corr-og-${Date.now()}`,
    timestamp: nowIso()
  });
});

app.get('/api/v1/open-gateway/sim-swap/:msisdn/risk', (req, res) => {
  const msisdn = normalizeOpenGatewayMsisdn(req.params.msisdn);
  const customer = openGatewayCustomer(msisdn);
  const country = countries.find(c => c.code === customer.country) || randomOf(countries);
  const lookbackHours = Math.max(Number(req.query.lookbackHours || 168), 1);

  const simulatedHours = customer.riskScore > 20
    ? Math.floor(2 + Math.random() * 36)
    : Math.floor(120 + Math.random() * 1200);

  const lastSimChangeAt = new Date(Date.now() - simulatedHours * 60 * 60 * 1000).toISOString();
  const riskScore = simulatedHours <= 24 ? 92 : simulatedHours <= 168 ? 63 : 18;
  const riskLevel = riskScore >= 85 ? 'CRITICAL' : riskScore >= 65 ? 'HIGH' : riskScore >= 40 ? 'MEDIUM' : 'LOW';

  res.json({
    apiFamily: 'GSMA Open Gateway / CAMARA-style',
    capability: 'SIM Swap',
    partnerId: openGatewayPartner(req),
    msisdn,
    country: country.code,
    lookbackHours,
    lastSimChangeAt,
    hoursSinceLastSimChange: simulatedHours,
    riskLevel,
    riskScore,
    coolingOffRecommended: riskScore >= 65,
    recommendedAction: riskScore >= 85 ? 'BLOCK' : riskScore >= 65 ? 'HOLD_TRANSACTION' : riskScore >= 40 ? 'STEP_UP' : 'ALLOW',
    correlationId: req.headers['x-correlation-id'] || `corr-og-${Date.now()}`,
    timestamp: nowIso()
  });
});

app.post('/api/v1/open-gateway/device-location/verify', (req, res) => {
  const msisdn = normalizeOpenGatewayMsisdn(req.body?.msisdn);
  const customer = openGatewayCustomer(msisdn);
  const expectedCountry = String(req.body?.expectedCountry || customer.country || 'MX').toUpperCase();
  const networkCountry = customer.country || randomOf(countries).code;
  const radiusKm = Number(req.body?.radiusKm || 25);
  const countryMatch = expectedCountry === networkCountry;
  const approximateDistanceKm = countryMatch
    ? Number((Math.random() * Math.max(radiusKm, 1)).toFixed(2))
    : Number((120 + Math.random() * 900).toFixed(2));

  const confidence = countryMatch ? Number((0.82 + Math.random() * 0.16).toFixed(2)) : Number((0.20 + Math.random() * 0.35).toFixed(2));
  const verificationResult = countryMatch ? 'MATCH' : 'NO_MATCH';
  const spoofingRisk = confidence >= 0.8 ? 'LOW' : confidence >= 0.5 ? 'MEDIUM' : 'HIGH';

  res.json({
    apiFamily: 'GSMA Open Gateway / CAMARA-style',
    capability: 'Location Verification',
    partnerId: openGatewayPartner(req),
    msisdn,
    expectedCountry,
    networkCountry,
    verificationResult,
    confidence,
    approximateDistanceKm,
    radiusKm,
    spoofingRisk,
    recommendedAction: verificationResult === 'MATCH' ? 'ALLOW' : 'STEP_UP',
    correlationId: req.headers['x-correlation-id'] || `corr-og-${Date.now()}`,
    timestamp: nowIso()
  });
});
// END OPEN GATEWAY / CAMARA DEMO ROUTES

app.post('/api/v1/network/slices/reservations', (req, res) => {
  res.status(201).json({ reservationId: `slice-res-${Date.now()}`, status: 'PENDING_ACTIVATION', requested: req.body, activationEtaSeconds: 45, chargePreviewUsd: 128.4 });
});

app.get('/api/v1/roaming/quote', (req, res) => {
  const country = req.query.country || 'US';
  res.json({ msisdn: req.query.msisdn || '+525512340001', destinationCountry: country, dailyPassUsd: 9.99, fairUseGb: 5, partnerNetwork: randomOf(['Partner Network Alpha', 'Partner Network Beta', 'Partner Network Gamma', 'Partner Network Delta', 'Partner Network Epsilon']) });
});

app.get('/api/v1/usage/summary', (req, res) => {
  const country = countries.find(c => c.code === req.query.country) || randomOf(countries);
  const calls = Math.floor(1200000 + Math.random() * 9000000);
  const revenue = Number((calls * (0.00025 + Math.random() * 0.001)).toFixed(2));
  res.json({ country: country.code, market: country.name, period: 'current-month', apiCalls: calls, billableCalls: Math.floor(calls * 0.82), revenueUsd: revenue, errorRatePct: Number((Math.random() * 1.8).toFixed(2)), topProduct: randomOf(apiProducts).name });
});

app.get('/api/v1/usage/events', (req, res) => {
  const count = Math.min(Number(req.query.count || 20), 100);
  res.json({ events: Array.from({ length: count }, () => networkEvent()) });
});

app.get('/api/v1/partners/:partnerId/settlement', (req, res) => {
  const partner = partners.find(p => p.id === req.params.partnerId) || randomOf(partners);
  const events = Math.floor(100000 + Math.random() * 1500000);
  res.json({ partner, period: 'current-month', billableEvents: events, grossRevenueUsd: Number((events * 0.0009).toFixed(2)), settlementStatus: randomOf(['READY', 'IN_REVIEW', 'PAID']), invoiceId: `INV-${partner.country}-${Date.now()}` });
});



// -----------------------------------------------------------------------------
// Candidate / pipeline API mock routes
// These routes back the "new candidate APIs" shown in the APIOps pipeline portal.
// APIM strips the API context/version before forwarding to this backend, so the
// backend receives paths such as /api/v1/venues, /api/v1/fleets/... etc.
// -----------------------------------------------------------------------------

const venueProfiles = [
  {
    venueId: 'azteca-mx',
    name: 'Estadio Azteca',
    country: 'MX',
    city: 'Mexico City',
    capacity: 87523,
    networkProfile: '5G-SA dense venue',
    peakThroughputMbps: 980,
    edgeSite: 'MX-MEX-EDGE-01',
    status: 'READY'
  },
  {
    venueId: 'morumbi-br',
    name: 'Estádio Morumbi',
    country: 'BR',
    city: 'São Paulo',
    capacity: 66795,
    networkProfile: '5G-NSA event overlay',
    peakThroughputMbps: 720,
    edgeSite: 'BR-SP-EDGE-03',
    status: 'READY'
  },
  {
    venueId: 'movistar-co',
    name: 'Movistar Arena Bogotá',
    country: 'CO',
    city: 'Bogotá',
    capacity: 14000,
    networkProfile: 'premium indoor DAS',
    peakThroughputMbps: 540,
    edgeSite: 'CO-BOG-EDGE-02',
    status: 'PLANNED'
  }
];

const venuePackages = [
  {
    packageId: 'fan-premium-5g',
    name: 'Fan Premium 5G',
    latencyTargetMs: 25,
    includedGb: 15,
    priceUsd: 7.99,
    features: ['priority radio access', 'AR replay stream', 'venue navigation']
  },
  {
    packageId: 'broadcast-uplink',
    name: 'Broadcast Uplink Boost',
    latencyTargetMs: 15,
    uplinkMbps: 120,
    priceUsd: 249.0,
    features: ['reserved uplink', 'QoD monitoring', 'event SLA']
  },
  {
    packageId: 'sponsor-captive-experience',
    name: 'Sponsor Captive Experience',
    latencyTargetMs: 35,
    includedGb: 500,
    priceUsd: 1200.0,
    features: ['sponsor landing page', 'zero-rated content', 'campaign analytics']
  }
];

const fleets = {
  'fleet-norte-001': {
    fleetId: 'fleet-norte-001',
    name: 'Northern Logistics Fleet',
    country: 'MX',
    customer: 'Continental Logistics',
    activeDevices: 1842,
    connectivityPlan: 'IoT Managed Connectivity Gold'
  },
  'fleet-sampa-002': {
    fleetId: 'fleet-sampa-002',
    name: 'São Paulo Cold Chain Fleet',
    country: 'BR',
    customer: 'FreshRoute Latam',
    activeDevices: 947,
    connectivityPlan: 'IoT Managed Connectivity Silver'
  }
};

const edgeSites = [
  {
    siteId: 'MX-MEX-EDGE-01',
    country: 'MX',
    city: 'Mexico City',
    status: 'ACTIVE',
    cacheHitRatioPct: 91.4,
    avgLatencyMs: 11
  },
  {
    siteId: 'BR-SP-EDGE-03',
    country: 'BR',
    city: 'São Paulo',
    status: 'ACTIVE',
    cacheHitRatioPct: 88.7,
    avgLatencyMs: 13
  },
  {
    siteId: 'CO-BOG-EDGE-02',
    country: 'CO',
    city: 'Bogotá',
    status: 'MAINTENANCE',
    cacheHitRatioPct: 74.2,
    avgLatencyMs: 24
  }
];

function candidateCorrelation(req) {
  return req.headers['x-correlation-id'] || `cand-${Date.now()}-${Math.floor(Math.random() * 1000)}`;
}

function candidateAccepted(type, payload = {}) {
  return {
    accepted: true,
    type,
    status: 'PENDING_ACTIVATION',
    requestId: `${type}-${Date.now()}`,
    submittedAt: nowIso(),
    etaSeconds: 45,
    ...payload
  };
}

// CandidateStadiumExperienceAPI
app.get('/api/v1/venues', (req, res) => {
  res.json({
    correlationId: candidateCorrelation(req),
    venues: venueProfiles,
    count: venueProfiles.length,
    source: 'candidate-stadium-experience-mock'
  });
});

app.get('/api/v1/venues/:venueId/packages', (req, res) => {
  const venue = venueProfiles.find(v => v.venueId === req.params.venueId) || venueProfiles[0];
  res.json({
    correlationId: candidateCorrelation(req),
    venue,
    packages: venuePackages,
    commercialModel: 'event-package',
    source: 'candidate-stadium-experience-mock'
  });
});

app.post('/api/v1/venues/:venueId/packages', (req, res) => {
  const venue = venueProfiles.find(v => v.venueId === req.params.venueId) || venueProfiles[0];
  res.status(202).json(candidateAccepted('venue-package-reservation', {
    venue,
    requestedPackage: req.body || {},
    chargePreviewUsd: 128.5
  }));
});

// CandidateIoTFleetTelemetryAPI
app.get('/api/v1/fleets/:fleetId/devices', (req, res) => {
  const fleet = fleets[req.params.fleetId] || fleets['fleet-norte-001'];
  const devices = Array.from({ length: 8 }, (_, i) => ({
    deviceId: `${fleet.fleetId}-dev-${String(i + 1).padStart(4, '0')}`,
    msisdn: `+52${Math.floor(5500000000 + Math.random() * 99999999)}`,
    imei: `35976210${Math.floor(1000000 + Math.random() * 8999999)}`,
    status: randomOf(['ONLINE', 'ONLINE', 'ONLINE', 'DEGRADED', 'OFFLINE']),
    lastHeartbeat: nowIso(),
    batteryPct: Math.floor(35 + Math.random() * 65),
    rat: randomOf(['LTE-M', 'NB-IoT', '4G', '5G-NSA'])
  }));

  res.json({
    correlationId: candidateCorrelation(req),
    fleet,
    devices,
    count: devices.length,
    source: 'candidate-iot-fleet-telemetry-mock'
  });
});

app.get('/api/v1/fleets/:fleetId/telemetry/summary', (req, res) => {
  const fleet = fleets[req.params.fleetId] || fleets['fleet-norte-001'];
  res.json({
    correlationId: candidateCorrelation(req),
    fleet,
    period: 'last-15-minutes',
    activeDevices: fleet.activeDevices,
    onlinePct: Number((88 + Math.random() * 10).toFixed(2)),
    avgLatencyMs: Math.floor(35 + Math.random() * 90),
    messagesPerMinute: Math.floor(25000 + Math.random() * 80000),
    anomalyCount: Math.floor(Math.random() * 12),
    source: 'candidate-iot-fleet-telemetry-mock'
  });
});

// CandidateDroneInspectionEventsAPI OpenAPI façade
app.get('/api/v1/events/drone-inspections', (req, res) => {
  const events = Array.from({ length: 10 }, (_, i) => ({
    eventId: `drone-insp-${Date.now()}-${i}`,
    timestamp: nowIso(),
    towerId: randomOf(['MX-TWR-00921', 'BR-TWR-11882', 'CL-TWR-00419']),
    eventType: randomOf(['tower.inspection.completed', 'tower.maintenance.dispatch.requested']),
    severity: randomOf(['LOW', 'MEDIUM', 'HIGH']),
    confidence: Number((0.78 + Math.random() * 0.21).toFixed(3)),
    finding: randomOf(['antenna alignment drift', 'cabinet door anomaly', 'vegetation risk', 'no finding']),
    dispatchRecommended: Math.random() > 0.5
  }));

  res.json({
    correlationId: candidateCorrelation(req),
    stream: 'candidate-drone-inspection-events',
    events,
    source: 'candidate-drone-inspection-events-mock'
  });
});

// CandidateFieldWorkOrderSOAPFacade
app.post('/api/v1/field/workorders', (req, res) => {
  res.status(202).json(candidateAccepted('field-workorder', {
    workOrderId: `wo-${Date.now()}`,
    priority: req.body?.priority || randomOf(['LOW', 'MEDIUM', 'HIGH']),
    assignedRegion: req.body?.region || randomOf(['MX-CENTRAL', 'BR-SOUTH', 'AR-AMBA']),
    legacyBackend: 'CandidateFieldWorkOrderService'
  }));
});

app.get('/api/v1/field/workorders/:workOrderId', (req, res) => {
  res.json({
    correlationId: candidateCorrelation(req),
    workOrderId: req.params.workOrderId,
    status: randomOf(['CREATED', 'DISPATCHED', 'IN_PROGRESS', 'COMPLETED']),
    priority: randomOf(['LOW', 'MEDIUM', 'HIGH']),
    technicianTeam: randomOf(['Field Ops Alpha', 'Field Ops Beta', 'Contractor Partner 7']),
    scheduledWindow: {
      start: nowIso(),
      durationMinutes: 120
    },
    source: 'candidate-field-workorder-soap-facade-mock'
  });
});

// CandidateEdgeCacheControlAPI
app.get('/api/v1/edge/sites', (req, res) => {
  res.json({
    correlationId: candidateCorrelation(req),
    sites: edgeSites,
    count: edgeSites.length,
    source: 'candidate-edge-cache-control-mock'
  });
});

app.post('/api/v1/edge/cache/invalidation', (req, res) => {
  res.status(202).json(candidateAccepted('edge-cache-invalidation', {
    invalidationId: `inv-${Date.now()}`,
    targetSite: req.body?.siteId || randomOf(edgeSites).siteId,
    paths: req.body?.paths || ['/sports/live/*', '/concerts/premium/*']
  }));
});

app.post('/api/v1/edge/cache/prewarm', (req, res) => {
  res.status(202).json(candidateAccepted('edge-cache-prewarm', {
    prewarmId: `prewarm-${Date.now()}`,
    targetSite: req.body?.siteId || randomOf(edgeSites).siteId,
    objects: req.body?.objects || ['/campaigns/stadium-launch/hero.mp4']
  }));
});

// Negative scenario mocks, useful if someone manually deploys rejected APIs for testing.
app.post('/api/v1/roaming/sponsorships', (req, res) => {
  res.status(202).json(candidateAccepted('roaming-sponsorship', {
    warning: 'This backend exists, but the candidate API should be rejected by governance because monetization metadata is missing.',
    sponsorId: req.body?.sponsorId || 'demo-sponsor'
  }));
});

app.post('/api/v1/devices/certifications', (req, res) => {
  res.status(202).json(candidateAccepted('device-certification', {
    warning: 'This backend exists, but the candidate API should be rejected by governance because health-check metadata is missing.',
    certificationId: `cert-${Date.now()}`
  }));
});


app.get('/events/network-events', (req, res) => {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
    'Access-Control-Allow-Origin': '*'
  });
  res.write(`event: connected\ndata: ${JSON.stringify({ ok: true, stream: 'network-events', timestamp: nowIso() })}\n\n`);
  const timer = setInterval(() => {
    const ev = networkEvent();
    res.write(`id: ${ev.id}\nevent: ${ev.eventType}\ndata: ${JSON.stringify(ev)}\n\n`);
  }, 1200);
  req.on('close', () => clearInterval(timer));
});

app.post('/webhooks/network-events', (req, res) => {
  res.status(202).json({ received: true, timestamp: nowIso(), payload: req.body, callbackCorrelationId: req.headers['x-hub-signature'] || `webhook-${Date.now()}` });
});

app.get('/wsdl/billing-adjustment.wsdl', (req, res) => {
  res.type('application/xml').send(wsdlXml(`http://localhost:${port}/soap/billing-adjustment`));
});

app.post('/soap/billing-adjustment', (req, res) => {
  const body = typeof req.body === 'string' ? req.body : '';
  const msisdn = (body.match(/<msisdn>(.*?)<\/msisdn>/) || [null, '+525512340001'])[1];
  const amount = (body.match(/<amount>(.*?)<\/amount>/) || [null, '0.00'])[1];
  const reason = (body.match(/<reasonCode>(.*?)<\/reasonCode>/) || [null, 'DEMO_CREDIT'])[1];
  const response = `<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:bil="http://demo.telco.wso2.com/billing">
  <soapenv:Header/>
  <soapenv:Body>
    <bil:CreateBillingAdjustmentResponse>
      <bil:adjustmentId>ADJ-${Date.now()}</bil:adjustmentId>
      <bil:msisdn>${escapeXml(msisdn)}</bil:msisdn>
      <bil:amount>${escapeXml(amount)}</bil:amount>
      <bil:reasonCode>${escapeXml(reason)}</bil:reasonCode>
      <bil:status>ACCEPTED</bil:status>
      <bil:auditRequired>true</bil:auditRequired>
    </bil:CreateBillingAdjustmentResponse>
  </soapenv:Body>
</soapenv:Envelope>`;
  res.type('text/xml').send(response);
});

function escapeXml(value) {
  return String(value).replace(/[<>&'"]/g, c => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', "'": '&apos;', '"': '&quot;' }[c]));
}

function wsdlXml(endpoint) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<definitions xmlns="http://schemas.xmlsoap.org/wsdl/"
             xmlns:soap="http://schemas.xmlsoap.org/wsdl/soap/"
             xmlns:tns="http://demo.telco.wso2.com/billing"
             xmlns:xsd="http://www.w3.org/2001/XMLSchema"
             targetNamespace="http://demo.telco.wso2.com/billing"
             name="BillingAdjustmentService">
  <types>
    <xsd:schema targetNamespace="http://demo.telco.wso2.com/billing">
      <xsd:element name="CreateBillingAdjustmentRequest">
        <xsd:complexType><xsd:sequence>
          <xsd:element name="msisdn" type="xsd:string"/>
          <xsd:element name="amount" type="xsd:decimal"/>
          <xsd:element name="currency" type="xsd:string"/>
          <xsd:element name="reasonCode" type="xsd:string"/>
          <xsd:element name="requestor" type="xsd:string"/>
        </xsd:sequence></xsd:complexType>
      </xsd:element>
      <xsd:element name="CreateBillingAdjustmentResponse">
        <xsd:complexType><xsd:sequence>
          <xsd:element name="adjustmentId" type="xsd:string"/>
          <xsd:element name="msisdn" type="xsd:string"/>
          <xsd:element name="status" type="xsd:string"/>
          <xsd:element name="auditRequired" type="xsd:boolean"/>
        </xsd:sequence></xsd:complexType>
      </xsd:element>
    </xsd:schema>
  </types>
  <message name="CreateBillingAdjustmentInput"><part name="parameters" element="tns:CreateBillingAdjustmentRequest"/></message>
  <message name="CreateBillingAdjustmentOutput"><part name="parameters" element="tns:CreateBillingAdjustmentResponse"/></message>
  <portType name="BillingAdjustmentPortType">
    <operation name="CreateBillingAdjustment"><input message="tns:CreateBillingAdjustmentInput"/><output message="tns:CreateBillingAdjustmentOutput"/></operation>
  </portType>
  <binding name="BillingAdjustmentSoapBinding" type="tns:BillingAdjustmentPortType">
    <soap:binding transport="http://schemas.xmlsoap.org/soap/http" style="document"/>
    <operation name="CreateBillingAdjustment"><soap:operation soapAction="CreateBillingAdjustment"/><input><soap:body use="literal"/></input><output><soap:body use="literal"/></output></operation>
  </binding>
  <service name="BillingAdjustmentService">
    <port name="BillingAdjustmentPort" binding="tns:BillingAdjustmentSoapBinding"><soap:address location="${endpoint}"/></port>
  </service>
</definitions>`;
}


// -----------------------------------------------------------------------------
// CandidatePartnerInsightsGraphQLAPI
// Real GraphQL backend used only by the APIOps pipeline candidate.
// -----------------------------------------------------------------------------
const partnerInsightGraphqlSchema = buildSchema(`
schema {
  query: Query
  mutation: Mutation
}

type Query {
  schemaHealth: SchemaHealth!
  partnerInsight(partnerId: ID!): PartnerInsight
  partnerPortfolio(country: String, segment: String): [PartnerInsight!]!
  marketplaceRecommendations(partnerId: ID!, country: String): [ApiRecommendation!]!
  subscriberOpportunity(msisdn: String!): SubscriberOpportunity!
}

type Mutation {
  reservePartnerCampaign(input: CampaignReservationInput!): CampaignReservationResult!
}

type SchemaHealth {
  ok: Boolean!
  service: String!
  timestamp: String!
}

type PartnerInsight {
  partnerId: ID!
  name: String!
  segment: String!
  country: String!
  tier: String!
  activeSubscribers: Int!
  monthlyApiCalls: Int!
  revenueUsd: Float!
  churnRisk: String!
  recommendedApis: [ApiRecommendation!]!
}

type ApiRecommendation {
  apiName: String!
  apiProduct: String!
  reason: String!
  fitScore: Int!
  monetizationModel: String!
}

type SubscriberOpportunity {
  msisdn: String!
  country: String!
  customerSegment: String!
  consentReady: Boolean!
  eligibleOffers: [String!]!
  recommendedPartner: PartnerInsight!
}

input CampaignReservationInput {
  partnerId: ID!
  country: String!
  campaignName: String!
  targetSegment: String!
  budgetUsd: Float!
}

type CampaignReservationResult {
  reservationId: ID!
  accepted: Boolean!
  status: String!
  estimatedReach: Int!
  chargePreviewUsd: Float!
  submittedAt: String!
}
`);

const partnerInsightRecords = [
  {
    partnerId: 'banking-superapp',
    name: 'Continental SuperApp Bank',
    segment: 'Fintech',
    country: 'MX',
    tier: 'Platinum',
    activeSubscribers: 1830000,
    monthlyApiCalls: 47200000,
    revenueUsd: 146500.25,
    churnRisk: 'LOW'
  },
  {
    partnerId: 'ride-hailing',
    name: 'UrbanMove Mobility',
    segment: 'Mobility',
    country: 'BR',
    tier: 'Gold',
    activeSubscribers: 940000,
    monthlyApiCalls: 28100000,
    revenueUsd: 78200.90,
    churnRisk: 'MEDIUM'
  },
  {
    partnerId: 'iot-energy',
    name: 'Andes Smart Energy',
    segment: 'IoT',
    country: 'CO',
    tier: 'Gold',
    activeSubscribers: 420000,
    monthlyApiCalls: 19300000,
    revenueUsd: 51990.00,
    churnRisk: 'LOW'
  },
  {
    partnerId: 'retail-marketplace',
    name: 'Digital Retail Partner',
    segment: 'Retail',
    country: 'CL',
    tier: 'Enterprise',
    activeSubscribers: 610000,
    monthlyApiCalls: 22400000,
    revenueUsd: 66850.45,
    churnRisk: 'MEDIUM'
  }
];

function partnerRecommendations(partnerId, country) {
  const byPartner = {
    'banking-superapp': [
      ['Customer360API', 'Partner Growth Pack', 'Consent-aware customer profile and eligibility checks for financial journeys.', 94, 'REVENUE_SHARE'],
      ['NumberLifecycleAPI', 'Partner Growth Pack', 'Number verification and portability intelligence for onboarding.', 89, 'PER_TRANSACTION']
    ],
    'ride-hailing': [
      ['NetworkSliceAPI', 'Network Monetization Pack', 'Low-latency mobility corridors and QoD-backed premium trips.', 91, 'USAGE_BASED'],
      ['PartnerChargingAPI', 'Partner Growth Pack', 'Settlement and charging for sponsored mobility bundles.', 86, 'REVENUE_SHARE']
    ],
    'iot-energy': [
      ['CandidateIoTFleetTelemetryAPI', 'Enterprise IoT Pack', 'Fleet and device telemetry for managed connectivity.', 96, 'SUBSCRIPTION_PLUS_OVERAGE'],
      ['NetworkEventsStreamAPI', 'Network Monetization Pack', 'Operational event stream for field and network anomaly detection.', 88, 'EVENT_STREAM']
    ],
    'retail-marketplace': [
      ['Customer360API', 'Partner Growth Pack', 'Audience segmentation with consent-aware customer data access.', 90, 'REVENUE_SHARE'],
      ['CandidateEdgeCacheControlAPI', 'Edge Services Pack', 'Regional edge pre-warming for campaign and media assets.', 84, 'USAGE_BASED']
    ]
  };

  const records = byPartner[partnerId] || byPartner['banking-superapp'];

  return records.map(([apiName, apiProduct, reason, fitScore, monetizationModel]) => ({
    apiName,
    apiProduct,
    reason: country ? `${reason} Market focus: ${country}.` : reason,
    fitScore,
    monetizationModel
  }));
}

function enrichPartnerInsight(record) {
  return {
    ...record,
    recommendedApis: partnerRecommendations(record.partnerId, record.country)
  };
}

function inferCountryFromMsisdn(msisdn) {
  if (String(msisdn).startsWith('+55')) return 'BR';
  if (String(msisdn).startsWith('+57')) return 'CO';
  if (String(msisdn).startsWith('+56')) return 'CL';
  return 'MX';
}

function partnerInsightResolvers() {
  return {
    schemaHealth: () => ({
      ok: true,
      service: 'candidate-partner-insights-graphql',
      timestamp: nowIso()
    }),

    partnerInsight: ({ partnerId }) => {
      const record = partnerInsightRecords.find(p => p.partnerId === partnerId);
      return record ? enrichPartnerInsight(record) : null;
    },

    partnerPortfolio: ({ country, segment }) => {
      return partnerInsightRecords
        .filter(p => !country || p.country === country)
        .filter(p => !segment || p.segment.toLowerCase() === String(segment).toLowerCase())
        .map(enrichPartnerInsight);
    },

    marketplaceRecommendations: ({ partnerId, country }) => partnerRecommendations(partnerId, country),

    subscriberOpportunity: ({ msisdn }) => {
      const country = inferCountryFromMsisdn(msisdn);
      const partner = partnerInsightRecords.find(p => p.country === country) || partnerInsightRecords[0];

      return {
        msisdn,
        country,
        customerSegment: country === 'BR' ? 'Postpaid Consumer' : 'Postpaid Premium',
        consentReady: true,
        eligibleOffers: [
          'partner-data-share',
          'number-verification',
          'sponsored-connectivity',
          'premium-qod-bundle'
        ],
        recommendedPartner: enrichPartnerInsight(partner)
      };
    },

    reservePartnerCampaign: ({ input }) => {
      const baseReach = Math.max(25000, Math.floor(Number(input.budgetUsd || 0) * 38));

      return {
        reservationId: `gql-campaign-${Date.now()}`,
        accepted: true,
        status: 'PENDING_COMMERCIAL_APPROVAL',
        estimatedReach: baseReach,
        chargePreviewUsd: Number((Number(input.budgetUsd || 0) * 0.082).toFixed(2)),
        submittedAt: nowIso()
      };
    }
  };
}

async function handlePartnerInsightsGraphQL(req, res) {
  try {
    if (req.method === 'GET' && !req.query.query) {
      return res.json({
        service: 'candidate-partner-insights-graphql',
        endpoint: '/graphql/partner-insights',
        example: {
          query: 'query PartnerPortfolio($country: String) { partnerPortfolio(country: $country) { partnerId name country tier recommendedApis { apiName fitScore monetizationModel } } }',
          variables: { country: 'BR' }
        }
      });
    }

    const source = req.method === 'GET' ? req.query.query : req.body?.query;
    const operationName = req.method === 'GET' ? req.query.operationName : req.body?.operationName;
    let variableValues = req.method === 'GET' ? req.query.variables : req.body?.variables;

    if (typeof variableValues === 'string' && variableValues.trim()) {
      variableValues = JSON.parse(variableValues);
    }

    if (!source) {
      return res.status(400).json({
        errors: [{ message: 'GraphQL query is required.' }]
      });
    }

    const result = await graphql({
      schema: partnerInsightGraphqlSchema,
      source,
      rootValue: partnerInsightResolvers(),
      variableValues,
      operationName,
      contextValue: {
        correlationId: req.headers['x-correlation-id'] || `gql-${Date.now()}`
      }
    });

    res.status(result.errors ? 400 : 200).json(result);
  } catch (e) {
    res.status(400).json({
      errors: [{ message: e.message }]
    });
  }
}

app.get('/graphql/partner-insights', handlePartnerInsightsGraphQL);
app.post('/graphql/partner-insights', handlePartnerInsightsGraphQL);

const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: '/ws/network-events' });
wss.on('connection', ws => {
  ws.send(JSON.stringify({ type: 'connected', stream: 'network-events', timestamp: nowIso() }));
  const timer = setInterval(() => {
    if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(networkEvent()));
  }, 1300);
  ws.on('close', () => clearInterval(timer));
});



// CandidateFieldWorkOrderSOAPAPI - SOAP pass-through backend mock.
// Used by the pipeline SOAP candidate when imported as a real WSDL/SOAP API.
app.post('/soap/candidate-field-workorder', express.text({ type: '*/*', limit: '2mb' }), (req, res) => {
  res.type('application/xml').send(`<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:fw="http://example.com/telco/field-workorder">
  <soapenv:Body>
    <fw:CreateWorkOrderResponse>
      <fw:workOrderId>wo-${Date.now()}</fw:workOrderId>
      <fw:status>ACCEPTED</fw:status>
      <fw:priority>HIGH</fw:priority>
      <fw:source>candidate-field-workorder-soap-mock</fw:source>
    </fw:CreateWorkOrderResponse>
  </soapenv:Body>
</soapenv:Envelope>`);
});


server.listen(port, () => console.log(`Telco mock backend running on ${port}`));

app.get('/events/drone-inspections', (req, res) => {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no'
  });

  let counter = 0;
  const towers = ['TOWER-BR-SP-009', 'TOWER-BR-RJ-014', 'TOWER-BR-MG-021'];
  const statuses = ['COMPLETED', 'ATTENTION_REQUIRED', 'MAINTENANCE_DISPATCHED'];
  const severities = ['INFO', 'WARNING', 'CRITICAL'];

  const writeEvent = () => {
    counter += 1;

    const event = {
      eventId: `DRONE-EVT-${String(counter).padStart(5, '0')}`,
      towerId: towers[counter % towers.length],
      inspectionStatus: statuses[counter % statuses.length],
      severity: severities[counter % severities.length],
      timestamp: new Date().toISOString()
    };

    res.write('event: drone-inspection\n');
    res.write(`data: ${JSON.stringify(event)}\n\n`);
  };

  writeEvent();
  const interval = setInterval(writeEvent, 1500);

  req.on('close', () => {
    clearInterval(interval);
  });
});
