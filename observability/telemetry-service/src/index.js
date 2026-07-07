const express=require('express');
const fs=require('fs');
const path=require('path');
const crypto=require('crypto');
const pino=require('pino');
const client=require('prom-client');
const {Kafka,logLevel}=require('kafkajs');
const {emitSpan,parseTraceparent}=require('./otel');

const log=pino({base:{service:'telco-observability'}});
const app=express(); app.use(express.json({limit:'5mb'}));
const dataDir=process.env.DATA_DIR||'/data'; fs.mkdirSync(dataDir,{recursive:true});
const eventFile=path.join(dataDir,'events.jsonl');
const failedFile=path.join(dataDir,'failed-billing.jsonl');
const events=new Map(); const traces=new Map(); const failedBilling=[];
client.collectDefaultMetrics({prefix:'telco_observability_'});
const received=new client.Counter({name:'telco_observability_events_total',help:'Structured events by stage and outcome',labelNames:['stage','component','event_type','outcome']});
const billing=new client.Counter({name:'telco_billing_records_total',help:'Billing processing results',labelNames:['status','country','partner']});
const analytics=new client.Counter({name:'telco_analytics_events_total',help:'Analytics events consumed',labelNames:['country','partner','outcome']});
const timelineSize=new client.Gauge({name:'telco_active_correlation_timelines',help:'Correlation timelines kept in memory'});

function append(file,obj){fs.appendFileSync(file,JSON.stringify(obj)+'\n');}
function normalize(raw){
  const correlationId=String(raw.correlationId||raw.activityID||raw.activityId||crypto.randomUUID());
  const event={timestamp:raw.timestamp||new Date().toISOString(),correlationId,stage:raw.stage||'custom',component:raw.component||'unknown',eventType:raw.eventType||'event',outcome:raw.outcome||((Number(raw.status)>=400)?'ERROR':'SUCCESS'),...raw,correlationId};
  return event;
}
function record(raw){
  const event=normalize(raw); const arr=events.get(event.correlationId)||[]; arr.push(event); arr.sort((a,b)=>String(a.timestamp).localeCompare(String(b.timestamp))); events.set(event.correlationId,arr);
  if(event.traceId) traces.set(event.correlationId,event.traceId);
  received.inc({stage:event.stage,component:event.component,event_type:event.eventType,outcome:event.outcome}); timelineSize.set(events.size); append(eventFile,event); log.info(event,'observability.event'); return event;
}
if(fs.existsSync(eventFile)) for(const line of fs.readFileSync(eventFile,'utf8').split('\n')){if(line.trim())try{const e=JSON.parse(line);const a=events.get(e.correlationId)||[];a.push(e);events.set(e.correlationId,a);if(e.traceId)traces.set(e.correlationId,e.traceId);}catch{}}
if(fs.existsSync(failedFile)) for(const line of fs.readFileSync(failedFile,'utf8').split('\n')){if(line.trim())try{failedBilling.push(JSON.parse(line));}catch{}}

