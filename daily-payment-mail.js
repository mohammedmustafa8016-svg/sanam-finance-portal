/* Delegated mailbox tokens stay in memory. Navigation and preview never send mail. */
(() => {
 'use strict';const text=(ar,en)=>currentLang==='en'?en:ar;
 const permitted=()=>['Supervisor','BankAccountant'].includes(profile?.role)&&originalCanPage('payments');
 const originalCanPage=canPage;
 canPage=function(id){return id==='dailyemail'?permitted():originalCanPage(id);};
 let state={user:null,date:null,preview:null,config:null,auth:null,busy:false,blocked:false,load:0};
 function reset(){state={user:profile?.id,date:riyadhToday(),preview:null,config:null,auth:null,busy:false,blocked:false,load:state.load+1};}
 const section=document.createElement('section');section.id='dailyemail';section.className='section';document.querySelector('.main .content')?.append(section);
 const errors={MAIL_CONNECTION_REQUIRED:['ربط Outlook غير مكتمل. يمكن معاينة التقرير، ويُفعّل الإرسال بعد الإعداد.','Outlook setup is incomplete. Preview is available; sending becomes available after configuration.'],MAIL_PREVIEW_CHANGED_REFRESH:['تغيرت العمليات أو إعدادات البريد. حدّث المعاينة قبل الإرسال.','Payments or routing changed. Refresh the preview before sending.'],MAIL_PREVIOUS_ATTEMPT_UNCERTAIN:['نتيجة محاولة سابقة غير مؤكدة. تحقق من العناصر المرسلة مع المشرف قبل أي إعادة إرسال.','A previous attempt is uncertain. Check Sent Items with your supervisor before resending.'],MAIL_SENDER_MISMATCH:['اربط حساب Outlook المطابق لبريدك المسجل في النظام.','Connect the Outlook account matching your portal email.'],MAIL_OUTLOOK_RECONNECT:['أعد ربط حساب Outlook ثم حاول الإرسال.','Reconnect Outlook before sending.'],MAIL_NO_APPROVED_EXECUTED_PAYMENTS:['لا توجد عمليات منفذة ومعتمدة من المشرف والمدير المالي لهذا التاريخ.','No payments executed on this date have both approvals.'],MAIL_PROVIDER_REJECTED:['رفض Outlook طلب الإرسال. راجع الاتصال والصلاحيات قبل المحاولة مجددًا.','Outlook rejected the send request. Check connection and permissions before retrying.']};
 function errorMessage(code){return errors[code]?text(...errors[code]):text('تعذر إتمام الطلب. حدّث الصفحة أو راجع المشرف.','The request could not be completed. Refresh or contact your supervisor.');}
 function status(value,error=false){const box=document.getElementById('dailyMailStatus');if(box){box.textContent=value;box.className=error?'wc-error':'note';}}
 function controls(){const send=document.getElementById('dailyMailSend'),connect=document.getElementById('dailyMailConnect');if(send)send.disabled=state.busy||state.blocked||!state.config?.ready||!state.preview?.items?.length||!state.auth||state.auth.user!==profile?.id||state.auth.expires<=Date.now();if(connect){connect.disabled=state.busy||!state.config?.client_id||!state.config?.tenant_id;connect.textContent=state.auth?text('إعادة ربط Outlook','Reconnect Outlook'):text('ربط بريدي على Outlook','Connect my Outlook mailbox');}}
 function shell(){section.innerHTML=`<div class="row"><div><h3>${text('البريد اليومي للعمليات المنفذة','Daily executed-payment email')}</h3><p class="muted">${text('تاريخ التنفيذ بتوقيت الرياض، والعمليات المعتمدة من المشرف والمدير المالي فقط.','Riyadh execution date; only payments with both Supervisor and CFO approvals.')}</p></div></div><div class="card"><div class="filters"><label>${text('تاريخ التقرير','Report date')}<input id="dailyMailDate" type="date" max="${riyadhToday()}" value="${state.date}"></label><button id="dailyMailRefresh" type="button" class="btn">${text('تحديث المعاينة','Refresh preview')}</button><button id="dailyMailConnect" type="button" class="btn">Outlook</button><button id="dailyMailSend" type="button" class="btn primary" disabled>${text('إرسال التقرير من بريدي','Send report from my mailbox')}</button></div><div id="dailyMailStatus" class="note" role="status" aria-live="polite"></div><div id="dailyMailRouting" class="daily-mail-routing"></div></div><div id="dailyMailPreview" class="daily-mail-paper"></div><div id="dailyMailHistory" class="muted"></div>`;
 document.getElementById('dailyMailDate').onchange=e=>{if(state.busy)return;state.date=e.target.value;void load();};document.getElementById('dailyMailRefresh').onclick=()=>load();document.getElementById('dailyMailConnect').onclick=connect;document.getElementById('dailyMailSend').onclick=send;controls();}
 async function load(){if(!permitted()||state.busy)return;if(state.user!==profile?.id)reset();const token=++state.load,user=profile.id,date=state.date;state.preview=null;state.blocked=false;controls();status(text('جارٍ إعداد المعاينة…','Preparing preview…'));document.getElementById('dailyMailPreview').replaceChildren();try{
  const results=await Promise.all([sb.rpc('get_daily_payment_mail_config'),sb.rpc('get_daily_payment_mail_preview',{p_report_date:date}),sb.from('daily_payment_mail_dispatches').select('id,status,report_date,created_at,snapshot_hash').eq('sender_id',user).eq('report_date',date).order('created_at',{ascending:false}).limit(20)]);
  if(token!==state.load||user!==profile?.id)return;for(const r of results)if(r.error)throw r.error;
  state.config=results[0].data;state.preview=results[1].data;const history=results[2].data||[];
  const uncertain=history.some(r=>['Sending','Unknown'].includes(r.status)),alreadyAccepted=state.preview.already_accepted===true||history.some(r=>r.status==='Accepted'&&r.snapshot_hash===state.preview.snapshot_hash);state.blocked=uncertain||alreadyAccepted;
  const route=document.getElementById('dailyMailRouting');route.replaceChildren();for(const [label,value] of [[text('الموضوع','Subject'),state.preview.subject],[text('المرسل','Sender'),state.preview.sender.email],['To',state.preview.to.join('; ')],['Cc',state.preview.cc.join('; ')]]){const p=document.createElement('p');p.textContent=`${label}: ${value||'—'}`;route.append(p);}
  document.getElementById('dailyMailPreview').innerHTML=SanamDailyMailTemplate.message(state.preview);
  document.getElementById('dailyMailHistory').textContent=history.length?text('محاولات هذا التاريخ: ','Attempts for this date: ')+history.map(h=>({Accepted:text('قَبِل Outlook الإرسال','Accepted by Outlook'),Sending:text('جارٍ التحقق','Awaiting confirmation'),Unknown:text('النتيجة غير مؤكدة','Result uncertain'),Failed:text('لم يُقبل الإرسال','Send rejected')}[h.status]||h.status)).join(' · '):'';
  status(uncertain?errorMessage('MAIL_PREVIOUS_ATTEMPT_UNCERTAIN'):alreadyAccepted?text('قَبِل Outlook هذه النسخة سابقًا؛ أعد المعاينة عند إضافة عمليات جديدة.','Outlook already accepted this version. Refresh when new payments are available.'):!state.config.ready?errorMessage('MAIL_CONNECTION_REQUIRED'):state.preview.items.length?text('راجع البيانات ثم اضغط إرسال. فتح الصفحة لا يرسل البريد.','Review the report, then press Send. Opening this page never sends mail.'):errorMessage('MAIL_NO_APPROVED_EXECUTED_PAYMENTS'),uncertain);
 }catch(e){if(token===state.load&&user===profile?.id)status(errorMessage(e.message),true);}finally{if(token===state.load)controls();}}
 function base64(bytes){return btoa(String.fromCharCode(...bytes)).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');}
 async function connect(){if(!permitted()||state.busy||!state.config?.client_id||!state.config?.tenant_id)return;const popup=window.open('about:blank','sanam-outlook','popup,width=600,height=740');if(!popup)return status(text('اسمح بنافذة الربط المنبثقة ثم أعد المحاولة.','Allow the connection popup, then retry.'),true);const user=profile.id,nonce=base64(crypto.getRandomValues(new Uint8Array(32))),verifier=base64(crypto.getRandomValues(new Uint8Array(48))),config=state.config;state.busy=true;controls();try{
  if(!/^[0-9a-f-]{36}$/i.test(config.client_id)||!/^[0-9a-f-]{36}$/i.test(config.tenant_id))throw new Error('MAIL_CONNECTION_REQUIRED');
  const challenge=base64(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier)))),redirect=location.origin+'/outlook-callback.html',authority='https://login.microsoftonline.com/'+config.tenant_id+'/oauth2/v2.0';
  const code=await new Promise((resolve,reject)=>{let done=false;const channel=new BroadcastChannel('sanam-outlook-'+nonce);let timeout,poll;const finish=(error,value)=>{if(done)return;done=true;clearTimeout(timeout);clearInterval(poll);window.removeEventListener('message',listener);channel.close();popup.close();error?reject(error):resolve(value);};const receive=data=>{if(data?.type!=='sanam-outlook-code'||data.state!==nonce)return;if(data.error||!data.code)finish(new Error('MAIL_OUTLOOK_RECONNECT'));else finish(null,data.code);};const listener=event=>{if(event.origin===location.origin&&event.source===popup)receive(event.data);};window.addEventListener('message',listener);channel.onmessage=e=>receive(e.data);timeout=setTimeout(()=>finish(new Error('MAIL_OUTLOOK_RECONNECT')),300000);poll=setInterval(()=>{if(popup.closed)finish(new Error('MAIL_OUTLOOK_RECONNECT'));},500);const params=new URLSearchParams({client_id:config.client_id,response_type:'code',redirect_uri:redirect,response_mode:'query',scope:'https://graph.microsoft.com/User.Read https://graph.microsoft.com/Mail.Send',state:nonce,code_challenge:challenge,code_challenge_method:'S256',prompt:'select_account'});popup.location=authority+'/authorize?'+params;});
  const response=await fetch(authority+'/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({client_id:config.client_id,grant_type:'authorization_code',code,redirect_uri:redirect,code_verifier:verifier,scope:'https://graph.microsoft.com/User.Read https://graph.microsoft.com/Mail.Send'})});if(!response.ok)throw new Error('MAIL_OUTLOOK_RECONNECT');const token=await response.json();
  const me=await fetch('https://graph.microsoft.com/v1.0/me?$select=mail,userPrincipalName',{headers:{Authorization:'Bearer '+token.access_token}});if(!me.ok)throw new Error('MAIL_OUTLOOK_RECONNECT');const mailbox=await me.json();if(![mailbox.mail,mailbox.userPrincipalName].some(v=>String(v||'').toLowerCase()===String(profile?.email||'').toLowerCase()))throw new Error('MAIL_SENDER_MISMATCH');
  if(user!==profile?.id)return;state.auth={user,token:token.access_token,expires:Date.now()+Math.max(0,Number(token.expires_in||0)-60)*1000};status(text('تم ربط بريدك. يمكنك إرسال التقرير بعد مراجعته.','Your mailbox is connected. Review the report before sending.'));
 }catch(e){state.auth=null;if(user===profile?.id)status(errorMessage(e.message),true);}finally{popup.close();if(user===profile?.id){state.busy=false;controls();}}}
 async function send(){if(!permitted()||state.busy||state.blocked||!state.preview||!state.auth||!state.config?.ready)return;const user=profile.id,snapshot=state.preview,auth=state.auth;if(auth.user!==user||auth.expires<=Date.now())return status(errorMessage('MAIL_OUTLOOK_RECONNECT'),true);state.busy=true;controls();document.getElementById('dailyMailDate').disabled=true;document.getElementById('dailyMailRefresh').disabled=true;let attempted=false;try{
  const token=session?.access_token||(await sb.auth.getSession()).data?.session?.access_token;if(!token||profile?.id!==user)throw new Error('MAIL_SESSION_REQUIRED');attempted=true;
  const response=await fetch('/api/daily-payment-email',{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify({date:snapshot.date,snapshot_hash:snapshot.snapshot_hash,outlook_token:auth.token})});const result=await response.json();if(profile?.id!==user)return;if(!response.ok){if(result.status==='Unknown'||result.error==='MAIL_PREVIOUS_ATTEMPT_UNCERTAIN')state.blocked=true;throw new Error(result.error);}state.blocked=true;status(result.duplicate?text('هذا التقرير مقبول سابقًا لدى Outlook؛ لم يُرسل مرة ثانية.','Outlook already accepted this report; no duplicate was sent.'):text('قَبِل Outlook التقرير للإرسال. هذا تأكيد قبول، وليس تأكيد تسليم للمستلمين.','Outlook accepted the report for sending. This confirms acceptance, not recipient delivery.'));
 }catch(e){if(user===profile?.id){if(attempted){state.blocked=true;status(text('جارٍ التحقق من نتيجة الإرسال المسجلة…','Checking the recorded send result…'));let accepted=false;try{const r=await sb.from('daily_payment_mail_dispatches').select('id,status').eq('sender_id',user).eq('report_date',snapshot.date).eq('snapshot_hash',snapshot.snapshot_hash).limit(1);accepted=!r.error&&r.data?.[0]?.status==='Accepted';}catch{}if(user!==profile?.id)return;if(accepted){status(text('قَبِل Outlook التقرير للإرسال وتم تأكيد ذلك من سجل النظام. هذا ليس تأكيد تسليم للمستلمين.','Outlook accepted the report for sending, confirmed by the system record. This is not confirmation of recipient delivery.'));}else status(errorMessage(e.message in errors?e.message:'MAIL_PREVIOUS_ATTEMPT_UNCERTAIN'),true);}else status(errorMessage(e.message),true);}}finally{if(user===profile?.id){state.busy=false;document.getElementById('dailyMailDate').disabled=false;document.getElementById('dailyMailRefresh').disabled=false;controls();}}}
 window.openDailyMailSettings=async function(){if(profile?.role!=='CFO')return;const [{data:c,error},{data:uncertain,error:queueError}]=await Promise.all([sb.rpc('get_daily_payment_mail_config'),sb.rpc('get_uncertain_daily_payment_mail')]);if(error||queueError)return alert((error||queueError).message);showModal(text('إعداد البريد اليومي','Daily email setup'),`<p class="muted">${text('معرّفا التطبيق والمستأجر من مسؤول Microsoft 365. لا تدخل كلمة مرور أو مفتاحًا سريًا.','Use the application and tenant IDs supplied by Microsoft 365 administration. Do not enter a password or client secret.')}</p><div class="modal-grid">${input('mailClientId','Application (client) ID',c.client_id||'')}${input('mailTenantId','Directory (tenant) ID',c.tenant_id||'')}</div><label>To</label><textarea id="mailTo">${esc((c.to||[]).join('; '))}</textarea><label>Cc</label><textarea id="mailCc">${esc((c.cc||[]).join('; '))}</textarea><label class="inbox-check"><input id="mailEnabled" type="checkbox" ${c.enabled?'checked':''}>${text('تفعيل الإرسال بعد استكمال الربط','Enable sending after setup')}</label><div id="mailConfigError" class="wc-error hidden"></div><button id="mailConfigSave" class="btn primary">${text('حفظ الإعدادات','Save settings')}</button>`);const queue=document.createElement('div');queue.className='daily-mail-reconciliation';
    for(const row of uncertain||[]){const box=document.createElement('div');box.className='card';const heading=document.createElement('p');heading.textContent=`${row.report_date} · ${row.sender_name} · ${row.status}`;const note=document.createElement('textarea');note.placeholder=text('تحقق مع صاحب البريد من العناصر المرسلة ثم وثق نتيجة التحقق (20 حرفًا على الأقل).','Verify Sent Items with the mailbox owner and document the evidence (at least 20 characters).');const sent=document.createElement('button'),notSent=document.createElement('button');for(const [button,value,label] of [[sent,true,text('تم التحقق: أُرسل','Verified: sent')],[notSent,false,text('تم التحقق: لم يُرسل','Verified: not sent')]]){button.type='button';button.className='btn';button.textContent=label;button.onclick=async()=>{sent.disabled=notSent.disabled=true;const r=await sb.rpc('resolve_daily_payment_mail_attempt',{p_dispatch_id:row.dispatch_id,p_confirmed_sent:value,p_reason:note.value});if(r.error){alert(r.error.message);sent.disabled=notSent.disabled=false;}else box.remove();};}box.append(heading,note,sent,notSent);queue.append(box);}const editTemplate=document.createElement('button');
    editTemplate.id='dailyMailTemplateEdit';editTemplate.type='button';editTemplate.className='btn';
    editTemplate.textContent=text('تعديل صيغة الرسالة','Edit email template');
    editTemplate.onclick=()=>openTemplateEditor(c.template??null);
    document.getElementById('mailConfigSave').after(editTemplate,queue);
    document.getElementById('mailConfigSave').onclick=async()=>{const button=document.getElementById('mailConfigSave');button.disabled=true;try{const list=id=>document.getElementById(id).value.split(/[;,\n]+/).map(s=>s.trim()).filter(Boolean);const r=await sb.rpc('configure_daily_payment_mail',{p_client_id:document.getElementById('mailClientId').value.trim()||null,p_tenant_id:document.getElementById('mailTenantId').value.trim()||null,p_to:list('mailTo'),p_cc:list('mailCc'),p_enabled:document.getElementById('mailEnabled').checked});if(r.error)throw r.error;closeModal();}catch(e){const box=document.getElementById('mailConfigError');box.textContent=e.message;box.classList.remove('hidden');button.disabled=false;}};};
 function openTemplateEditor(savedTemplate){
  if(profile?.role!=='CFO')return;
  const renderer=SanamDailyMailTemplate;
  const fields=[
   ['subject',text('موضوع البريد','Subject'),200],
   ['greeting',text('التحية','Greeting'),500],
   ['intro',text('المقدمة','Introduction'),2000],
   ['closing',text('الخاتمة','Closing'),1000]
  ];
  const values={...renderer.defaults,...savedTemplate};
  showModal(text('صيغة بريد المدفوعات المنفذة','Executed payment email template'),`
   <p class="muted">${text('استخدم {{date}} لإدراج تاريخ التقرير، و{{day}} لإدراج اسم اليوم في نص الرسالة.','Use {{date}} for the report date and {{day}} for the weekday in the message body.')}</p>
   ${fields.map(([key,label,max])=>`<div>
    <label for="dailyMailTemplate-${key}">${label}</label>
    ${key==='subject'
     ?`<input id="dailyMailTemplate-${key}" maxlength="${max}" value="${esc(values[key])}">`
     :`<textarea id="dailyMailTemplate-${key}" maxlength="${max}" rows="2">${esc(values[key])}</textarea>`}
   </div>`).join('')}
   <h4>${text('معاينة ببيانات تجريبية','Preview with sample data')}</h4>
   <div id="dailyMailTemplatePreviewSubject"></div>
   <div id="dailyMailTemplatePreview" class="daily-mail-paper" style="overflow:auto"></div>
   <p id="dailyMailTemplateStatus" role="status" aria-live="polite"></p>
   <div class="row">
    <button id="dailyMailTemplateSave" type="button" class="btn primary">${text('حفظ الصيغة','Save template')}</button>
    <button id="dailyMailTemplateReset" type="button" class="btn">${text('استعادة الصيغة الأصلية','Restore original template')}</button>
   </div>`);
  const byId=id=>document.getElementById(id);
  const editors=fields.map(([key])=>[key,byId('dailyMailTemplate-'+key)]);
  const save=byId('dailyMailTemplateSave'),resetButton=byId('dailyMailTemplateReset');
  const notice=byId('dailyMailTemplateStatus'),body=byId('dailyMailTemplatePreview'),subject=byId('dailyMailTemplatePreviewSubject');
  const date=riyadhToday();
  const sample={
   date,
   items:[{due_date:date,company:text('شركة تجريبية','Sample company'),beneficiary:text('مستفيد تجريبي','Sample beneficiary'),amount:1250,bank_account:text('حساب تجريبي','Sample account'),purpose:text('دفعة تجريبية','Sample payment')}],
   total:1250,sender:{name:text('مرسل تجريبي','Sample sender'),role:'Supervisor',email:'sender@example.com'}
  };
  const draft=()=>Object.fromEntries(editors.map(([key,field])=>[key,field.value.trim()]));
  const render=()=>{
   const template=draft();
   subject.textContent=renderer.subject(template,date);
   body.innerHTML=renderer.message({...sample,template});
  };
  for(const [,field] of editors)field.addEventListener('input',render);
  resetButton.onclick=()=>{
   for(const [key,field] of editors)field.value=renderer.defaults[key];
   notice.textContent=text('اضغط حفظ الصيغة لاعتماد النص الأصلي.','Save the template to restore the original text.');
   render();
  };
  save.onclick=async()=>{
   if(profile?.role!=='CFO')return;
   const template=draft();
   if(!template.subject){
    notice.textContent=text('أدخل موضوع البريد.','Enter an email subject.');
    return;
   }
   const value=Object.keys(renderer.defaults).every(key=>renderer.defaults[key]===template[key])?null:template;
   save.disabled=resetButton.disabled=true;
   for(const [,field] of editors)field.disabled=true;
   try{
    const result=await sb.rpc('save_daily_payment_mail_template',{p_template:value,p_expected:savedTemplate??null});
    if(result.error)throw result.error;
    savedTemplate=value;
    notice.textContent=text('تم حفظ صيغة البريد.','Email template saved.');
   }catch(error){
    notice.textContent=error.message==='MAIL_TEMPLATE_CHANGED_REFRESH'
     ?text('تغيرت الصيغة في جلسة أخرى. أعد فتح إعداد البريد لقراءة آخر صيغة.','The template changed in another session. Reopen email setup to load it.')
     :text('تعذر حفظ الصيغة. راجع الموضوع وطول النص وحاول مجددًا.','Could not save the template. Check the subject and text length and retry.');
   }finally{
    save.disabled=resetButton.disabled=false;
    for(const [,field] of editors)field.disabled=false;
   }
  };
  render();
 }
 const previousOpen=openPage;openPage=function(id,...args){const result=previousOpen(id,...args);if(id==='dailyemail'&&permitted()){if(state.user!==profile.id)reset();shell();void load();}return result;};
 function settingsButton(){if(state.user&&state.user!==profile?.id)reset();const area=document.querySelector('#automation>.row');if(!area)return;let button=document.getElementById('dailyMailSettingsBtn');if(!button){button=document.createElement('button');button.id='dailyMailSettingsBtn';button.className='btn';button.type='button';button.onclick=openDailyMailSettings;area.append(button);}button.hidden=profile?.role!=='CFO';button.textContent=text('إعداد البريد اليومي','Daily email setup');}
 for(const name of ['applyAccess','applyLanguage']){const previous=window[name];window[name]=function(...args){const result=previous.apply(this,args);settingsButton();if(name==='applyLanguage'&&section.classList.contains('active')&&permitted()){shell();void load();}return result;};}
 const previousAuth=showAuth;showAuth=function(...args){reset();state.auth=null;return previousAuth.apply(this,args);};settingsButton();
})();

