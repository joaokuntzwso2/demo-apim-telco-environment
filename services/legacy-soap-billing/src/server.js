'use strict';

const http = require('http');
const crypto = require('crypto');

const port = Number(process.env.PORT || 8080);
const backendNode = String(process.env.BACKEND_NODE || 'PRIMARY').toUpperCase();
const wsseUsername = String(process.env.WSSE_USERNAME || 'mi-modernization');
const wssePassword = String(process.env.WSSE_PASSWORD || 'change-me-demo-only');
const adminKey = String(process.env.DEMO_ADMIN_KEY || 'demo-admin-key');
const defaultDelayMs = Number(process.env.DEFAULT_DELAY_MS || 0);
const publicServiceUrl = String(
  process.env.PUBLIC_SERVICE_URL ||
  `http://legacy-billing-${backendNode.toLowerCase()}:8080/LegacyBillingAdjustmentService`
);

const transactions = new Map();
let mode = 'normal';
let modeDelayMs = defaultDelayMs;

function escapeXml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
}

function decodeXml(value) {
  return String(value ?? '')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');
}

function tagValue(xml, localName) {
  const pattern = new RegExp(
    `<(?:[A-Za-z_][\\w.-]*:)?${localName}(?:\\s[^>]*)?>([\\s\\S]*?)<\\/(?:[A-Za-z_][\\w.-]*:)?${localName}>`,
    'i'
  );
  const match = pattern.exec(xml);
  return match ? decodeXml(match[1].trim()) : '';
}

function hasSoapAction(req, expected) {
  const raw = String(req.headers.soapaction || '').replaceAll('"', '').trim();
  return !raw || raw === expected;
}

function soapEnvelope(body, correlationId = '') {
  return `<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
                  xmlns:leg="urn:americamovil:bss:billing:v1">
  <soapenv:Header>
    <leg:CorrelationId>${escapeXml(correlationId)}</leg:CorrelationId>
  </soapenv:Header>
  <soapenv:Body>
${body}
  </soapenv:Body>
</soapenv:Envelope>`;
}

function soapFault(code, message, correlationId) {
  return soapEnvelope(`    <soapenv:Fault>
      <faultcode>soapenv:Server</faultcode>
      <faultstring>${escapeXml(message)}</faultstring>
      <detail>
        <leg:LegacyBillingFault>
          <leg:code>${escapeXml(code)}</leg:code>
          <leg:message>${escapeXml(message)}</leg:message>
          <leg:backendNode>${escapeXml(backendNode)}</leg:backendNode>
          <leg:correlationId>${escapeXml(correlationId)}</leg:correlationId>
        </leg:LegacyBillingFault>
      </detail>
    </soapenv:Fault>`, correlationId);
}

function send(res, status, contentType, body, headers = {}) {
  res.writeHead(status, {
    'Content-Type': contentType,
    'Content-Length': Buffer.byteLength(body),
    'X-Legacy-Backend-Node': backendNode,
    ...headers,
  });
  res.end(body);
}

function sendJson(res, status, object) {
  send(res, status, 'application/json; charset=utf-8', JSON.stringify(object, null, 2));
}

function readBody(req, maxBytes = 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', (chunk) => {
      body += chunk;
      if (Buffer.byteLength(body) > maxBytes) {
        reject(new Error('Request body exceeds limit'));
        req.destroy();
      }
    });
    req.on('end', () => resolve(body));
    req.on('error', reject);
  });
}

function validateWsSecurity(xml) {
  const username = tagValue(xml, 'Username');
  const password = tagValue(xml, 'Password');
  return username === wsseUsername && password === wssePassword;
}

