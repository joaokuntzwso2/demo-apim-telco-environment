const express = require('express');
const axios = require('axios');
const crypto = require('crypto');
const CircuitBreaker = require('opossum');
const pino = require('pino');
const client = require('prom-client');
const { ensureTraceContext, emitSpan } = require('./otel');

const log = pino({ base:{ service:'telco-backend-observer' } });
const app = express();
app.use(express.raw({ type:()=>true, limit:'10mb' }));
client.collectDefaultMetrics({ prefix:'telco_backend_observer_' });
const calls = new client.Counter({ name:'telco_backend_requests_total', help:'BSS/OSS backend calls', labelNames:['backend','method','status','outcome'] });
const latency = new client.Histogram({ name:'telco_backend_request_duration_seconds', help:'BSS/OSS backend latency', labelNames:['backend','method'], buckets:[0.005,0.01,0.025,0.05,0.1,0.25,0.5,1,2,5,10] });
const circuit = new client.Gauge({ name:'telco_backend_circuit_state', help:'Circuit state: closed=0, half-open=1, open=2', labelNames:['backend'] });
const retries = new client.Counter({ name:'telco_backend_retry_total', help:'Observer transport retry attempts', labelNames:['backend'] });

const targets = {
  crm: process.env.CRM_TARGET || 'http://subscriber-crm:8080',
  'sim-swap': process.env.SIM_SWAP_TARGET || 'http://sim-swap-service:8080',
  'device-location': process.env.DEVICE_LOCATION_TARGET || 'http://device-location-service:8080',
  oss: process.env.OSS_TARGET || 'http://oss-network-service:8080',
  billing: process.env.BILLING_TARGET || 'http://legacy-billing-soap:8080'
};
const telemetry = process.env.TELEMETRY_URL || 'http://telco-observability:8088/v1/events';
const faultModes = Object.create(null);
function cleanHeaders(headers) { const out={...headers}; for (const h of ['host','content-length','connection','transfer-encoding']) delete out[h]; return out; }
async function postEvent(payload) { try { await axios.post(telemetry,payload,{timeout:1000}); } catch (_) {} }
async function invoke({ backend, method, url, headers, data }) {
  let last;
  for (let attempt=0; attempt<2; attempt++) {
    try {
      if (faultModes[backend] === 'error') {
        const injected = new Error(`Injected ${backend} transport failure`);
        injected.code = 'INJECTED_FAILURE';
        injected.retryable = true;
        throw injected;
      }
      const response = await axios({method,url,headers,data,responseType:'arraybuffer',validateStatus:()=>true,timeout:Number(process.env.BACKEND_TIMEOUT_MS||3500)});
      if (response.status >= 500) {
        const error = new Error(`Backend ${backend} returned HTTP ${response.status}`);
        error.status = response.status;
        error.retryable = true;
        throw error;
      }
      return response;
    } catch (e) {
      last=e;
      const retryableCodes=new Set(['ECONNRESET','ECONNREFUSED','EAI_AGAIN','ENOTFOUND','EPIPE','UND_ERR_SOCKET','INJECTED_FAILURE']);
      const retryable=e.retryable===true||retryableCodes.has(e.code);
      if (attempt===0 && retryable) {
        retries.inc({backend});
        await new Promise(r=>setTimeout(r,150));
        continue;
      }
      break;
    }
  }
  throw last;
}
const breakers={};
for (const backend of Object.keys(targets)) {
  const b = new CircuitBreaker((opts)=>invoke(opts), { timeout:Number(process.env.CIRCUIT_TIMEOUT_MS||4500), errorThresholdPercentage:50, resetTimeout:10000, volumeThreshold:3 });
  circuit.set({backend},0);
  b.on('open',()=>{ circuit.set({backend},2); log.warn({backend},'circuit.open'); });
  b.on('halfOpen',()=>{ circuit.set({backend},1); log.warn({backend},'circuit.half_open'); });
  b.on('close',()=>{ circuit.set({backend},0); log.info({backend},'circuit.closed'); });
  breakers[backend]=b;
}
app.get('/',(_req,res)=>res.json({status:'UP',service:'telco-backend-observer',message:'Backend observability and circuit-breaker API',links:{health:'/health',metrics:'/metrics'}}));
app.get('/health',(_req,res)=>res.json({status:'UP',service:'telco-backend-observer',targets,faultModes}));
app.post('/__admin/faults/:backend',(req,res)=>{
  const backend=req.params.backend;
  if(!targets[backend])return res.status(404).json({code:'UNKNOWN_BACKEND',backend});
  const mode=String(req.query.mode||'error');
  if(!['error'].includes(mode))return res.status(400).json({code:'UNSUPPORTED_FAULT_MODE',supported:['error']});
  faultModes[backend]=mode;
  log.warn({backend,mode},'demo.fault.enabled');
  res.json({status:'ENABLED',backend,mode});
});
app.delete('/__admin/faults/:backend',(req,res)=>{
  const backend=req.params.backend;
  delete faultModes[backend];
  log.info({backend},'demo.fault.disabled');
  res.json({status:'DISABLED',backend});
});
app.get('/metrics',async(_req,res)=>res.type(client.register.contentType).send(await client.register.metrics()));
app.all('/backend/:backend/*', async(req,res)=>{
  const backend=req.params.backend;
  if(!targets[backend]) return res.status(404).json({code:'UNKNOWN_BACKEND',backend});
  const rest=req.params[0] ? '/' + req.params[0] : '';
  const query=req.url.includes('?')?'?'+req.url.split('?').slice(1).join('?'):'';
  const target=targets[backend]+rest+query;
  const correlationId=String(req.headers['x-correlation-id']||req.headers.activityid||crypto.randomUUID());
  const trace=ensureTraceContext(req.headers);
  const headers=cleanHeaders(req.headers);
  headers['x-correlation-id']=correlationId; headers.activityid=correlationId; headers.traceparent=trace.traceparent;
  const startedMono=process.hrtime.bigint();
  const startedWallNs=BigInt(Date.now())*1000000n;
  const miDispatch={timestamp:new Date().toISOString(),correlationId,traceId:trace.traceId,traceparent:trace.traceparent,stage:'mi',component:'wso2-integrator-mi',eventType:'mi.backend.dispatch',backend,method:req.method,path:rest,outcome:'IN_PROGRESS'};
  if(String(req.headers['x-observer-component-test']||'').toLowerCase()!=='true')postEvent(miDispatch);
  let status=503,outcome='ERROR';
  try {
    const response=await breakers[backend].fire({backend,method:req.method,url:target,headers,data:req.body?.length?req.body:undefined});
    status=response.status; outcome=status>=400?'ERROR':'SUCCESS';
    for(const[k,v]of Object.entries(response.headers))if(!['transfer-encoding','connection','content-length'].includes(k.toLowerCase()))res.setHeader(k,v);
    res.setHeader('X-Correlation-ID',correlationId); res.status(status).send(Buffer.from(response.data));
  } catch(error) {
    const open=breakers[backend].opened;
    log.error({correlationId,backend,target,error:error.message,circuitOpen:open},'backend.call.failed');
    res.status(open?503:504).json({code:open?'BACKEND_CIRCUIT_OPEN':'BACKEND_TIMEOUT_OR_TRANSPORT_ERROR',backend,correlationId,message:error.message});
    status=open?503:504;
  } finally {
    const elapsedNs=process.hrtime.bigint()-startedMono; const endedWallNs=startedWallNs+elapsedNs; const seconds=Number(elapsedNs)/1e9;
    calls.inc({backend,method:req.method,status:String(status),outcome}); latency.observe({backend,method:req.method},seconds);
    const payload={timestamp:new Date().toISOString(),correlationId,traceId:trace.traceId,traceparent:trace.traceparent,stage:'backend',component:backend,eventType:'backend.call.completed',backend,method:req.method,path:rest,status,durationMs:Math.round(seconds*1000),outcome,circuitOpen:breakers[backend].opened};
    log.info(payload,'backend.call.completed'); postEvent(payload);
    emitSpan({serviceName:`telco-${backend}-observer`,name:`${req.method} ${backend}${rest}`,traceId:trace.traceId,spanId:trace.spanId,parentSpanId:trace.parentSpanId,startNs:startedWallNs,endNs:endedWallNs,attributes:{'telco.correlation_id':correlationId,'telco.backend':backend,'http.response.status_code':status,'circuit.open':breakers[backend].opened},statusCode:status>=400?2:1,kind:3});
  }
});
app.listen(8090,()=>log.info({port:8090,targets},'Backend observer ready'));
