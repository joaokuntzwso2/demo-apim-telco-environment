'use strict';

const http = require('http');
const { randomUUID } = require('crypto');

const PORT = Number(process.env.PORT || 8080);
const SERVICE_KIND = String(process.env.SERVICE_KIND || 'crm').toLowerCase();
const CRM_LEGACY_KEY = process.env.CRM_LEGACY_KEY || 'crm-demo-key';
const OSS_LEGACY_KEY = process.env.OSS_LEGACY_KEY || 'oss-demo-key';

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', chunk => {
      size += chunk.length;
      if (size > 1024 * 1024) {
        reject(new Error('request body exceeds 1 MiB'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function send(res, status, contentType, body, correlationId) {
  const payload = Buffer.from(body, 'utf8');
  res.writeHead(status, {
    'Content-Type': contentType,
    'Content-Length': payload.length,
    'X-Correlation-ID': correlationId
  });
  res.end(payload);
}

function sendJson(res, status, value, correlationId) {
  send(res, status, 'application/json; charset=utf-8', JSON.stringify(value), correlationId);
}

function xmlEscape(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
}

function xmlValue(xml, tag) {
  const expression = new RegExp(
    `<(?:[A-Za-z_][\\w.-]*:)?${tag}(?:\\s[^>]*)?>([\\s\\S]*?)<\\/(?:[A-Za-z_][\\w.-]*:)?${tag}>`,
    'i'
  );
  const match = String(xml || '').match(expression);
  return match ? match[1].trim() : '';
}

function lastDigit(msisdn) {
  const digits = String(msisdn || '').replace(/\D/g, '');
  return digits ? Number(digits.at(-1)) : 0;
}

function parseJson(raw) {
  try {
    return JSON.parse(raw || '{}');
  } catch {
    return null;
  }
}

function matchesServiceHeader(req, headerName) {
  const requested = String(req.headers[headerName] || '')
    .split(',')
    .map(item => item.trim().toLowerCase())
    .filter(Boolean);
  return requested.includes(SERVICE_KIND) || requested.includes('all');
}

async function applyChaos(req, res, correlationId) {
  if (matchesServiceHeader(req, 'x-demo-delay-service')) {
    const requestedDelay = Number(req.headers['x-demo-delay-ms'] || 2500);
    const delayMs = Number.isFinite(requestedDelay)
      ? Math.max(0, Math.min(requestedDelay, 30000))
      : 2500;
    console.log(JSON.stringify({
      event: 'demo-delay',
      service: SERVICE_KIND,
      delayMs,
      correlationId
    }));
    await new Promise(resolve => setTimeout(resolve, delayMs));
  }

  if (matchesServiceHeader(req, 'x-demo-fail-service')) {
    const mode = String(req.headers['x-demo-fail-mode'] || 'transport').toLowerCase();
    console.log(JSON.stringify({
      event: 'demo-failure',
      service: SERVICE_KIND,
      mode,
      correlationId
    }));

    if (mode === 'http') {
      sendJson(res, 503, {
        type: 'https://demo.telco/errors/backend-unavailable',
        title: 'Backend unavailable',
        status: 503,
        service: SERVICE_KIND,
        correlationId
      }, correlationId);
      return true;
    }

    // A transport failure is intentional: MI treats connection resets/timeouts as
    // endpoint failures, allowing failover, retry and suspension/circuit-breaker
    // state to be demonstrated.
    req.socket.destroy();
    return true;
  }

  return false;
}

function crmResponse(raw, res, correlationId) {
  if (String(res.req.headers['x-legacy-system-key'] || '') !== CRM_LEGACY_KEY) {
    send(res, 401, 'application/xml; charset=utf-8',
      `<?xml version="1.0" encoding="UTF-8"?>
<crm:LegacyFault xmlns:crm="urn:telco:crm:legacy">
  <crm:Code>CRM-401</crm:Code>
  <crm:Message>Invalid legacy CRM system key</crm:Message>
  <crm:CorrelationId>${xmlEscape(correlationId)}</crm:CorrelationId>
</crm:LegacyFault>`,
      correlationId);
    return;
  }

  const msisdn = xmlValue(raw, 'Msisdn');
  const partnerId = xmlValue(raw, 'PartnerId');
  const digit = lastDigit(msisdn);
  const accountStatus = digit === 9 ? 'SUSPENDED' : 'ACTIVE';
  const fraudWatch = digit === 7;
  const tenureMonths = 12 + ((digit + 1) * 7);

  send(res, 200, 'application/xml; charset=utf-8',
    `<?xml version="1.0" encoding="UTF-8"?>
<crm:AccountStatusResponse xmlns:crm="urn:telco:crm:legacy">
  <crm:Msisdn>${xmlEscape(msisdn)}</crm:Msisdn>
  <crm:PartnerId>${xmlEscape(partnerId)}</crm:PartnerId>
  <crm:AccountStatus>${accountStatus}</crm:AccountStatus>
  <crm:FraudWatch>${fraudWatch}</crm:FraudWatch>
  <crm:TenureMonths>${tenureMonths}</crm:TenureMonths>
  <crm:Segment>${digit % 2 === 0 ? 'CONSUMER' : 'BUSINESS'}</crm:Segment>
  <crm:CorrelationId>${xmlEscape(correlationId)}</crm:CorrelationId>
</crm:AccountStatusResponse>`,
    correlationId);
}

function simSwapResponse(raw, res, correlationId) {
  const body = parseJson(raw);
  if (!body || !body.msisdn) {
    sendJson(res, 400, {
      type: 'https://demo.telco/errors/invalid-request',
      title: 'msisdn is required',
      status: 400,
      correlationId
    }, correlationId);
    return;
  }

  const digit = lastDigit(body.msisdn);
  const ageHours = digit === 8 ? 3 : digit === 6 ? 48 : 720;
  sendJson(res, 200, {
    msisdn: body.msisdn,
    swapDetected: ageHours <= 168,
    lastSwapAgeHours: ageHours,
    confidence: ageHours <= 24 ? 0.99 : ageHours <= 168 ? 0.91 : 0.98,
    source: 'SIM_CHANGE_EVENT_STORE',
    correlationId
  }, correlationId);
}

function deviceLocationResponse(raw, res, correlationId) {
  const body = parseJson(raw);
  if (!body || !body.msisdn || body.latitude == null || body.longitude == null) {
    sendJson(res, 400, {
      type: 'https://demo.telco/errors/invalid-request',
      title: 'msisdn, latitude and longitude are required',
      status: 400,
      correlationId
    }, correlationId);
    return;
  }

  const digit = lastDigit(body.msisdn);
  const expectedCountry = String(body.expectedCountry || 'MX').toUpperCase();
  const networkCountry = digit === 5
    ? (expectedCountry === 'MX' ? 'US' : 'MX')
    : expectedCountry;
  const verified = networkCountry === expectedCountry;

  sendJson(res, 200, {
    msisdn: body.msisdn,
    verified,
    expectedCountry,
    networkCountry,
    accuracyMeters: verified ? 42 : 18000,
    networkObservedLocation: {
      latitude: verified ? Number(body.latitude) + 0.00012 : Number(body.latitude) + 2.25,
      longitude: verified ? Number(body.longitude) - 0.00009 : Number(body.longitude) - 2.10
    },
    correlationId
  }, correlationId);
}

function ossResponse(raw, res, correlationId) {
  if (String(res.req.headers['x-legacy-system-key'] || '') !== OSS_LEGACY_KEY) {
    send(res, 401, 'text/plain; charset=utf-8',
      `ERROR|OSS-401|INVALID_SYSTEM_KEY|${correlationId}`,
      correlationId);
    return;
  }

  const parts = String(raw || '').trim().split('|');
  if (parts[0] !== 'NETWORK_STATUS' || parts.length < 5) {
    send(res, 400, 'text/plain; charset=utf-8',
      `ERROR|OSS-400|INVALID_LEGACY_MESSAGE|${correlationId}`,
      correlationId);
    return;
  }

  const [, version, msisdn, transactionId, partnerId] = parts;
  const digit = lastDigit(msisdn);
  const roaming = digit === 4;
  const networkStatus = digit === 3 ? 'DEGRADED' : 'NORMAL';
  const accessType = digit % 2 === 0 ? '5G_SA' : 'LTE';

  send(res, 200, 'text/plain; charset=utf-8',
    [
      'NETWORK_STATUS_RESPONSE',
      version,
      msisdn,
      transactionId,
      partnerId,
      roaming ? 'ROAMING' : 'HOME',
      networkStatus,
      accessType,
      correlationId
    ].join('|'),
    correlationId);
}

const routes = {
  crm: { method: 'POST', path: '/legacy/account-status', handler: crmResponse },
  'sim-swap': { method: 'POST', path: '/risk/sim-swap', handler: simSwapResponse },
  'device-location': { method: 'POST', path: '/location/verify', handler: deviceLocationResponse },
  oss: { method: 'POST', path: '/legacy/network-status', handler: ossResponse }
};

const server = http.createServer(async (req, res) => {
  const correlationId = String(req.headers['x-correlation-id'] || randomUUID());
  const startedAt = Date.now();

  try {
    if (req.method === 'GET' && req.url === '/health') {
      sendJson(res, 200, {
        status: 'UP',
        service: SERVICE_KIND,
        timestamp: new Date().toISOString()
      }, correlationId);
      return;
    }

    const route = routes[SERVICE_KIND];
    if (!route || req.method !== route.method || req.url !== route.path) {
      sendJson(res, 404, {
        type: 'https://demo.telco/errors/not-found',
        title: 'Route not found',
        status: 404,
        service: SERVICE_KIND,
        correlationId
      }, correlationId);
      return;
    }

    if (await applyChaos(req, res, correlationId)) {
      return;
    }

    const raw = await readBody(req);
    route.handler(raw, res, correlationId);
  } catch (error) {
    console.error(JSON.stringify({
      event: 'backend-error',
      service: SERVICE_KIND,
      correlationId,
      message: error.message,
      stack: error.stack
    }));
    if (!res.headersSent) {
      sendJson(res, 500, {
        type: 'https://demo.telco/errors/internal',
        title: 'Unexpected mock backend error',
        status: 500,
        service: SERVICE_KIND,
        correlationId
      }, correlationId);
    } else {
      res.destroy(error);
    }
  } finally {
    console.log(JSON.stringify({
      event: 'backend-request',
      service: SERVICE_KIND,
      method: req.method,
      path: req.url,
      correlationId,
      durationMs: Date.now() - startedAt
    }));
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(JSON.stringify({
    event: 'backend-started',
    service: SERVICE_KIND,
    port: PORT
  }));
});
