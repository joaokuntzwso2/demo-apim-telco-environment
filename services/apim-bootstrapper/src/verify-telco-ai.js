'use strict';
const {Agent}=require('undici');
const APIM=process.env.WSO2_APIM_URL||'https://wso2-apim:9443', TOKEN=process.env.WSO2_APIM_TOKEN_URL||`${APIM}/oauth2/token`;
const USER=process.env.APIM_USERNAME||'admin',PASS=process.env.APIM_PASSWORD||'admin';
const dispatcher=new Agent({connect:{rejectUnauthorized:false}});
const pass=m=>console.log(`[telco-ai-apim-verify][PASS] ${m}`);
async function req(method,url,t,body,ok=[200,201,202,204]){
 const r=await fetch(url,{method,dispatcher,headers:{...(t?{authorization:`Bearer ${t}`}:{...{}}),...(body!==undefined?{'content-type':'application/json'}:{})},body:body===undefined?undefined:JSON.stringify(body)});
 const text=await r.text();let d=text;try{d=text?JSON.parse(text):null}catch{};if(!ok.includes(r.status))throw new Error(`${method} ${url}: ${r.status} ${text}`);return d;
}
async function token(){
 const d=await req('POST',`${APIM}/client-registration/v0.17/register`,null,{callbackUrl:'www.google.lk',clientName:`telco-ai-verify-${Date.now()}`,owner:USER,grantType:'password refresh_token',saasApp:true});
 const r=await fetch(TOKEN,{method:'POST',dispatcher,headers:{authorization:`Basic ${Buffer.from(`${d.clientId}:${d.clientSecret}`).toString('base64')}`,'content-type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grant_type:'password',username:USER,password:PASS,scope:'apim:api_view apim:subscription_view apim:app_manage apim:admin apim:admin_tier_view'})});
 const j=await r.json();if(!r.ok||!j.access_token)throw new Error(`token ${r.status} ${JSON.stringify(j)}`);return j.access_token;
}
function list(d){return d?.list||d?.data||[]}
(async()=>{
 const t=await token();
 const apis=await req('GET',`${APIM}/api/am/publisher/v4/apis?limit=200`,t);
 for(const name of ['TelcoSupportAssistantAPI','TelcoAgentToolsAPI']){
   const a=list(apis).find(x=>x.name===name&&x.version==='1.0.0');if(!a)throw new Error(`API absent: ${name}`);pass(`API published: ${name}`);
   const id=a.id||a.apiId;
   const docs=await req('GET',`${APIM}/api/am/publisher/v4/apis/${id}/documents?limit=100`,t);
   if(!list(docs).length)throw new Error(`Documentation absent: ${name}`);pass(`Documentation present: ${name}`);
   const deps=await req('GET',`${APIM}/api/am/publisher/v4/apis/${id}/deployments`,t);
   if(!list(deps).length && !Array.isArray(deps))throw new Error(`Deployment absent: ${name}`);pass(`Deployment present: ${name}`);
 }
 const products=await req('GET',`${APIM}/api/am/publisher/v4/api-products?limit=100`,t);
 if(!list(products).some(x=>x.name==='Telco AI Service Care Pack'))throw new Error('API Product absent');pass('API Product published');
 const apps=await req('GET',`${APIM}/api/am/devportal/v3/applications?query=Regional%20Portal&limit=100`,t);
 const app=list(apps).find(x=>x.name==='Regional Portal');if(!app)throw new Error('Regional Portal app absent');
 const subs=await req('GET',`${APIM}/api/am/devportal/v3/subscriptions?applicationId=${app.applicationId||app.id}&limit=200`,t);
 if(list(subs).length<3)throw new Error('Expected AI API/Product/MCP subscriptions are absent');pass('Existing portal application has AI subscriptions');
 const mcp=await req('GET',`${APIM}/api/am/devportal/v3/mcp-servers?limit=100`,t);
 if(!list(mcp).some(x=>x.name==='TelcoOperationsMCP'&&x.version==='1.0.0'))throw new Error('MCP absent');pass('MCP published and visible');
 let policyFound=false;
 for(const p of ['/api/am/admin/v4/throttling/policies/ai-subscription','/api/am/admin/v4/throttling/policies/aiSubscription']){
   try{const d=await req('GET',`${APIM}${p}?limit=100`,t);policyFound=list(d).some(x=>(x.policyName||x.name)==='TelcoAITokenQuota');if(policyFound)break}catch{}
 }
 if(!policyFound)throw new Error('Native AI token policy absent');pass('Native AI token policy present');
 const sc=await req('GET',`${APIM}/api/am/service-catalog/v1/services?limit=200`,t);
 for(const n of ['TelcoSupportAssistantAPI','TelcoAgentToolsAPI'])if(!list(sc).some(x=>(x.name||x.serviceName)===n))throw new Error(`Service Catalog entry absent: ${n}`);
 pass('Both MI APIs registered in Service Catalog');
})().catch(e=>{console.error(`[telco-ai-apim-verify][FAIL] ${e.stack||e}`);process.exit(1)});
