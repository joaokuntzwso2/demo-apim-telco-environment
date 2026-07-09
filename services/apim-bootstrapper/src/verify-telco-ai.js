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
async function token() {
  // TELCO_AI_DCR_AUTH_FIX
  const apimUrl =
    process.env.WSO2_APIM_URL ||
    process.env.APIM_URL ||
    'https://wso2-apim:9443';

  const username =
    process.env.APIM_USERNAME ||
    process.env.APIM_USER ||
    'admin';

  const password =
    process.env.APIM_PASSWORD ||
    process.env.APIM_PASS ||
    'admin';

  function withDispatcher(options) {
    if (typeof dispatcher !== 'undefined') {
      options.dispatcher = dispatcher;
    }
    return options;
  }

  async function responseJson(response, operation) {
    const text = await response.text();

    if (!response.ok) {
      throw new Error(
        `${operation}: ${response.status} ${text}`
      );
    }

    try {
      return text ? JSON.parse(text) : {};
    } catch {
      throw new Error(
        `${operation}: response was not valid JSON: ${text}`
      );
    }
  }

  const dcrUrl =
    `${apimUrl}/client-registration/v0.17/register`;

  const dcrResponse = await fetch(
    dcrUrl,
    withDispatcher({
      method: 'POST',
      headers: {
        authorization:
          `Basic ${Buffer.from(
            `${username}:${password}`
          ).toString('base64')}`,
        'content-type': 'application/json'
      },
      body: JSON.stringify({
        callbackUrl: 'http://localhost:8080/callback',
        clientName:
          `telco-ai-verifier-${Date.now()}-` +
          Math.random().toString(16).slice(2),
        owner: username,
        grantType:
          'password refresh_token client_credentials',
        saasApp: true
      })
    })
  );

  const client = await responseJson(
    dcrResponse,
    `POST ${dcrUrl}`
  );

  if (!client.clientId || !client.clientSecret) {
    throw new Error(
      `DCR response did not contain client credentials: ` +
      JSON.stringify(client)
    );
  }

  const form = new URLSearchParams();

  form.set('grant_type', 'password');
  form.set('username', username);
  form.set('password', password);
  form.set(
    'scope',
    [
      'apim:api_view',
      'apim:api_create',
      'apim:api_update',
      'apim:api_manage',
      'apim:api_publish',
      'apim:app_manage',
      'apim:sub_manage',
      'apim:subscribe',
      'apim:api_key',
      'apim:api_generate_key',
      'service_catalog:service_view'
    ].join(' ')
  );

  const tokenUrl = `${apimUrl}/oauth2/token`;

  const tokenResponse = await fetch(
    tokenUrl,
    withDispatcher({
      method: 'POST',
      headers: {
        authorization:
          `Basic ${Buffer.from(
            `${client.clientId}:${client.clientSecret}`
          ).toString('base64')}`,
        'content-type':
          'application/x-www-form-urlencoded'
      },
      body: form.toString()
    })
  );

  const tokenResult = await responseJson(
    tokenResponse,
    `POST ${tokenUrl}`
  );

  if (!tokenResult.access_token) {
    throw new Error(
      `Token response did not contain access_token: ` +
      JSON.stringify(tokenResult)
    );
  }

  return tokenResult.access_token;
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
  const policyCheck = require(
    'child_process'
  ).spawnSync(
    process.execPath,
    [
      require('path').join(
        __dirname,
        'check-telco-ai-policy.js'
      )
    ],
    {
      encoding: 'utf8',
      env: process.env
    }
  );

  if (policyCheck.status !== 0) {
    throw new Error(
      'Native AI token policy absent: ' +
      (
        policyCheck.stderr ||
        policyCheck.stdout ||
        `checker exited with ${policyCheck.status}`
      ).trim()
    );
  }

  console.log(
    '[telco-ai-apim-verify][PASS] ' +
    'Native AI token policy'
  );

 const sc=await req('GET',`${APIM}/api/am/service-catalog/v1/services?limit=200`,t);
 for(const n of ['TelcoSupportAssistantAPI','TelcoAgentToolsAPI'])if(!list(sc).some(x=>(x.name||x.serviceName)===n))throw new Error(`Service Catalog entry absent: ${n}`);
 pass('Both MI APIs registered in Service Catalog');
})().catch(e=>{console.error(`[telco-ai-apim-verify][FAIL] ${e.stack||e}`);process.exit(1)});