const brokers=(process.env.KAFKA_BROKERS||'redpanda:9092').split(',');
const kafka=new Kafka({clientId:'telco-observability',brokers,logLevel:logLevel.NOTHING});
const producer=kafka.producer({allowAutoTopicCreation:true});
const consumer=kafka.consumer({groupId:'telco-observability-processors'});
let kafkaReady=false;
async function send(topic,event){
  if(!kafkaReady)return null;
  const startedMono=process.hrtime.bigint();
  const startedWallNs=BigInt(Date.now())*1000000n;
  const upstream=parseTraceparent(event.traceparent);
  const traceId=event.traceId||upstream?.traceId||traces.get(event.correlationId)||crypto.randomBytes(16).toString('hex');
  const spanId=crypto.randomBytes(8).toString('hex');
  const traceparent=`00-${traceId}-${spanId}-01`;
  const outbound={...event,traceId,traceparent};
  await producer.send({topic,messages:[{key:event.correlationId,value:JSON.stringify(outbound),headers:{correlationId:Buffer.from(event.correlationId),traceparent:Buffer.from(traceparent)}}]});
  const elapsedNs=process.hrtime.bigint()-startedMono;
  emitSpan({serviceName:'telco-observability',name:`kafka publish ${topic}`,traceId,spanId,parentSpanId:upstream?.parentSpanId,startNs:startedWallNs,endNs:startedWallNs+elapsedNs,attributes:{'telco.correlation_id':event.correlationId,'messaging.system':'kafka','messaging.destination.name':topic,'messaging.operation.type':'publish'},statusCode:1,kind:4});
  return outbound;
}
function billingFailure(e){return e.forceBillingFailure===true||e.partner==='partner-billing-fail'||Number(e.status)>=500;}
async function startKafka(){
  while(!kafkaReady){try{await producer.connect();await consumer.connect();kafkaReady=true;}catch(e){log.warn({error:e.message},'Kafka not ready; retrying');await new Promise(r=>setTimeout(r,3000));}}
  await consumer.subscribe({topics:['telco.analytics.events','telco.billing.records'],fromBeginning:false});
  await consumer.run({eachMessage:async({topic,message})=>{
    const base=JSON.parse(message.value.toString()); const startedMono=process.hrtime.bigint(); const startedWallNs=BigInt(Date.now())*1000000n;
    if(topic==='telco.analytics.events'){
      const e=record({...base,timestamp:new Date().toISOString(),stage:'analytics',component:'telco-analytics-event-processor',eventType:'analytics.event.consumed'});
      analytics.inc({country:e.country||'UNKNOWN',partner:e.partner||'anonymous',outcome:e.outcome||'SUCCESS'});
    } else {
      const failed=billingFailure(base); const status=failed?'FAILED':'POSTED';
      const rec=record({...base,timestamp:new Date().toISOString(),stage:'billing',component:'partner-billing-processor',eventType:'billing.record.processed',billingStatus:status,outcome:failed?'ERROR':'SUCCESS'});
      billing.inc({status,country:rec.country||'UNKNOWN',partner:rec.partner||'anonymous'});
      if(failed){failedBilling.unshift(rec);append(failedFile,rec);}
    }
    const elapsedNs=process.hrtime.bigint()-startedMono; const endedWallNs=startedWallNs+elapsedNs;
    const upstream=parseTraceparent(base.traceparent);
    const traceId=base.traceId||upstream?.traceId||traces.get(base.correlationId)||crypto.randomBytes(16).toString('hex');
    emitSpan({serviceName:topic==='telco.analytics.events'?'telco-analytics-processor':'telco-billing-processor',name:`kafka consume ${topic}`,traceId,parentSpanId:upstream?.parentSpanId,startNs:startedWallNs,endNs:endedWallNs,attributes:{'telco.correlation_id':base.correlationId,'messaging.system':'kafka','messaging.destination.name':topic,'messaging.operation.type':'process'},statusCode:1,kind:5});
  }});
}
startKafka().catch(e=>log.error({error:e.message},'Kafka worker stopped'));

app.get('/health',(_req,res)=>res.json({status:kafkaReady?'UP':'DEGRADED',service:'telco-observability',kafkaReady,brokers,timelines:events.size,failedBilling:failedBilling.length}));
app.get('/metrics',async(_req,res)=>res.type(client.register.contentType).send(await client.register.metrics()));
app.post('/v1/events',async(req,res)=>{
  const e=record(req.body||{});
  if(e.stage==='gateway'&&e.eventType==='request.completed'){
    await Promise.allSettled([
      send('telco.analytics.events',{...e,eventType:'analytics.event'}),
      send('telco.billing.records',{...e,eventType:'billing.record'})
    ]);
    record({...e,timestamp:new Date().toISOString(),stage:'kafka',component:'redpanda',eventType:'kafka.events.published',topics:['telco.analytics.events','telco.billing.records']});
  }
  res.status(202).json({status:'ACCEPTED',correlationId:e.correlationId,traceId:e.traceId||traces.get(e.correlationId)});
});
app.get('/v1/transactions/:correlationId',(req,res)=>{
  const correlationId=req.params.correlationId; const list=events.get(correlationId);
  if(!list)return res.status(404).json({code:'CORRELATION_NOT_FOUND',correlationId});
  const failed=list.some(e=>e.outcome==='ERROR'||Number(e.status)>=400||e.billingStatus==='FAILED');
  res.json({correlationId,traceId:traces.get(correlationId),status:failed?'FAILED_OR_DEGRADED':'SUCCESS',eventCount:list.length,events:list});
});
app.get('/v1/billing/failed',(_req,res)=>res.json(failedBilling.slice(0,250)));
app.post('/v1/reset',(_req,res)=>{events.clear();traces.clear();failedBilling.length=0;for(const f of[eventFile,failedFile])try{fs.unlinkSync(f)}catch{};res.json({status:'RESET'});});
app.listen(8088,()=>log.info({port:8088,brokers},'Telco observability service ready'));