function wsdl() {
  return `<?xml version="1.0" encoding="UTF-8"?>
<wsdl:definitions xmlns:wsdl="http://schemas.xmlsoap.org/wsdl/"
                  xmlns:soap="http://schemas.xmlsoap.org/wsdl/soap/"
                  xmlns:xsd="http://www.w3.org/2001/XMLSchema"
                  xmlns:tns="urn:americamovil:bss:billing:v1"
                  targetNamespace="urn:americamovil:bss:billing:v1"
                  name="LegacyBillingAdjustmentService">
  <wsdl:types>
    <xsd:schema targetNamespace="urn:americamovil:bss:billing:v1" elementFormDefault="qualified">
      <xsd:element name="AdjustBillingRequest">
        <xsd:complexType><xsd:sequence>
          <xsd:element name="transactionId" type="xsd:string"/>
          <xsd:element name="subscriberId" type="xsd:string"/>
          <xsd:element name="amount" type="xsd:decimal"/>
          <xsd:element name="currency" type="xsd:string"/>
          <xsd:element name="reasonCode" type="xsd:string"/>
          <xsd:element name="requestedBy" type="xsd:string"/>
          <xsd:element name="correlationId" type="xsd:string"/>
        </xsd:sequence></xsd:complexType>
      </xsd:element>
      <xsd:element name="AdjustBillingResponse">
        <xsd:complexType><xsd:sequence>
          <xsd:element name="transactionId" type="xsd:string"/>
          <xsd:element name="adjustmentId" type="xsd:string"/>
          <xsd:element name="status" type="xsd:string"/>
          <xsd:element name="subscriberId" type="xsd:string"/>
          <xsd:element name="amount" type="xsd:decimal"/>
          <xsd:element name="currency" type="xsd:string"/>
          <xsd:element name="previousBalance" type="xsd:decimal"/>
          <xsd:element name="newBalance" type="xsd:decimal"/>
          <xsd:element name="backendNode" type="xsd:string"/>
          <xsd:element name="processedAt" type="xsd:dateTime"/>
          <xsd:element name="idempotentReplay" type="xsd:boolean"/>
          <xsd:element name="correlationId" type="xsd:string"/>
        </xsd:sequence></xsd:complexType>
      </xsd:element>
    </xsd:schema>
  </wsdl:types>
  <wsdl:message name="AdjustBillingInput"><wsdl:part name="parameters" element="tns:AdjustBillingRequest"/></wsdl:message>
  <wsdl:message name="AdjustBillingOutput"><wsdl:part name="parameters" element="tns:AdjustBillingResponse"/></wsdl:message>
  <wsdl:portType name="LegacyBillingAdjustmentPortType">
    <wsdl:operation name="AdjustBilling"><wsdl:input message="tns:AdjustBillingInput"/><wsdl:output message="tns:AdjustBillingOutput"/></wsdl:operation>
  </wsdl:portType>
  <wsdl:binding name="LegacyBillingAdjustmentSoapBinding" type="tns:LegacyBillingAdjustmentPortType">
    <soap:binding transport="http://schemas.xmlsoap.org/soap/http" style="document"/>
    <wsdl:operation name="AdjustBilling"><soap:operation soapAction="urn:AdjustBilling"/>
      <wsdl:input><soap:body use="literal"/></wsdl:input><wsdl:output><soap:body use="literal"/></wsdl:output>
    </wsdl:operation>
  </wsdl:binding>
  <wsdl:service name="LegacyBillingAdjustmentService">
    <wsdl:port name="LegacyBillingAdjustmentSoapPort" binding="tns:LegacyBillingAdjustmentSoapBinding">
      <soap:address location="${escapeXml(publicServiceUrl)}"/>
    </wsdl:port>
  </wsdl:service>
</wsdl:definitions>`;
}

function buildSuccess(input, replay) {
  const existing = transactions.get(input.transactionId);
  if (existing) {
    return { ...existing, idempotentReplay: true, correlationId: input.correlationId };
  }

  const previousBalance = 540.25;
  const newBalance = Number((previousBalance + input.amount).toFixed(2));
  const adjustmentId = `ADJ-${crypto.createHash('sha256').update(input.transactionId).digest('hex').slice(0, 12).toUpperCase()}`;
  const record = {
    transactionId: input.transactionId,
    adjustmentId,
    status: 'APPLIED',
    subscriberId: input.subscriberId,
    amount: input.amount,
    currency: input.currency,
    previousBalance,
    newBalance,
    backendNode,
    processedAt: new Date().toISOString(),
    idempotentReplay: Boolean(replay),
    correlationId: input.correlationId,
  };
  transactions.set(input.transactionId, record);
  return record;
}

