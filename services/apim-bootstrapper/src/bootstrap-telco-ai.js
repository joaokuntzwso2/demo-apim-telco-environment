'use strict';
const fs=require('fs');
const {Agent}=require('undici');
const {execFileSync}=require('child_process');
const APIM=process.env.WSO2_APIM_URL||'https://wso2-apim:9443';
const TOKEN_URL=process.env.WSO2_APIM_TOKEN_URL||`${APIM}/oauth2/token`;
const USER=process.env.APIM_USERNAME||'admin', PASS=process.env.APIM_PASSWORD||'admin';
const ENV=process.env.APIM_ENV||'am47';
const STATE=process.env.APIM_PORTAL_STATE_FILE||'/workspace/state/runtime.json';
const APP=process.env.PORTAL_APP_NAME||'Regional Portal';
const dispatcher=new Agent({connect:{rejectUnauthorized:false}});
const log=m=>console.log(`[telco-ai-bootstrap] ${m}`);
async function req(method,url,token,body,ok=[200,201,202,204]){
  const r=await fetch(url,{method,dispatcher,headers:{...(token?{authorization:`Bearer ${token}`}:{...{}}),...(body!==undefined?{'content-type':'application/json'}:{})},body:body===undefined?undefined:JSON.stringify(body)});
  const text=await r.text(); let data=text; try{data=text?JSON.parse(text):null}catch{}
  if(!ok.includes(r.status)) throw new Error(`${method} ${url}: ${r.status} ${typeof data==='string'?data:JSON.stringify(data)}`);
  return data;
}
async function token(){
  const d=await req('POST',`${APIM}/client-registration/v0.17/register`,null,{callbackUrl:'www.google.lk',clientName:`telco-ai-${Date.now()}`,owner:USER,grantType:'password refresh_token',saasApp:true});
  const r=await fetch(TOKEN_URL,{method:'POST',dispatcher,headers:{authorization:`Basic ${Buffer.from(`${d.clientId}:${d.clientSecret}`).toString('base64')}`,'content-type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grant_type:'password',username:USER,password:PASS,scope:'apim:api_view apim:api_create apim:api_publish apim:subscription_view apim:subscription_manage apim:app_manage apim:admin apim:admin_tier_view apim:admin_tier_manage'})});
  const j=await r.json(); if(!r.ok||!j.access_token) throw new Error(`Management token failed: ${r.status} ${JSON.stringify(j)}`); return j.access_token;
}
async function ensureAiPolicy(t){
  const name=process.env.AI_APIM_TOKEN_POLICY||'TelcoAITokenQuota';
  const paths=['/api/am/admin/v4/throttling/policies/ai-subscription','/api/am/admin/v4/throttling/policies/aiSubscription'];
  let path=null,list=null;
  for(const p of paths){try{list=await req('GET',`${APIM}${p}?limit=100`,t);path=p;break}catch(e){log(`Policy resource not at ${p}`)}}
  if(!path) throw new Error('APIM 4.7 AI subscription-policy REST resource was not found; refusing to silently downgrade token governance.');
  if((list.list||list.data||[]).some(x=>(x.policyName||x.name)===name)){log(`AI token policy exists: ${name}`);return;}
  const payload={policyName:name,displayName:'Telco AI Token Quota',description:'100 requests/min; 100k total, 70k prompt and 30k completion tokens/day.',isDeployed:true,type:'AISubscriptionThrottlePolicy',defaultLimit:{type:'AIAPILIMIT',aiApiQuota:{requestCount:100,requestTimeUnit:'min',requestUnitTime:1,totalTokenCount:100000,totalTokenTimeUnit:'day',totalTokenUnitTime:1,promptTokenCount:70000,promptTokenTimeUnit:'day',promptTokenUnitTime:1,completionTokenCount:30000,completionTokenTimeUnit:'day',completionTokenUnitTime:1}},stopOnQuotaReach:true,billingPlan:'COMMERCIAL'};
  try{await req('POST',`${APIM}${path}`,t,payload)}
  catch(e){await req('POST',`${APIM}${path}`,t,{policyName:name,displayName:'Telco AI Token Quota',description:payload.description,requestCount:100,requestCountTimeUnit:'min',totalTokenCount:100000,totalTokenCountTimeUnit:'day',promptTokenCount:70000,promptTokenCountTimeUnit:'day',completionTokenCount:30000,completionTokenCountTimeUnit:'day',stopOnQuotaReach:true,billingPlan:'COMMERCIAL'});}
  log(`Created native AI token policy: ${name}`);
}
function apictl(){
  const root='/workspace/artifacts/apictl/mcp/TelcoOperationsMCP-1.0.0';
  execFileSync('apictl',['add','env',ENV,'--apim',APIM,'--token',TOKEN_URL,'-k'],{stdio:'inherit'});
  execFileSync('apictl',['login',ENV,'-u',USER,'-p',PASS,'-k'],{stdio:'inherit'});
  execFileSync('apictl',['import','mcp-server','-f',root,'-e',ENV,'--update-mcp-server=true','--rotate-revision','-k'],{stdio:'inherit',timeout:300000});
}
async function subscribeMcp(t){
  const apps=await req('GET',`${APIM}/api/am/devportal/v3/applications?query=${encodeURIComponent(APP)}&limit=100`,t);
  const app=(apps.list||[]).find(x=>x.name===APP); if(!app) throw new Error(`Application not found: ${APP}`);
  let mcp;
  for(let i=0;i<30&&!mcp;i++){try{const d=await req('GET',`${APIM}/api/am/devportal/v3/mcp-servers?limit=100`,t);mcp=(d.list||d.data||[]).find(x=>x.name==='TelcoOperationsMCP'&&x.version==='1.0.0')}catch{};if(!mcp)await new Promise(r=>setTimeout(r,2000));}
  if(!mcp) throw new Error('TelcoOperationsMCP is not visible in the Developer Portal.');
  const appId=app.applicationId||app.id,mcpId=mcp.id||mcp.mcpServerId;
  const subs=await req('GET',`${APIM}/api/am/devportal/v3/subscriptions?applicationId=${appId}&limit=100`,t);
  if(!(subs.list||subs.data||[]).some(x=>(x.apiId||x.mcpServerId)===mcpId)){
    await req('POST',`${APIM}/api/am/devportal/v3/subscriptions`,t,{applicationId:appId,apiId:mcpId,throttlingPolicy:'Unlimited'},[200,201,202,409]);
  }
  return {appId,mcpId};
}
(async()=>{
  const t=await token(); await ensureAiPolicy(t); apictl(); const ids=await subscribeMcp(t);
  let s={};try{s=JSON.parse(fs.readFileSync(STATE,'utf8'))}catch{}
  s.ai={enabled:true,supportApi:'TelcoSupportAssistantAPI',toolsApi:'TelcoAgentToolsAPI',apiProduct:'Telco AI Service Care Pack',mcpServer:'TelcoOperationsMCP',tokenPolicy:process.env.AI_APIM_TOKEN_POLICY||'TelcoAITokenQuota',scopes:['telco_ai_support','telco_subscriber_status','telco_outage_read','telco_qod_request','telco_ticket_create'],...ids};
  fs.mkdirSync(require('path').dirname(STATE),{recursive:true});fs.writeFileSync(STATE,JSON.stringify(s,null,2));
  log('AI policy, MCP publication and existing-application subscription complete.');
})().catch(e=>{console.error(`[telco-ai-bootstrap][FAIL] ${e.stack||e}`);process.exit(1)});
