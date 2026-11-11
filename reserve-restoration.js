/* Operational reserve entry lives on Home; balances remain under CFO control. */
(() => {
 'use strict';const text=(ar,en)=>currentLang==='en'?en:ar;
 let state=null;
 const allowed=()=>['Supervisor','BankAccountant'].includes(profile?.role)&&canBankBalances();
 function postingFields(destination){
  return `<div class="modal-grid">${select('rrPostingMode',text('أثر الاسترداد على الأرصدة','Restoration balance effect'),[
   {value:'',label:text('حدد أثر الاسترداد','Choose the balance effect')},
   {value:'External',label:text('إيداع من خارج الحسابات المسجلة','Deposit from outside tracked accounts')},
   {value:'Internal',label:text('تحويل من حساب بنكي مسجل','Transfer from a tracked bank account')},
   {value:'Already reflected',label:text('الأثر مسجل بالفعل في الأرصدة','Already reflected in balances')}
  ])}<div id="rrSourceGroup" class="hidden">${select('rrSourceBank',text('الحساب المحوّل منه','Source bank account'),[
   {value:'',label:'—'},...banks.filter(bank=>bank.id!==destination).map(bank=>({
    value:bank.id,label:`${bank.company} — ${bank.bank_name} — ${bank.account_name}`
   }))
  ])}</div></div>`;
 }
 function bindPostingFields(validate){
  const mode=document.getElementById('rrPostingMode'),source=document.getElementById('rrSourceBank');
  mode.onchange=()=>{
   document.getElementById('rrSourceGroup').classList.toggle('hidden',mode.value!=='Internal');
   validate();
  };
  source.onchange=validate;
 }
 const postingSelected=()=>Boolean(val('rrPostingMode')&&(val('rrPostingMode')!=='Internal'||val('rrSourceBank')));
 const postingArgs=()=>({p_mode:val('rrPostingMode'),p_source_bank_account_id:val('rrPostingMode')==='Internal'?val('rrSourceBank'):null});
 const originalOpen=openReserveMovement;
 openReserveMovement=async function(bankId,type){
  if(!allowed()||document.querySelector('.section.active')?.id!=='dashboard')return;
  if(type==='Support Draw')return originalOpen(bankId,type);
  const bank=banks.find(b=>b.id===bankId);if(!bank||!isProtectedBank(bank))return;
  const user=profile.id,{data,error}=await sb.rpc('get_recoverable_reserve_uses',{p_bank_account_id:bankId});if(profile?.id!==user)return;if(error)return alert(error.message);
  const uses=data||[];if(!uses.length)return alert(text('لا توجد مبالغ مطلوبة الاستعادة.','No outstanding recoveries.'));
  state={bankId,user,uses,request:crypto.randomUUID(),busy:false};
  showModal(text('استعادة واحدة · توزيع مرن','One restoration · flexible allocation'),`<p class="muted">${esc(bank.bank_name)} — ${esc(bank.account_name)}</p><div class="note">${text('وزّع مبلغ الاسترداد على الحركات المستحقة، وحدد أثره على رصيد الاحتياطي والحساب المحوّل منه.','Allocate the receipt to outstanding items and choose the balance effect for the reserve and source accounts.')}</div><div class="modal-grid" style="margin-top:14px">${input('rrAmount',text('المبلغ المستعاد','Receipt amount'),0,'number')}${input('rrDate',text('التاريخ','Date'),riyadhToday(),'date')}</div>${postingFields(bankId)}<button id="rrSuggest" class="btn" type="button">${text('اقتراح توزيع الأقدم أولًا','Suggest oldest first')}</button><div class="table-wrap" style="margin-top:12px"><table class="pf-allocation-table"><thead><tr><th>${text('المبلغ المطلوب استعادته','Recovery item')}</th><th>${text('المتبقي','Outstanding')}</th><th>${text('التخصيص','Allocate')}</th></tr></thead><tbody>${uses.map((u,i)=>`<tr><td style="white-space:normal">${esc(u.use_date)} · ${esc(u.note||u.source_type)}</td><td>${moneyHtml(u.outstanding_amount)}</td><td><input data-recovery-index="${i}" type="number" min="0" max="${Number(u.outstanding_amount)}" step="0.01" value="0" aria-label="${esc(text('تخصيص','Allocate')+' '+(u.note||u.source_type))}"></td></tr>`).join('')}</tbody></table></div><div id="rrTotal" role="status" aria-live="polite" style="margin:12px 0"></div><label for="rrNote">${text('ملاحظة','Note')}</label><textarea id="rrNote"></textarea><div id="rrError" class="wc-error hidden" role="alert"></div><button id="rrSave" class="btn primary" type="button" style="margin-top:14px">${text('تسجيل الاستعادة','Record restoration')}</button>`);
  function cents(value){const n=Number(value);return Number.isFinite(n)&&n>=0&&Math.abs(n*100-Math.round(n*100))<0.00001?Math.round(n*100):null;}
  function amounts(){return [...document.querySelectorAll('[data-recovery-index]')].map(el=>({el,c:cents(el.value),u:uses[Number(el.dataset.recoveryIndex)]}));}
  function validate(){const receipt=cents(document.getElementById('rrAmount').value),rows=amounts(),total=rows.reduce((sum,r)=>sum+(r.c||0),0),valid=postingSelected()&&receipt>0&&rows.every(r=>r.c!==null&&r.c<=Math.round(Number(r.u.outstanding_amount)*100))&&total===receipt;document.getElementById('rrTotal').textContent=`${text('الموزع','Allocated')}: ${money(total/100)} · ${text('غير الموزع','Unallocated')}: ${money(((receipt||0)-total)/100)}`;document.getElementById('rrSave').disabled=state?.busy||!valid;return valid;}
  bindPostingFields(validate);
  document.getElementById('rrAmount').addEventListener('input',validate);amounts().forEach(r=>r.el.addEventListener('input',validate));
  document.getElementById('rrSuggest').onclick=()=>{let left=cents(document.getElementById('rrAmount').value)||0;for(const r of amounts()){const c=Math.min(left,Math.round(Number(r.u.outstanding_amount)*100));r.el.value=(c/100).toFixed(2);left-=c;}validate();};
  document.getElementById('rrSave').onclick=async()=>{const current=state;if(!current||current.busy||current.user!==profile?.id||!allowed()||!validate())return;current.busy=true;validate();const allocations=amounts().filter(r=>r.c>0).map(r=>({source_type:r.u.source_type,source_id:r.u.source_id,amount:r.c/100}));try{const {error}=await sb.rpc('record_reserve_restoration_v4',{p_bank_account_id:current.bankId,p_amount:cents(document.getElementById('rrAmount').value)/100,p_movement_date:document.getElementById('rrDate').value,p_note:document.getElementById('rrNote').value,p_allocations:allocations,p_request_id:current.request,...postingArgs()});if(error)throw error;if(profile?.id!==current.user)return;state=null;closeModal();await reloadAll();}catch(e){if(state===current&&profile?.id===current.user){const box=document.getElementById('rrError');if(box){box.textContent=e.message;box.classList.remove('hidden');}}}finally{current.busy=false;if(state===current&&document.getElementById('rrSave'))validate();}};validate();
 };
 const previousReport=previewReserveReport;
 previewReserveReport=async function(){
  await previousReport();
  if(profile?.role!=='CFO'||val('rr_type')!=='movements')return;
  document.querySelectorAll('#reserveReportOutput tbody tr').forEach((row,index)=>{
   const movement=reserveReportRows[index];
   if(movement?.movement_type!=='Restoration')return;
   const button=document.createElement('button');
   button.type='button';button.className='btn';
   button.textContent=text('تسوية الأثر البنكي','Reconcile bank effect');
   button.onclick=()=>openRestorationReconciliation(movement);
   row.lastElementChild.replaceChildren(button);
  });
 };
 function openRestorationReconciliation(movement){
  if(profile?.role!=='CFO')return;
  showModal(text('تسوية أثر الاسترداد','Reconcile restoration'),`
   <p>${esc(movement.movement_date)} · ${esc(movement.account_name)} · ${moneyHtml(movement.amount)}</p>
   <p class="note">${text('طابق الحركة مع كشف البنك والأرصدة المسجلة، ثم اختر الأثر المناسب.','Match the receipt against the bank statement and recorded balances, then select the balance effect.')}</p>
   ${postingFields(movement.bank_account_id)}
   <label for="rrReconcileReason">${text('سبب التسوية ومرجع المطابقة','Reason and reconciliation reference')}</label>
   <textarea id="rrReconcileReason"></textarea>
   <div id="rrReconcileError" role="alert"></div>
   <button id="rrReconcileSave" type="button" class="btn primary" disabled>${text('حفظ التسوية','Save reconciliation')}</button>`);
  const save=document.getElementById('rrReconcileSave'),reason=document.getElementById('rrReconcileReason');
  const errorBox=document.getElementById('rrReconcileError');
  let busy=false;
  const validate=()=>{save.disabled=busy||!postingSelected()||!reason.value.trim();};
  bindPostingFields(validate);
  reason.addEventListener('input',validate);
  save.onclick=async()=>{
   if(busy||!postingSelected()||!reason.value.trim()||profile?.role!=='CFO')return;
   busy=true;validate();
   try{
    const {error}=await sb.rpc('cfo_reconcile_reserve_restoration',{
     p_movement_id:movement.reference,...postingArgs(),p_reason:reason.value.trim()
    });
    if(error)throw error;
    closeModal();await reloadAll();
   }catch(error){
    errorBox.textContent=error.message==='RESERVE_RESTORATION_ALREADY_RECONCILED'
     ?text('سبق تسوية الأثر البنكي لهذه الحركة.','The bank effect of this receipt has already been reconciled.')
     :error.message;
   }finally{busy=false;validate();}
  };
 }
 const previousBankModal=openBankModal;
 openBankModal=function(id=''){const result=previousBankModal(id);setTimeout(()=>{const bank=banks.find(b=>b.id===id);if(profile?.role!=='CFO'&&bank&&isProtectedBank(bank))for(const key of ['b_balance','b_target','b_type']){const input=document.getElementById(key);if(input){input.disabled=true;input.title=text('تعديل المدير المالي فقط','CFO edits only');}}},0);return result;};
})();
