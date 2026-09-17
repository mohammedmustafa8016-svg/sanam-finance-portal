from pathlib import Path
import re

p=Path('index.html')
s=p.read_text(encoding='utf-8')

if '/* IMPREST_EDIT_DELETE_V33_2026_09_17 */' not in s:
    s=s.replace('/* PAYMENT_IMPREST_WORKFLOW_V32_2026_09_17 */','/* PAYMENT_IMPREST_WORKFLOW_V32_2026_09_17 */\n/* IMPREST_EDIT_DELETE_V33_2026_09_17 */',1)

old_render="""function renderImprest(){imprestBody.innerHTML=imprest.map(x=>{const sm=imprestSummaryFor(x.id);const canOpen=['CFO','Supervisor','BankAccountant','APAccountant'].includes(profile.role);return `<tr><td>${esc(x.type)}</td><td>${esc(x.company)}</td><td>${esc(x.name)}</td><td>${esc(x.custodian?.full_name||'—')}</td><td>${moneyHtml(x.balance)}</td><td>${moneyHtml(x.unsettled)}</td><td>${moneyHtml(sm.under_settlement||0)}</td><td>${moneyHtml(sm.available_to_settle||0)}</td><td>${moneyHtml(sm.approved_settlements||0)}</td><td>${Number(x.aging||0)} يوم</td><td>${badge(x.status)}</td><td>${canOpen?`<button class=\"btn primary\" onclick=\"openImprestSettlementModal('${x.id}')\">${displayText('فتح تصفية عهدة')}</button>`:'—'}</td></tr>`}).join('')||`<tr><td colspan=\"12\" class=\"muted\">${displayText('لا توجد عهد مسجلة حتى الآن.')}</td></tr>`;applyTableFilters(document.getElementById('imprestTable'))}"""
new_render="""function renderImprest(){imprestBody.innerHTML=imprest.map(x=>{const sm=imprestSummaryFor(x.id);const canOpen=['CFO','Supervisor','BankAccountant','APAccountant'].includes(profile.role),canManage=['CFO','Supervisor'].includes(profile.role);const actions=[];if(canOpen)actions.push(`<button class=\"btn primary\" onclick=\"openImprestSettlementModal('${x.id}')\">${displayText('فتح تصفية عهدة')}</button>`);if(canManage){actions.push(`<button class=\"btn\" onclick=\"openImprestModal('${x.id}')\">${displayText('تعديل')}</button>`);actions.push(`<button class=\"btn danger\" onclick=\"deleteImprest('${x.id}')\">${displayText('حذف')}</button>`)}return `<tr><td>${esc(x.type)}</td><td>${esc(x.company)}</td><td>${esc(x.name)}</td><td>${esc(x.custodian?.full_name||'—')}</td><td>${moneyHtml(x.balance)}</td><td>${moneyHtml(x.unsettled)}</td><td>${moneyHtml(sm.under_settlement||0)}</td><td>${moneyHtml(sm.available_to_settle||0)}</td><td>${moneyHtml(sm.approved_settlements||0)}</td><td>${Number(x.aging||0)} يوم</td><td>${badge(x.status)}</td><td><div class=\"task-actions-wrap\">${actions.join(' ')||'—'}</div></td></tr>`}).join('')||`<tr><td colspan=\"12\" class=\"muted\">${displayText('لا توجد عهد مسجلة حتى الآن.')}</td></tr>`;applyTableFilters(document.getElementById('imprestTable'))}"""
if old_render not in s:
    raise SystemExit('renderImprest anchor not found')
s=s.replace(old_render,new_render,1)

# Restore/create the account modal and convert save to create-or-edit through governed RPC for edits.
old_save=re.search(r'async function saveImprest\(\)\{[^\n]*\}',s)
if not old_save:
    raise SystemExit('saveImprest anchor not found')
