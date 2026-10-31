const {rpc,user}=require('../server/mail-platform.cjs');const {message}=require('../daily-mail-template.js');const {randomUUID}=require('node:crypto');
module.exports=async function handler(req,res){
 res.setHeader('Cache-Control','no-store');res.setHeader('Content-Type','application/json');
 const reply=(status,data)=>res.status(status).json(data);
 if(req.method!=='POST')return reply(405,{error:'METHOD_NOT_ALLOWED'});
 const origins=['https://sanam-finance-cloud-pilot-mohammedmustafa8016-6001.vercel.app',process.env.VERCEL_URL?'https://'+process.env.VERCEL_URL:null];
 if(!origins.includes(req.headers.origin))return reply(403,{error:'MAIL_ORIGIN_DENIED'});
 const authorization=req.headers.authorization||'',secret=process.env.SANAM_MAIL_DISPATCH_SECRET;
 if(!authorization.startsWith('Bearer '))return reply(401,{error:'MAIL_SESSION_REQUIRED'});
 if(!secret)return reply(503,{error:'MAIL_CONNECTION_REQUIRED'});
 let body;try{body=typeof req.body==='string'?JSON.parse(req.body):req.body||{};}catch{return reply(400,{error:'MAIL_INVALID_REQUEST'});}
 if(!/^\d{4}-\d{2}-\d{2}$/.test(body.date||'')||!/^[a-f0-9]{64}$/.test(body.snapshot_hash||'')||typeof body.outlook_token!=='string'||body.outlook_token.length>20000||!body.outlook_token)return reply(400,{error:'MAIL_INVALID_REQUEST'});
 let claim,attempted=false,acknowledged=false;
 try{
  await user(authorization);
  const preview=await rpc('get_daily_payment_mail_preview',{p_report_date:body.date},authorization);
  if(preview.snapshot_hash!==body.snapshot_hash)return reply(409,{error:'MAIL_PREVIEW_CHANGED_REFRESH'});
  const identityResponse=await fetch('https://graph.microsoft.com/v1.0/me?$select=id,mail,userPrincipalName',{headers:{Authorization:'Bearer '+body.outlook_token},signal:AbortSignal.timeout(8000)});
  if(!identityResponse.ok)return reply(401,{error:'MAIL_OUTLOOK_RECONNECT'});
  const identity=await identityResponse.json(),expected=String(preview.sender.email||'').toLowerCase();
  if(!expected||![identity.mail,identity.userPrincipalName].some(value=>String(value||'').toLowerCase()===expected))return reply(403,{error:'MAIL_SENDER_MISMATCH'});
  claim=await rpc('claim_daily_payment_mail',{p_report_date:body.date,p_snapshot_hash:body.snapshot_hash,p_request_id:randomUUID(),p_server_secret:secret},authorization);
  if(claim.duplicate)return reply(200,{status:'Accepted',duplicate:true,dispatch_id:claim.id});
  const snapshot=claim.snapshot,clientRequestId=randomUUID();attempted=true;
  const sent=await fetch('https://graph.microsoft.com/v1.0/me/sendMail',{method:'POST',headers:{Authorization:'Bearer '+body.outlook_token,'Content-Type':'application/json','client-request-id':clientRequestId,'return-client-request-id':'true'},body:JSON.stringify({message:{subject:snapshot.subject,body:{contentType:'HTML',content:message(snapshot)},toRecipients:snapshot.to.map(address=>({emailAddress:{address}})),ccRecipients:snapshot.cc.map(address=>({emailAddress:{address}}))},saveToSentItems:true}),signal:AbortSignal.timeout(15000)});
  const status=sent.status===202?'Accepted':sent.status>=400&&sent.status<500?'Failed':'Unknown';acknowledged=sent.status===202;
  await rpc('finish_daily_payment_mail',{p_dispatch_id:claim.id,p_status:status,p_provider_request_id:sent.headers.get('request-id')||clientRequestId,p_error_code:status==='Accepted'?null:'GRAPH_HTTP_'+sent.status,p_server_secret:secret},authorization);
  return reply(status==='Accepted'?200:status==='Failed'?502:503,{status,dispatch_id:claim.id,error:status==='Accepted'?undefined:status==='Failed'?'MAIL_PROVIDER_REJECTED':'MAIL_PREVIOUS_ATTEMPT_UNCERTAIN'});
 }catch(error){
  if(claim?.id&&!claim.duplicate){try{await rpc('finish_daily_payment_mail',{p_dispatch_id:claim.id,p_status:attempted?'Unknown':'Failed',p_provider_request_id:null,p_error_code:acknowledged?'ACKNOWLEDGED_AUDIT_UNCONFIRMED':attempted?'SEND_RESULT_UNCONFIRMED':'BEFORE_SEND_FAILED',p_server_secret:secret},authorization);}catch{/* Keep Sending: never automatically resend an uncertain attempt. */}}
  const known=['MAIL_PREVIEW_CHANGED_REFRESH','MAIL_PREVIOUS_ATTEMPT_UNCERTAIN','MAIL_NO_APPROVED_EXECUTED_PAYMENTS','MAIL_CONNECTION_REQUIRED','MAIL_SESSION_REQUIRED','MAIL_SENDER_ROLE_REQUIRED'];
  return reply(attempted?503:400,{error:attempted?'MAIL_PREVIOUS_ATTEMPT_UNCERTAIN':known.includes(error.message)?error.message:'MAIL_REQUEST_FAILED'});
 }
};
