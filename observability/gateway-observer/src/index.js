const express = require('express');
const axios = require('axios');
const https = require('https');
const crypto = require('crypto');
const pino = require('pino');
const client = require('prom-client');
const { ensureTraceContext, emitSpan } = require('./otel');

const log = pino({ base: { service: 'telco-gateway-observer' } });
const app = express();
const localHttpsAgent = new https.Agent({ rejectUnauthorized: false });
app.use(express.raw({ type: () => true, limit: '10mb' }));
client.collectDefaultMetrics({ prefix: 'telco_gateway_observer_' });
const requests = new client.Counter({ name: 'telco_gateway_requests_total', help: 'Requests entering the WSO2 API Manager gateway', labelNames: ['country','partner','application','method','status'] });
const latency = new client.Histogram({ name: 'telco_gateway_request_duration_seconds', help: 'Client to WSO2 API Manager round trip', labelNames: ['country','partner','application','method'], buckets: [0.01,0.025,0.05,0.1,0.25,0.5,1,2,5,10] });
const inflight = new client.Gauge({ name: 'telco_gateway_inflight_requests', help: 'Requests currently being proxied to WSO2 API Manager' });

const target = process.env.GATEWAY_TARGET || 'https://wso2-apim:8243';
const telemetry = process.env.TELEMETRY_URL || 'http://telco-observability:8088/v1/events';
function cleanHeaders(headers) {
  const out = { ...headers };
  for (const h of ['host','content-length','connection','transfer-encoding']) delete out[h];
  return out;
}
function val(req, names, fallback) {
  for (const n of names) if (req.headers[n]) return String(req.headers[n]);
  return fallback;
}
async function event(payload) { try { await axios.post(telemetry, payload, { timeout: 1000 }); } catch (_) {} }

app.get('/health', (_req,res) => res.json({ status:'UP', service:'telco-gateway-observer', target }));
app.get('/metrics', async (_req,res) => { res.type(client.register.contentType).send(await client.register.metrics()); });
app.all('*', async (req,res) => {
  const startedMono = process.hrtime.bigint();
  const startedWallNs = BigInt(Date.now()) * 1000000n;
  const correlationId = val(req, ['activityid','x-correlation-id','x-request-id'], crypto.randomUUID());
  const country = val(req, ['organization-id','x-country-code'], 'UNKNOWN');
  const partner = val(req, ['source-id','x-partner-id'], 'anonymous');
  const application = val(req, ['application-id','x-application-id'], 'unknown');
  const trace = ensureTraceContext(req.headers);
  const headers = cleanHeaders(req.headers); headers.host = process.env.GATEWAY_VHOST || 'localhost';
  headers.activityid = correlationId;
  headers['x-correlation-id'] = correlationId;
  headers.traceparent = trace.traceparent;
  headers['organization-id'] = country;
  headers['source-id'] = partner;
  headers['application-id'] = application;
  inflight.inc();
  let status = 502;
  try {
    const response = await axios({ method:req.method, url:target + req.originalUrl, headers, data:req.body?.length ? req.body : undefined, responseType:'arraybuffer', validateStatus:()=>true, timeout:Number(process.env.GATEWAY_TIMEOUT_MS || 30000), httpsAgent:target.startsWith('https://')?localHttpsAgent:undefined });
    status = response.status;
    for (const [k,v] of Object.entries(response.headers)) if (!['transfer-encoding','connection','content-length'].includes(k.toLowerCase())) res.setHeader(k,v);
    res.setHeader('activityID', correlationId);
    res.setHeader('X-Correlation-ID', correlationId);
    res.status(status).send(Buffer.from(response.data));
  } catch (error) {
    log.error({ correlationId, error:error.message }, 'Gateway observer failed to reach WSO2 API Manager');
    res.setHeader('activityID', correlationId); res.setHeader('X-Correlation-ID', correlationId);
    res.status(502).json({ code:'GATEWAY_OBSERVER_UPSTREAM_ERROR', correlationId, message:error.message });
  } finally {
    inflight.dec();
    const elapsedNs = process.hrtime.bigint() - startedMono;
    const endedWallNs = startedWallNs + elapsedNs;
    const seconds = Number(elapsedNs) / 1e9;
    requests.inc({country,partner,application,method:req.method,status:String(status)});
    latency.observe({country,partner,application,method:req.method},seconds);
    const payload = { timestamp:new Date().toISOString(), correlationId, traceId:trace.traceId, traceparent:trace.traceparent, stage:'gateway', component:'wso2-api-manager-frontdoor', eventType:'request.completed', country, partner, application, method:req.method, path:req.originalUrl, status, durationMs:Math.round(seconds*1000), outcome:status>=400?'ERROR':'SUCCESS' };
    log.info(payload,'gateway.request.completed');
    event(payload);
    emitSpan({ serviceName:'wso2-apim-gateway-frontdoor', name:`${req.method} ${req.path}`, traceId:trace.traceId, spanId:trace.spanId, parentSpanId:trace.parentSpanId, startNs:startedWallNs, endNs:endedWallNs, attributes:{'telco.correlation_id':correlationId,'telco.country':country,'telco.partner':partner,'http.request.method':req.method,'url.path':req.originalUrl,'http.response.status_code':status}, statusCode:status>=400?2:1 });
  }
});
app.listen(8089, () => log.info({ port:8089, target }, 'Gateway observer ready'));