async function handleSoap(req, res) {
  if (mode === 'unavailable') {
    send(res, 503, 'text/plain; charset=utf-8', `Legacy ${backendNode} node is unavailable`);
    return;
  }

  const xml = await readBody(req);
  const correlationId = tagValue(xml, 'correlationId') || String(req.headers['x-correlation-id'] || '');

  if (!hasSoapAction(req, 'urn:AdjustBilling')) {
    send(res, 500, 'text/xml; charset=utf-8', soapFault('BSS-ACTION-NOT-SUPPORTED', 'Unsupported SOAPAction', correlationId));
    return;
  }

  if (!validateWsSecurity(xml)) {
    send(res, 500, 'text/xml; charset=utf-8', soapFault('BSS-AUTH-FAILED', 'WS-Security UsernameToken validation failed', correlationId));
    return;
  }

  const input = {
    transactionId: tagValue(xml, 'transactionId'),
    subscriberId: tagValue(xml, 'subscriberId'),
    amount: Number(tagValue(xml, 'amount')),
    currency: tagValue(xml, 'currency').toUpperCase(),
    reasonCode: tagValue(xml, 'reasonCode').toUpperCase(),
    requestedBy: tagValue(xml, 'requestedBy'),
    correlationId,
  };

  if (!input.transactionId || !input.subscriberId || !Number.isFinite(input.amount)) {
    send(res, 500, 'text/xml; charset=utf-8', soapFault('BSS-INVALID-REQUEST', 'Required legacy request fields are missing', correlationId));
    return;
  }

  if (input.subscriberId.startsWith('NOT-FOUND')) {
    send(res, 500, 'text/xml; charset=utf-8', soapFault('BSS-ACCOUNT-NOT-FOUND', 'Billing account was not found', correlationId));
    return;
  }

  if (input.reasonCode === 'LIMIT_EXCEEDED' || input.amount > 5000) {
    send(res, 500, 'text/xml; charset=utf-8', soapFault('BSS-ADJUSTMENT-REJECTED', 'Adjustment exceeds the permitted legacy limit', correlationId));
    return;
  }

  const delay = mode === 'slow' ? Math.max(modeDelayMs, 6000) : modeDelayMs;
  if (delay > 0) {
    await new Promise((resolve) => setTimeout(resolve, delay));
  }

  const result = buildSuccess(input, false);
  const body = `    <leg:AdjustBillingResponse>
      <leg:transactionId>${escapeXml(result.transactionId)}</leg:transactionId>
      <leg:adjustmentId>${escapeXml(result.adjustmentId)}</leg:adjustmentId>
      <leg:status>${escapeXml(result.status)}</leg:status>
      <leg:subscriberId>${escapeXml(result.subscriberId)}</leg:subscriberId>
      <leg:amount>${result.amount.toFixed(2)}</leg:amount>
      <leg:currency>${escapeXml(result.currency)}</leg:currency>
      <leg:previousBalance>${result.previousBalance.toFixed(2)}</leg:previousBalance>
      <leg:newBalance>${result.newBalance.toFixed(2)}</leg:newBalance>
      <leg:backendNode>${escapeXml(result.backendNode)}</leg:backendNode>
      <leg:processedAt>${escapeXml(result.processedAt)}</leg:processedAt>
      <leg:idempotentReplay>${result.idempotentReplay}</leg:idempotentReplay>
      <leg:correlationId>${escapeXml(result.correlationId)}</leg:correlationId>
    </leg:AdjustBillingResponse>`;
  send(res, 200, 'text/xml; charset=utf-8', soapEnvelope(body, correlationId));
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

    if (req.method === 'GET' && url.pathname === '/health') {
      sendJson(res, 200, {
        status: 'UP',
        service: 'LegacyBillingAdjustmentService',
        backendNode,
        mode,
        wsSecurity: 'UsernameToken PasswordText',
      });
      return;
    }

    if (req.method === 'GET' && url.pathname === '/LegacyBillingAdjustmentService' && url.search.toLowerCase() === '?wsdl') {
      send(res, 200, 'text/xml; charset=utf-8', wsdl());
      return;
    }

    if (req.method === 'POST' && url.pathname === '/admin/mode') {
      if (String(req.headers['x-demo-admin-key'] || '') !== adminKey) {
        sendJson(res, 403, { error: 'Forbidden' });
        return;
      }
      const payload = JSON.parse((await readBody(req)) || '{}');
      const requestedMode = String(payload.mode || '').toLowerCase();
      if (!['normal', 'slow', 'unavailable'].includes(requestedMode)) {
        sendJson(res, 400, { error: 'mode must be normal, slow or unavailable' });
        return;
      }
      mode = requestedMode;
      modeDelayMs = Number(payload.delayMs || defaultDelayMs || 0);
      sendJson(res, 200, { backendNode, mode, delayMs: modeDelayMs });
      return;
    }

    if (req.method === 'POST' && url.pathname === '/LegacyBillingAdjustmentService') {
      await handleSoap(req, res);
      return;
    }

    sendJson(res, 404, { error: 'Not found', path: url.pathname });
  } catch (error) {
    console.error(`[legacy-billing:${backendNode}]`, error);
    if (!res.headersSent) {
      sendJson(res, 500, { error: 'Internal mock BSS error', message: error.message });
    } else {
      res.end();
    }
  }
});

server.listen(port, '0.0.0.0', () => {
  console.log(`[legacy-billing:${backendNode}] listening on ${port}`);
});
