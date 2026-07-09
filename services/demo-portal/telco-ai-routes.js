'use strict';
const fs=require('fs'), https=require('https'), crypto=require('crypto');
function request(url,{method='GET',headers={},body}={}){
  return new Promise((resolve,reject)=>{
    const u=new URL(url); const req=https.request({hostname:u.hostname,port:u.port||443,path:u.pathname+u.search,method,headers,rejectUnauthorized:false},res=>{
      let data='';res.on('data',c=>data+=c);res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,body:data}));
    });req.on('error',reject);if(body)req.write(body);req.end();
  });
}
function findCredentials(v){
  if(!v||typeof v!=='object')return null;
  const key=v.consumerKey||v.clientId,secret=v.consumerSecret||v.clientSecret;
  if(key&&secret)return{key,secret};
  for(const x of Object.values(v)){const f=findCredentials(x);if(f)return f} return null;
}
module.exports=function(app){
  const stateFile=process.env.APIM_PORTAL_STATE_FILE||'/workspace/apim-portal-state/runtime.json';
  const apim=process.env.WSO2_APIM_URL||'https://wso2-apim:9443';
  const gateway=process.env.WSO2_APIM_GATEWAY_URL||'https://wso2-apim:8243';
  const partner=process.env.TELCO_AI_PARTNER_ID||'partner-alpha';
  const state=()=>{try{return JSON.parse(fs.readFileSync(stateFile,'utf8'))}catch{return{}}};
  async function token(){
    const c=findCredentials(state());if(!c)throw new Error('Regional Portal application credentials are absent from runtime state.');
    const body=new URLSearchParams({grant_type:'client_credentials',scope:'telco_ai_support telco_subscriber_status telco_outage_read telco_qod_request telco_ticket_create'}).toString();
    const r=await request(`${apim}/oauth2/token`,{method:'POST',headers:{authorization:`Basic ${Buffer.from(`${c.key}:${c.secret}`).toString('base64')}`,'content-type':'application/x-www-form-urlencoded','content-length':Buffer.byteLength(body)},body});
    const j=JSON.parse(r.body||'{}');if(r.status<200||r.status>299||!j.access_token)throw new Error(`Token request failed: ${r.status} ${r.body}`);return j.access_token;
  }
  app.get('/api/ai/status',(req,res)=>{const s=state();res.json({configured:Boolean(s.ai&&s.ai.enabled),published:s.ai||null,partnerId:partner})});
  app.post('/api/ai/chat',async(req,res)=>{
    const correlation=req.get('X-Correlation-ID')||crypto.randomUUID();
    try{
      const t=await token(), payload=JSON.stringify({sessionId:String(req.body?.sessionId||`portal-${partner}`),message:String(req.body?.message||''),profile:req.body?.profile==='advanced'?'advanced':'standard'});
      const r=await request(`${gateway}/telco-support/v1/1.0.0/chat`,{method:'POST',headers:{authorization:`Bearer ${t}`,'X-Agent-Tool-Token':t,'X-Partner-Id':partner,'X-Correlation-ID':correlation,'content-type':'application/json','content-length':Buffer.byteLength(payload)},body:payload});
      res.status(r.status).type(r.headers['content-type']||'application/json').send(r.body);
    }catch(e){res.status(502).json({type:'https://telco.example/problems/portal-ai-proxy',title:'Portal AI proxy failure',status:502,code:'PORTAL_AI_PROXY_FAILURE',detail:e.message,correlationId:correlation})}
  });
};
