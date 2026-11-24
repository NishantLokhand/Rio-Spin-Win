import { lowSpinEmail, lowSpinWorkbook, REPORT_TO, REPORT_CC } from './lowSpinReport.mjs';
import { GMAIL_SENDER,gmailMessage,gmailAccessToken } from './lowSpinGmail.mjs';

export function indiaDate(now = new Date()) {
  return new Date(now.getTime()+330*60000).toISOString().slice(0,10);
}
export function yesterdayIndia(now = new Date()) {
  return new Date(Date.parse(indiaDate(now)+'T00:00:00Z')-86400000).toISOString().slice(0,10);
}
const reply = (status, body) => new Response(JSON.stringify(body),{status,headers:{'Content-Type':'application/json'}});
export async function secureEqual(a,b) {
  if (!a || !b) return false;
  const enc=new TextEncoder();
  const [x,y]=await Promise.all([a,b].map(s=>crypto.subtle.digest('SHA-256',enc.encode(s))));
  const p=new Uint8Array(x),q=new Uint8Array(y);let difference=0;
  for(let i=0;i<p.length;i++)difference|=p[i]^q[i];return difference===0;
}
// Dependencies are injected so authentication, retries and provider failures can be tested without sending mail.
export function createLowSpinHandler({ env, db, isAdmin, zipSync, fetcher=fetch, now=()=>new Date() }) {
  async function rpc(name,args) { const {data,error}=await db.rpc(name,args);if(error)throw new Error(name+' failed');return data; }
  return async request => {
    if(request.method!=='POST')return reply(405,{error:'POST required'});
    let authorized=false, internal=false;
    const bearer=request.headers.get('authorization')?.replace(/^Bearer\s+/i,'')||'';
    internal=await secureEqual(bearer,env.SUPABASE_SERVICE_ROLE_KEY)||await secureEqual(request.headers.get('x-report-token'),env.LOW_SPIN_CRON_TOKEN);
    if(internal)authorized=true;
    else if(bearer)authorized=await isAdmin(bearer).catch(()=>false);
    if(!authorized)return reply(401,{error:'Admin or scheduled-report authorization required'});
    let body;try{body=await request.json();}catch{return reply(400,{error:'Valid JSON required'});}
    if(!body||!['test','scheduled','preview'].includes(body.mode))return reply(400,{error:'Choose test, scheduled or preview mode'});
    const kind=body.mode==='test'?'test':'scheduled', date=body.report_date||yesterdayIndia(now());
    if(!/^\d{4}-\d{2}-\d{2}$/.test(date)||date>=indiaDate(now())||Number.isNaN(Date.parse(date))||new Date(date).toISOString().slice(0,10)!==date)
      return reply(400,{error:'Choose a completed India business date'});
    if(body.mode==='scheduled') {
      const hour=(now().getUTCHours()+5+(now().getUTCMinutes()>=30?1:0))%24;
      if(!internal||date!==yesterdayIndia(now())||hour!==10)return reply(403,{error:'Scheduled delivery is limited to yesterday at 10 AM India time'});
    }
    if(body.mode!=='preview'&&(!env.GMAIL_CLIENT_ID||!env.GMAIL_CLIENT_SECRET||!env.GMAIL_REFRESH_TOKEN))return reply(503,{error:'Configure Gmail OAuth for '+GMAIL_SENDER+' before sending'});
    let token;
    try {
      if(body.mode==='preview') {
        const report=await rpc('report_less_than_ten_spins',{p_date:date});
        const email=lowSpinEmail(report,{test:true});
        return reply(200,{date,to:REPORT_TO,cc:REPORT_CC,subject:email.subject,filename:email.filename,summary:report.summary});
      }
      const claim=await rpc('claim_low_spin_email',{p_date:date,p_kind:kind});
      if(!claim.claimed)return reply(200,{skipped:true,status:claim.status,date,kind});
      token=claim.token;
      let payload=claim.payload;
      if(!payload) {
        const report=await rpc('report_less_than_ten_spins',{p_date:date});
        const email=lowSpinEmail(report,{test:kind==='test'}),bytes=lowSpinWorkbook(report,zipSync);
        let binary='';for(let i=0;i<bytes.length;i+=8192)binary+=String.fromCharCode(...bytes.subarray(i,i+8192));
        payload=await rpc('prepare_low_spin_email',{p_date:date,p_kind:kind,p_token:token,p_payload:{
          from:GMAIL_SENDER,to:[REPORT_TO],cc:REPORT_CC,subject:email.subject,html:email.html,text:email.text,
          attachments:[{filename:email.filename,content:btoa(binary)}],
        }});
      }
      const raw=gmailMessage(payload),accessToken=await gmailAccessToken(env,fetcher);
      if(!await rpc('begin_low_spin_email_send',{p_date:date,p_kind:kind,p_token:token}))throw new Error('Email lease expired');
      const response=await fetcher('https://gmail.googleapis.com/gmail/v1/users/'+encodeURIComponent(GMAIL_SENDER)+'/messages/send',{method:'POST',headers:{
        Authorization:`Bearer ${accessToken}`,'Content-Type':'application/json',
      },body:JSON.stringify({raw}),signal:AbortSignal.timeout(20000)});
      const result=await response.json();
      if(!response.ok||typeof result.id!=='string')throw new Error('Email provider rejected delivery (HTTP '+response.status+')');
      const saved=await rpc('finish_low_spin_email',{p_date:date,p_kind:kind,p_token:token,p_provider_id:result.id,p_error:null});
      if(!saved)throw new Error('Email receipt could not be recorded');
      return reply(200,{sent:true,date,kind,provider_id:result.id,to:REPORT_TO,cc:REPORT_CC});
    } catch(error) {
      // Do not log API keys, full payloads or private contact details.
      if(token)await rpc('finish_low_spin_email',{p_date:date,p_kind:kind,p_token:token,p_provider_id:null,p_error:error.message}).catch(()=>{});
      return reply(502,{error:'Report delivery failed. Check the private delivery log before retrying.'});
    }
  };
}
