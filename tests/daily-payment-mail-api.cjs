const assert=require('node:assert/strict');const handler=require('../api/daily-payment-email.js');const {message}=require('../daily-mail-template.js');
const hash='a'.repeat(64),snapshot={date:'2026-10-29',snapshot_hash:hash,subject:'Daily executed payments',sender:{id:'user',name:'Test sender',role:'Supervisor',email:'sender@local.invalid'},to:['recipient@local.invalid'],cc:[],items:[{amount:100,company:'Local',beneficiary:'<img src=x onerror=alert(1)>',bank_account:'Test bank',purpose:'Executed',due_date:'2026-10-29'}],total:100};
function response(status,data,headers={}){return {ok:status>=200&&status<300,status,json:async()=>data,headers:new Headers(headers)};}
async function scenario(options={}){const calls=[],finish=[];global.fetch=async(url,request={})=>{calls.push(url);const body=request.body?JSON.parse(request.body):{};
 if(url.includes('/auth/v1/user'))return response(200,{id:'user'});
 if(url.includes('/rpc/get_daily_payment_mail_preview'))return response(200,options.stale?{...snapshot,snapshot_hash:'b'.repeat(64)}:snapshot);
 if(url.includes('/v1.0/me?'))return response(200,{mail:options.wrongSender?'other@local.invalid':snapshot.sender.email});
 if(url.includes('/rpc/claim_daily_payment_mail'))return response(200,{id:'dispatch',snapshot,duplicate:!!options.duplicate});
 if(url.includes('/rpc/finish_daily_payment_mail')){finish.push(body.p_status);if(options.auditFailure)return response(503,{message:'Audit unavailable'});return response(200,null);}
 if(url.includes('/me/sendMail')){assert.equal(body.message.toRecipients[0].emailAddress.address,'recipient@local.invalid');assert.doesNotMatch(body.message.body.content,/<img/);if(options.networkFailure)throw new Error('network uncertain');return response(options.graphStatus||202,null,{'request-id':'provider-request'});}
 throw new Error('Unexpected test URL');};
 const req={method:options.method||'POST',headers:{origin:options.origin||'https://sanam-finance-cloud-pilot-mohammedmustafa8016-6001.vercel.app',authorization:'Bearer fixture-session'},body:{date:snapshot.date,snapshot_hash:hash,outlook_token:'fixture-outlook-token'}},res={setHeader(){},status(code){this.code=code;return this;},json(data){this.data=data;return this;}};
 await handler(req,res);return {code:res.code,data:res.data,calls,finish};}
(async()=>{const previous=global.fetch;process.env.SANAM_MAIL_DISPATCH_SECRET='local-test-dispatch-secret';try{
 let r=await scenario();assert.equal(r.code,200);assert.equal(r.data.status,'Accepted');assert.deepEqual(r.finish,['Accepted']);
 r=await scenario({wrongSender:true});assert.equal(r.code,403);assert.equal(r.calls.some(u=>u.includes('claim_daily')),false);
 r=await scenario({stale:true});assert.equal(r.code,409);assert.equal(r.calls.some(u=>u.includes('graph.microsoft.com')),false);
 r=await scenario({duplicate:true});assert.equal(r.data.duplicate,true);assert.equal(r.calls.some(u=>u.includes('/sendMail')),false);
 r=await scenario({graphStatus:403});assert.equal(r.code,502);assert.deepEqual(r.finish,['Failed']);
 r=await scenario({networkFailure:true});assert.equal(r.code,503);assert.deepEqual(r.finish,['Unknown']);assert.equal(r.calls.filter(u=>u.includes('/sendMail')).length,1);
 r=await scenario({graphStatus:500});assert.deepEqual(r.finish,['Unknown']);
 r=await scenario({auditFailure:true});assert.equal(r.code,503);assert.equal(r.calls.filter(u=>u.includes('/sendMail')).length,1);
 r=await scenario({origin:'https://other.example'});assert.equal(r.code,403);assert.equal(r.calls.length,0);
 assert.doesNotMatch(message(snapshot),/<img/);process.env.VERCEL_ENV='preview';assert.match(require('../server/mail-platform.cjs').backend().supabaseUrl,/lpanqnuwmeusmygzhcxm/);
 console.log('PASS: authoritative snapshot, matching sender, stale preview, duplicate suppression, explicit send only, accepted/rejected/uncertain audit, no auto retry, escaped email and preview isolation. No real mail sent.');
}finally{global.fetch=previous;delete process.env.SANAM_MAIL_DISPATCH_SECRET;delete process.env.VERCEL_ENV;}})().catch(e=>{console.error(e);process.exitCode=1;});
