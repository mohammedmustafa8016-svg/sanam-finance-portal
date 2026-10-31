/* Stage-aware release of payment holds; existing registration and final-posting APIs remain separate. */
(() => {
 'use strict';
 const $=id=>document.getElementById(id),T=(ar,en)=>currentLang==='en'?en:ar;
 const words={'تاريخ التعليق':'Held since','نوع التعليق':'Hold type','المبلغ المعلق':'Held amount','المبلغ غير المعلق':'Unheld amount','سبب التعليق':'Hold reason','مسؤول المتابعة':'Follow-up owner','تاريخ المتابعة':'Follow-up date','مدة التعليق':'Days on hold','الإجراء المطلوب':'Required action','كامل':'Full','جزئي':'Partial','عمليات أوقفها محاسب القيود قبل التسجيل أو علّقها المشرف/المدير المالي بعد التسجيل، مع تبرير وملاحظات وتحديد كامل أو جزئي للمبلغ.':'Payments held by GL before registration or by Supervisor/CFO afterward, with reasons, notes and full/partial amounts.'};
 Object.assign(I18N_AR_EN,words);for(const [ar,en] of Object.entries(words))I18N_EN_AR[en]=ar;
 const eligible=p=>!!p&&p.status==='معلقة'&&!!p.executed_at&&!p.posted_at;
 const manager=()=>['Supervisor','CFO'].includes(profile?.role);
 const reader=()=>!!profile&&!isReadonlyViewer()&&canPage('payments')&&['CFO','Supervisor','GLAccountant','BankAccountant','APAccountant'].includes(profile.role);
 const canResume=p=>reader()&&eligible(p)&&(p.accounting_registered_at?manager():profile.role==='GLAccountant');
 let context=null,busy=false,request=0;
 const messages={PENDING_STALE_RECORD_REFRESH:['تغيّرت العملية منذ فتحها. حدّث بياناتها وراجعها قبل المحاولة.','The payment changed. Refresh and review it before retrying.'],
  PENDING_REQUIRES_GL_REGISTRATION:['ينبغي أن يستكمل محاسب القيود التسجيل أولًا.','The GL accountant must complete registration first.'],
  PENDING_REQUIRES_SUPERVISOR_REVIEW:['رفع التعليق بعد التسجيل من اختصاص المشرف أو المدير المالي.','A supervisor or CFO must release a post-registration hold.'],
  PENDING_NOT_AUTHORIZED:['لا تملك صلاحية هذا الإجراء.','You do not have permission for this action.'],
  PENDING_RESOLUTION_NOTE_REQUIRED:['وثّق الحل بملاحظة من 10 إلى 2000 حرف.','Document the resolution in 10–2000 characters.'],
  PAYMENT_IS_NOT_ACTIVE_PENDING:['لم تعد العملية معلقة. حدّث القائمة لمراجعة حالتها.','This payment is no longer on hold. Refresh to see its state.'],
  PENDING_ACTIVE_FINANCE_OWNER_REQUIRED:['اختر مسؤول متابعة نشطًا من الفريق المالي المختص.','Choose an active finance follow-up owner.'],
  PENDING_FOLLOWUP_DATE_REQUIRED:['حدد موعد متابعة اليوم أو تاريخًا لاحقًا.','Choose today or a later follow-up date.'],
  PENDING_FOLLOWUP_DETAILS_REQUIRED:['أكمل الإجراء المطلوب وسبب تحديث المتابعة.','Complete the required action and the reason for changing follow-up.'],
  PENDING_VERSION_REQUIRED:['حدّث بيانات العملية قبل إتمام الإجراء.','Refresh the payment before continuing.'],
  PENDING_AMOUNT_REQUIRES_REVIEW:['بيانات المبلغ المعلق تحتاج مراجعة المدير المالي قبل رفع التعليق.','The held amount needs CFO review before release.']};
 function errorText(error){const message=String(error?.message||error||'');for(const [code,pair] of Object.entries(messages))if(message.includes(code))return T(...pair);return T('تعذر إتمام الإجراء. ','Could not complete the action. ')+message;}
 function showError(error){const box=$('pendingFlowError');if(box){box.textContent=errorText(error);box.hidden=false;}}
 pendingPaymentActions=function(p){
  if(!reader())return '—';const a=[];
  if(canResume(p))a.push(`<button class="btn success" data-pending-resume="${esc(p.id)}" onclick="openResolvePendingPayment('${esc(p.id)}')">${p.accounting_registered_at?T('رفع التعليق للمراجعة النهائية','Release hold for final review'):T('استكمال التسجيل','Complete registration')}</button>`);
  else if(eligible(p))a.push(`<span class="muted">${p.accounting_registered_at?T('بانتظار مراجعة المشرف','Awaiting supervisor review'):T('بانتظار محاسب القيود','Awaiting GL registration')}</span>`);
  if(manager()&&eligible(p))a.push(`<button class="btn" data-pending-followup="${esc(p.id)}" onclick="openPendingFollowup('${esc(p.id)}')">${T('تحديث المتابعة','Update follow-up')}</button>`);
  a.push(`<button class="btn" data-pending-history="${esc(p.id)}" onclick="openPendingHistory('${esc(p.id)}')">${T('سجل التعليق والمعالجة','Hold & resolution history')}</button>`);
  if(profile.role==='CFO')a.push(`<button class="btn" onclick="openCfoStatusOverride('${esc(p.id)}')">${T('إدارة الحالة بواسطة المدير المالي','CFO status controls')}</button>`);
  return `<div class="task-actions-wrap pending-flow-actions">${a.join(' ')}</div>`;
 };
 const previousPaymentActions=paymentActions;
 paymentActions=function(p){const original=previousPaymentActions(p);return reader()&&(p.pending_at||p.pending_resolved_at)?original+` <button class="btn" data-pending-history="${esc(p.id)}" onclick="openPendingHistory('${esc(p.id)}')">${T('سجل التعليق والمعالجة','Hold & resolution history')}</button>`:original;};
 openResolvePendingPayment=function(id){
  const p=payments.find(x=>x.id===id);if(!canResume(p)||busy)return;
  context={id,version:p.updated_at,user:profile.id,kind:'resume'};
  const registered=!!p.accounting_registered_at;
  showModal(registered?T('رفع التعليق بعد التسجيل','Release post-registration hold'):T('حل التعليق واستكمال التسجيل','Resolve hold and complete registration'),
   `<div id="pendingFlowModal"><div class="note">${esc(p.company)} — ${esc(p.beneficiary)}<br>${T('إجمالي العملية','Payment total')}: ${moneyHtml(p.amount)} · ${T('المبلغ المعلق','Held amount')}: ${moneyHtml(p.pending_amount)}<br>${T('سبب التعليق','Hold reason')}: ${esc(p.pending_reason||'—')}<br>${T('تفاصيل المشكلة','Problem details')}: ${esc(p.pending_details||'—')}</div><p>${registered?T('حُلّت المشكلة بعد تسجيل العملية. رفع التعليق يعيدها إلى المراجعة النهائية ويحفظ بيانات التسجيل الأصلية.','The problem was resolved after registration. Releasing the hold returns it for final review and preserves the original registration.'):T('بعد توثيق الحل سيُستكمل التسجيل وتُرسل العملية للمراجعة النهائية.','Document the resolution to complete registration and send the payment for final review.')}</p><label for="pend_resolution_note">${T('ما الذي عولج؟ اذكر المستند أو مرجع الحل','What was resolved? Include the document or resolution reference')}</label><textarea id="pend_resolution_note" rows="4" minlength="10" maxlength="2000"></textarea><div id="pendingFlowError" class="ops-error" role="alert" hidden></div><div class="pending-flow-footer"><button id="pendingFlowSave" class="btn success" onclick="resolvePendingPayment('${esc(id)}')">${registered?T('تأكيد رفع التعليق','Confirm hold release'):T('استكمال التسجيل وإرسالها للمراجعة','Complete registration & send for review')}</button><button class="btn" onclick="refreshPendingFlow()">${T('تحديث بيانات العملية','Refresh payment details')}</button></div></div>`);
 };
 window.refreshPendingFlow=async function(){if(!context||busy)return;const saved={...context},note=$('pend_resolution_note')?.value||'';busy=true;try{await reloadAll();}catch(e){showError(e);return;}finally{busy=false;}if(profile?.id!==saved.user)return;if(saved.kind==='resume'){openResolvePendingPayment(saved.id);if($('pend_resolution_note'))$('pend_resolution_note').value=note;}else openPendingFollowup(saved.id);};
 resolvePendingPayment=async function(id){
  if(busy||context?.kind!=='resume'||context.id!==id||context.user!==profile?.id||!$('pendingFlowModal'))return;
  const note=($('pend_resolution_note')?.value||'').trim();if(note.length<10){showError({message:'PENDING_RESOLUTION_NOTE_REQUIRED'});return;}
  busy=true;const state={...context},button=$('pendingFlowSave');button.disabled=true;
  try{
   const {error}=await sb.rpc('resume_pending_payment',{p_payment_id:id,p_resolution_note:note,p_expected_updated_at:state.version});if(error)throw error;
   if(profile?.id!==state.user)return;context=null;closeModal();await reloadAll();
   if(canPage('executed')){for(const key of ['executedFrom','executedTo'])if($(key))$(key).value='';if($('executedRegFilter'))$('executedRegFilter').value='registered';renderExecutedPayments();openPage('executed',T('المنفذة — بانتظار المراجعة النهائية','Executed — awaiting final review'));
    let message=$('pendingResumeFeedback');if(!message){message=document.createElement('div');message.id='pendingResumeFeedback';message.className='note';message.setAttribute('role','status');$('executed').prepend(message);}message.textContent=T('عادت العملية إلى المسجلة بانتظار المراجعة النهائية. الترحيل النهائي إجراء مستقل للمشرف أو المدير المالي.','Payment returned to registered status for final review. Final posting is a separate supervisor/CFO action.');}
  }catch(error){showError(error);}finally{busy=false;if(button.isConnected)button.disabled=false;}
 };
 window.openPendingFollowup=function(id){
  const p=payments.find(x=>x.id===id);if(!reader()||!manager()||!eligible(p)||busy)return;
  context={id,version:p.updated_at,user:profile.id,kind:'followup'};
  const owners=profiles.filter(u=>u.active!==false&&u.finance_team!==false&&['CFO','Supervisor','BankAccountant','GLAccountant','APAccountant'].includes(u.role));
  showModal(T('متابعة معالجة التعليق','Hold follow-up'),`<div id="pendingFlowModal"><div class="note">${esc(p.company)} — ${esc(p.beneficiary)}<br>${T('يبقى المبلغ معلقًا أثناء تحديث المتابعة.','The amount stays on hold while follow-up is updated.')}</div><div class="ops-fields"><label>${T('الإجراء المطلوب','Required action')}<input id="pendingFollowAction" maxlength="1000" value="${esc(p.pending_action||'')}"></label><label>${T('مسؤول المتابعة','Follow-up owner')}<select id="pendingFollowOwner"><option value="">—</option>${owners.map(u=>`<option value="${esc(u.id)}" ${u.id===p.pending_owner_id?'selected':''}>${esc(u.full_name)}</option>`).join('')}</select></label><label>${T('تاريخ المتابعة','Follow-up date')}<input id="pendingFollowDate" type="date" value="${esc(p.pending_follow_up_date||'')}"></label></div><label>${T('سبب تحديث المتابعة','Reason for follow-up change')}<textarea id="pendingFollowNote" rows="3" minlength="10" maxlength="2000"></textarea></label><div id="pendingFlowError" class="ops-error" role="alert" hidden></div><div class="pending-flow-footer"><button id="pendingFlowSave" class="btn primary" onclick="savePendingFollowup()">${T('حفظ المتابعة','Save follow-up')}</button><button class="btn" onclick="refreshPendingFlow()">${T('تحديث بيانات العملية','Refresh payment details')}</button></div></div>`);
 };
 window.savePendingFollowup=async function(){
  if(busy||context?.kind!=='followup'||context.user!==profile?.id||!$('pendingFlowModal'))return;
  const action=val('pendingFollowAction').trim(),note=val('pendingFollowNote').trim(),owner=val('pendingFollowOwner'),date=val('pendingFollowDate');
  if(action.length<3||note.length<10||!owner||!date){showError({message:T('أكمل الإجراء والمسؤول والموعد وسببًا من عشرة أحرف على الأقل.','Enter the action, owner, date and a reason of at least ten characters.')});return;}
  busy=true;const state={...context},button=$('pendingFlowSave');button.disabled=true;
  try{const {error}=await sb.rpc('update_pending_payment_followup',{p_payment_id:state.id,p_required_action:action,p_owner_id:owner,p_follow_up_date:date,p_change_note:note,p_expected_updated_at:state.version});if(error)throw error;if(profile?.id!==state.user)return;context=null;closeModal();await reloadAll();}catch(error){showError(error);}finally{busy=false;if(button.isConnected)button.disabled=false;}
 };
 window.openPendingHistory=async function(id){
  if(!reader()||!payments.some(p=>p.id===id))return;
  const token=++request,user=profile.id;
  showModal(T('سجل التعليق والمعالجة','Hold & resolution history'),`<div id="pendingHistory" class="task-thread" role="status">${T('جارٍ تحميل آخر 50 حدثًا…','Loading the latest 50 events…')}</div>`);
  try{const {data,error}=await sb.rpc('get_pending_payment_history',{p_payment_id:id});if(error)throw error;if(token!==request||user!==profile?.id||!$('pendingHistory'))return;
   $('pendingHistory').innerHTML=(data||[]).map(event=>{const d=event.details||{};let title=event.action==='PAYMENT_PENDING_RESOLVED'?T('حل التعليق وإعادة العملية للمراجعة','Hold resolved; returned for review'):event.action==='PAYMENT_PENDING_FOLLOWUP_UPDATED'?T('تحديث مسؤول وخطة المتابعة','Follow-up plan updated'):T('تعليق العملية','Payment placed on hold');
    return `<article class="task-thread-item"><div class="task-thread-meta">${esc(fmt(event.created_at))} · ${esc(event.actor_name||'—')}</div><b>${title}</b><p>${esc(d.resolution_note||d.change_note||d.reason||'—')}</p>${d.previous_pending_amount!=null||d.pending_amount!=null?`<div>${T('المبلغ المعلق قبل الإجراء','Held amount before action')}: ${moneyHtml(d.previous_pending_amount??d.pending_amount)}</div>`:''}${d.details?`<p>${esc(d.details)}</p>`:''}${d.required_action?`<p>${T('الإجراء المطلوب','Required action')}: ${esc(d.required_action)}</p>`:''}</article>`;}).join('')||T('لا توجد أحداث تعليق مسجلة لهذه العملية.','No hold events are recorded for this payment.');
  }catch(error){if(token===request&&user===profile?.id&&$('pendingHistory'))$('pendingHistory').textContent=errorText(error);}
 };
})();
