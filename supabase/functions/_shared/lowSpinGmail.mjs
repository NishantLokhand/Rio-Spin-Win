export const GMAIL_SENDER='ai.automation@gooddropwine.com';
const base64=text=>{const bytes=new TextEncoder().encode(text);let s='';for(let i=0;i<bytes.length;i+=8192)s+=String.fromCharCode(...bytes.subarray(i,i+8192));return btoa(s);};
const lines=s=>s.match(/.{1,76}/g)?.join('\r\n')||'';
export function gmailMessage(payload) {
  // All address headers are fixed server-side, never copied from incoming requests.
  if(payload.from!==GMAIL_SENDER||[...payload.to,...payload.cc].some(v=>/[\r\n]/.test(v)))throw Error('Invalid email headers');
  const outer='rio_report_attachment',inner='rio_report_alternatives';
  const mime=[`From: RIO Spin & Win <${GMAIL_SENDER}>`,`To: ${payload.to.join(', ')}`,`Cc: ${payload.cc.join(', ')}`,
    `Subject: =?UTF-8?B?${base64(payload.subject)}?=`,'MIME-Version: 1.0',`Content-Type: multipart/mixed; boundary="${outer}"`,'',
    `--${outer}`,`Content-Type: multipart/alternative; boundary="${inner}"`,'',
    `--${inner}`,'Content-Type: text/plain; charset=UTF-8','Content-Transfer-Encoding: base64','',lines(base64(payload.text)),
    `--${inner}`,'Content-Type: text/html; charset=UTF-8','Content-Transfer-Encoding: base64','',lines(base64(payload.html)),`--${inner}--`,
    ...payload.attachments.flatMap(a=>{
      if(!/^[a-zA-Z0-9_.-]+\.xlsx$/.test(a.filename))throw Error('Invalid attachment filename');
      return [`--${outer}`,'Content-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        `Content-Disposition: attachment; filename="${a.filename}"`,'Content-Transfer-Encoding: base64','',lines(a.content)];
    }),`--${outer}--`,''
  ].join('\r\n');
  return base64(mime).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
}
export async function gmailAccessToken(env,fetcher=fetch) {
  const response=await fetcher('https://oauth2.googleapis.com/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
    body:new URLSearchParams({client_id:env.GMAIL_CLIENT_ID,client_secret:env.GMAIL_CLIENT_SECRET,refresh_token:env.GMAIL_REFRESH_TOKEN,grant_type:'refresh_token'}),signal:AbortSignal.timeout(15000)});
  const data=await response.json();if(!response.ok||!data.access_token)throw Error('Gmail authorization needs attention');return data.access_token;
}
