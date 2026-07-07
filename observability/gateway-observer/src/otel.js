const crypto = require('crypto');
const axios = require('axios');

function hex(bytes) { return crypto.randomBytes(bytes).toString('hex'); }
function parseTraceparent(value) {
  const match = /^00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$/i.exec(String(value || '').trim());
  return match ? { traceId: match[1].toLowerCase(), parentSpanId: match[2].toLowerCase(), flags: match[3] } : null;
}
function ensureTraceContext(headers = {}) {
  const existing = parseTraceparent(headers.traceparent || headers.Traceparent);
  const traceId = existing?.traceId || hex(16);
  const parentSpanId = existing?.parentSpanId;
  const spanId = hex(8);
  return { traceId, parentSpanId, spanId, traceparent: `00-${traceId}-${spanId}-01` };
}
function attr(key, value) {
  if (Number.isInteger(value)) return { key, value: { intValue: String(value) } };
  if (typeof value === 'number') return { key, value: { doubleValue: value } };
  if (typeof value === 'boolean') return { key, value: { boolValue: value } };
  return { key, value: { stringValue: String(value ?? '') } };
}
async function emitSpan({ serviceName, name, traceId, spanId, parentSpanId, startNs, endNs, attributes = {}, statusCode = 1, kind = 2 }) {
  const effectiveSpanId = spanId || hex(8);
  const span = {
    traceId,
    spanId: effectiveSpanId,
    name,
    kind,
    startTimeUnixNano: String(startNs),
    endTimeUnixNano: String(endNs),
    attributes: Object.entries(attributes).map(([k, v]) => attr(k, v)),
    status: { code: statusCode }
  };
  if (parentSpanId) span.parentSpanId = parentSpanId;
  const payload = {
    resourceSpans: [{
      resource: { attributes: [attr('service.name', serviceName), attr('deployment.environment.name', 'telco-demo')] },
      scopeSpans: [{ scope: { name: 'telco-demo-manual-otlp', version: '1.0.0' }, spans: [span] }]
    }]
  };
  try {
    await axios.post(
      process.env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT || 'http://otel-collector:4318/v1/traces',
      payload,
      { timeout: 1500, headers: { 'Content-Type': 'application/json' } }
    );
  } catch (_) { /* observability must never break the business transaction */ }
  return effectiveSpanId;
}
module.exports = { ensureTraceContext, emitSpan, parseTraceparent };
