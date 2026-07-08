const express=require('express');
const fs=require('fs');
const pino=require('pino');
const client=require('prom-client');
const axios=require('axios');
const log=pino({base:{service:'telco-apim-correlation-exporter'}});
const app=express(); client.collectDefaultMetrics({prefix:'telco_apim_correlation_exporter_'});
const backendLatency=new client.Histogram({name:'telco_apim_backend_duration_seconds',help:'Backend latency recorded by the WSO2 API Manager Synapse global handler',labelNames:['api','method','country','partner','application'],buckets:[0.005,0.01,0.025,0.05,0.1,0.25,0.5,1,2,5,10]});
const roundtrip=new client.Histogram({name:'telco_apim_roundtrip_duration_seconds',help:'Round-trip latency recorded by WSO2 API Manager',labelNames:['api','method','country','partner','application'],buckets:[0.005,0.01,0.025,0.05,0.1,0.25,0.5,1,2,5,10]});
const calls=new client.Counter({name:'telco_apim_requests_total',help:'API Manager calls parsed from native correlation.log',labelNames:['api','method','country','partner','application','status']});
const parseErrors=new client.Counter({name:'telco_apim_correlation_parse_errors_total',help:'Unparseable native correlation log entries'});
const logfile=process.env.CORRELATION_LOG||'/var/log/wso2/correlation.log'; const telemetry=process.env.TELEMETRY_URL||'http://telco-observability:8088/v1/events';

let offset=0,partial='';

function nullish(v,fallback){return !v||v==='null'?fallback:v;}
async function publish(e){try{await axios.post(telemetry,e,{timeout:1000});}catch{}}
function parse(line){
  const f=line.trim().replace(/^\d+\s+`?/,'').replace(/`$/,'').split('|');
  if(f.length<20||String(f[4]).trim()!=='HTTP'||!String(f[5]).includes('--'))return null;
  const [timestamp,correlationId,,duration,,api,method,context,resource,,country,partner,application,,requestSize,responseSize,status,applicationName,consumerKey,responseTime]=f.map(x=>String(x).trim());
  return {timestamp,correlationId,durationMs:Number(duration),api,method,context,resource,country:nullish(country,'UNKNOWN'),partner:nullish(partner,'anonymous'),application:nullish(application,nullish(applicationName,'unknown')),requestSize:Number(requestSize)||0,responseSize:Number(responseSize)||0,status:Number(status)||0,consumerKey:nullish(consumerKey,''),responseTimeMs:Number(responseTime)||0};
}

function processLine(line){
  const e=parse(line); if(!e)return;
  const labels={api:e.api,method:e.method,country:e.country,partner:e.partner,application:e.application};
  backendLatency.observe(labels,e.durationMs/1000); roundtrip.observe(labels,e.responseTimeMs/1000); calls.inc({...labels,status:String(e.status)});
  let eventTimestamp=new Date().toISOString();
  try {
    const parsed=new Date(e.timestamp.replace(' ','T').replace(',','.')+'Z');
    if(!Number.isNaN(parsed.getTime()))eventTimestamp=parsed.toISOString();
  } catch (_) {}
  const event={...e,timestamp:eventTimestamp,stage:'apim',component:'wso2-api-manager',eventType:'apim.correlation.completed',outcome:e.status>=400?'ERROR':'SUCCESS'};
  log.info(event,'apim.correlation.completed'); publish(event);
}

function poll(){
  fs.stat(logfile,(err,st)=>{
    if(err)return;
    if(st.size<offset)offset=0;
    if(st.size===offset)return;
    const stream=fs.createReadStream(logfile,{start:offset,end:st.size-1,encoding:'utf8'}); let data='';
    stream.on('data',c=>data+=c); stream.on('end',()=>{offset=st.size;const lines=(partial+data).split(/\r?\n/);partial=lines.pop()||'';for(const l of lines)try{processLine(l)}catch(e){parseErrors.inc();log.warn({line:l,error:e.message},'correlation.parse.failed');}});
  });
}

setInterval(poll,1000); poll();
app.get('/health',(_req,res)=>res.json({status:'UP',service:'telco-apim-correlation-exporter',logfile,offset}));
app.get('/metrics',async(_req,res)=>res.type(client.register.contentType).send(await client.register.metrics()));
app.listen(9470,()=>log.info({port:9470,logfile},'APIM correlation exporter ready'));