replacement=r'''function openImprestModal(id=''){
 const editing=!!id,f=editing?imprest.find(x=>x.id===id):null;
 if(editing&&!['CFO','Supervisor'].includes(profile.role))return;
 if(!editing&&!['CFO','Supervisor','BankAccountant','APAccountant'].includes(profile.role))return;
 if(editing&&!f)return;
 showModal(editing?displayText('تعديل عهدة'):displayText('إضافة عهدة'),`<div class="modal-grid">${select('i_type','النوع',['عامة','مشروع'])}${input('i_company','الشركة',f?.company||'')}${input('i_name','اسم العهدة',f?.name||'')}${select('i_custodian','المسؤول',[{value:'',label:'—'},...profiles.map(x=>({value:x.id,label:x.full_name}))])}${input('i_balance','الرصيد',f?.balance??0,'number')}${input('i_unsettled','غير مسوى',f?.unsettled??0,'number')}${input('i_aging','العمر بالأيام',f?.aging??0,'number')}${select('i_status','الحالة',['سليمة','تحتاج تسوية','متأخرة'])}</div><div class="row" style="margin-top:14px"><button class="btn primary" onclick="saveImprest('${id}')">${displayText('حفظ')}</button></div>`);
 setTimeout(()=>{const t=document.getElementById('i_type'),c=document.getElementById('i_custodian'),st=document.getElementById('i_status');if(t)t.value=f?.type||'عامة';if(c)c.value=f?.custodian_id||'';if(st)st.value=f?.status||'سليمة'},0)
}
async function saveImprest(id=''){
 const payload={p_type:val('i_type'),p_company:val('i_company'),p_name:val('i_name'),p_custodian_id:val('i_custodian')||null,p_balance:Number(val('i_balance')||0),p_unsettled:Number(val('i_unsettled')||0),p_aging:Number(val('i_aging')||0),p_status:val('i_status')};
 if(!payload.p_company.trim()||!payload.p_name.trim())return alert(currentLang==='en'?'Company and imprest name are required.':'الشركة واسم العهدة حقول إلزامية.');
 if(payload.p_balance<0||payload.p_unsettled<0||payload.p_aging<0)return alert(currentLang==='en'?'Balance, unsettled amount and aging cannot be negative.':'لا يمكن أن تكون قيم الرصيد أو غير المسوى أو العمر سالبة.');
 let error;
 if(id){({error}=await sb.rpc('update_imprest_fund',{p_fund_id:id,...payload}))}
 else{const createPayload={type:payload.p_type,company:payload.p_company,name:payload.p_name,custodian_id:payload.p_custodian_id,balance:payload.p_balance,unsettled:payload.p_unsettled,aging:payload.p_aging,status:payload.p_status,created_by:profile.id};({error}=await sb.from('imprest_funds').insert(createPayload))}
 if(error)return alert(imprestErrorMessage(error.message));closeModal();await reloadAll();openPage('imprest',displayText('العهد'))
}
function imprestErrorMessage(message=''){const m=String(message);if(m.includes('IMPREST_HAS_SETTLEMENT_HISTORY'))return currentLang==='en'?'This imprest account cannot be deleted because it has settlement history.':'لا يمكن حذف حساب العهدة لوجود ملفات تصفية مرتبطة به.';if(m.includes('IMPREST_HAS_OPEN_BALANCE'))return currentLang==='en'?'This imprest account cannot be deleted while it has a balance or unsettled amount.':'لا يمكن حذف حساب العهدة طالما يوجد رصيد أو مبلغ غير مسوى.';if(m.includes('NOT_AUTHORIZED'))return currentLang==='en'?'You are not authorized for this action.':'ليس لديك صلاحية لتنفيذ هذا الإجراء.';return m}
async function deleteImprest(id){if(!['CFO','Supervisor'].includes(profile.role))return;const f=imprest.find(x=>x.id===id);if(!f)return;const ok=confirm(currentLang==='en'?`Delete imprest account "${f.name}"? This is only allowed when the balance is zero and there is no settlement history.`:`هل تريد حذف حساب العهدة «${f.name}»؟ يسمح بالحذف فقط إذا كان الرصيد صفرًا ولا توجد له ملفات تصفية.`);if(!ok)return;const {error}=await sb.rpc('delete_imprest_fund',{p_fund_id:id});if(error)return alert(imprestErrorMessage(error.message));await reloadAll();openPage('imprest',displayText('العهد'))}'''
s=s[:old_save.start()]+replacement+s[old_save.end():]

# Translation terms used by the restored edit modal.
needle='Object.assign(I18N_AR_EN,{"الاعتمادات المنفذة"'
if needle in s and '"تعديل عهدة":"Edit Imprest"' not in s:
    s=s.replace(needle,'Object.assign(I18N_AR_EN,{"تعديل عهدة":"Edit Imprest","حذف العهدة":"Delete Imprest","الاعتمادات المنفذة"',1)

p.write_text(s,encoding='utf-8')
