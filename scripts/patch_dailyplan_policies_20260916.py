from pathlib import Path

p=Path('index.html')
s=p.read_text()
marker='/* DAILY_PLAN_POLICIES_2026_09_16 */'
if marker in s:
    print('already patched'); raise SystemExit(0)

s=s.replace('/* CFO_CONTROLS_RESERVE_RECOVERY_2026_09_16 */','/* CFO_CONTROLS_RESERVE_RECOVERY_2026_09_16 */\n'+marker,1)

old_section='<section id="exceptions" class="section"><div class="row" style="margin-bottom:12px"><h3>الاستثناءات والإجازات</h3><button id="addExceptionBtn" class="btn primary" type="button" onclick="openExceptionModal()">+ إضافة استثناء</button></div><div id="exceptionsList"></div></section>'
new_section='''<section id="exceptions" class="section"><div class="row" style="margin-bottom:12px"><h3>الاستثناءات والإجازات</h3><div class="lang-actions"><button id="addExceptionBtn" class="btn primary" type="button" onclick="openExceptionModal()">+ إضافة استثناء</button><button id="addPolicyBtn" class="btn primary" type="button" onclick="openPolicyModal()">+ إضافة سياسة</button></div></div><div class="saved-views" style="margin-bottom:12px"><button id="exceptionsTabBtn" class="view-chip active" onclick="switchExceptionsTab('exceptions')">الاستثناءات والإجازات</button><button id="policiesTabBtn" class="view-chip" onclick="switchExceptionsTab('policies')">سياسات الإدارة المالية</button></div><div id="exceptionsPanel"><div id="exceptionsList"></div></div><div id="policiesPanel" class="hidden"><div class="note" style="margin-bottom:12px">السياسات الفعالة ملزمة لفريق الإدارة المالية. يظهر لكل موظف ما إذا كان قد أقر بالاطلاع على النسخة الحالية، وأي تعديل جوهري ينشئ إصدارًا جديدًا يتطلب إقرارًا جديدًا.</div><div id="policiesList"></div></div></section>'''
assert old_section in s, 'exceptions section not found'
s=s.replace(old_section,new_section,1)

s=s.replace('reserveAccounts=[];let activeTaskView=', 'reserveAccounts=[],financePolicies=[];let activeTaskView=',1)

old_access='addExceptionBtn.classList.toggle("hidden",profile.role!=="CFO");addCloseBtn.classList.toggle'
new_access='addExceptionBtn.classList.toggle("hidden",profile.role!=="CFO");addPolicyBtn?.classList.toggle("hidden",profile.role!=="CFO");addCloseBtn.classList.toggle'
assert old_access in s, 'applyAccess marker not found'
s=s.replace(old_access,new_access,1)

old_reload='const rr=await sb.rpc("get_reserve_account_monitor");reserveAccounts=rr.data||[];if(["CFO","Supervisor"].includes(profile.role))'
new_reload='const rr=await sb.rpc("get_reserve_account_monitor");reserveAccounts=rr.data||[];const pol=await sb.rpc("get_finance_policy_register");financePolicies=pol.data||[];if(["CFO","Supervisor"].includes(profile.role))'
assert old_reload in s, 'reload marker not found'
s=s.replace(old_reload,new_reload,1)

old_render='function renderAll(){renderBanks();renderPayments();renderSavedViews();renderTasks();renderControlCenter();renderWorkload();renderEscalations();renderAutomationHealth();renderClose();renderImprest();renderPerformance();renderOwnership();renderExceptions();renderDashboard();installUniversalColumnCustomizers();installTableFilters();applyLanguage()}'
new_render='function renderAll(){renderBanks();renderPayments();renderSavedViews();renderTasks();renderControlCenter();renderWorkload();renderEscalations();renderAutomationHealth();renderClose();renderImprest();renderPerformance();renderOwnership();renderExceptions();renderPolicies();renderDashboard();installUniversalColumnCustomizers();installTableFilters();applyLanguage()}'
assert old_render in s, 'renderAll not found'
s=s.replace(old_render,new_render,1)

# Replace daily plan UI with default daily + optional non-daily + ad-hoc/catalog while keeping default-task workflow intact.
start=s.index('function openDailyPlan(){')
end=s.index('\nasync function startTask',start)
new_daily=r'''async function openDailyPlan(){
 if(!["Supervisor","CFO"].includes(profile.role))return;
 const today=riyadhToday();
 const dailyRows=tasks.filter(t=>t.frequency==='يومي'&&t.due_date===today&&t.status!=="مكتمل");
 const otherRows=tasks.filter(t=>t.frequency!=='يومي'&&t.status!=="مكتمل");
 const {data:catalog,error:catalogError}=await sb.from('finance_task_catalog').select('id,name,default_owner_id,default_priority,output').eq('active',true).order('name');
 if(catalogError)return alert(catalogError.message);
 const ownerOpts=profiles.map(x=>`<option value="${x.id}">${esc(x.full_name)}</option>`).join('');
 const dailyHtml=dailyRows.map(t=>`<tr><td><input type="checkbox" class="plan-default-check" data-id="${t.id}" checked></td><td>${esc(t.owner?.full_name||'—')}</td><td style="white-space:normal">${esc(t.name)}</td><td>${badge(t.priority||'عادي')}</td><td><input type="time" class="plan-default-time" data-id="${t.id}" value="${t.due_time?String(t.due_time).slice(0,5):''}"></td></tr>`).join('')||`<tr><td colspan="5" class="muted">${currentLang==='en'?'No default daily tasks for today.':'لا توجد مهام يومية افتراضية لليوم.'}</td></tr>`;
 const otherHtml=otherRows.map(t=>`<tr><td><input type="checkbox" class="plan-extra-check" data-id="${t.id}"></td><td style="white-space:normal">${esc(t.name)}</td><td><select class="plan-extra-owner" data-id="${t.id}">${profiles.map(x=>`<option value="${x.id}" ${x.id===t.owner_id?'selected':''}>${esc(x.full_name)}</option>`).join('')}</select></td><td><select class="plan-extra-priority" data-id="${t.id}">${['عادي','عاجل','حرج','عالي','متوسط','منخفض'].map(v=>`<option value="${v}" ${v===(t.priority||'عادي')?'selected':''}>${displayText(v)}</option>`).join('')}</select></td><td><input type="time" class="plan-extra-time" data-id="${t.id}" value="${t.due_time?String(t.due_time).slice(0,5):''}"></td></tr>`).join('')||`<tr><td colspan="5" class="muted">${currentLang==='en'?'No other open tasks.':'لا توجد مهام أخرى مفتوحة.'}</td></tr>`;
 const catalogOpts=[`<option value="">${currentLang==='en'?'— New ad-hoc task —':'— مهمة جديدة لليوم —'}</option>`].concat((catalog||[]).map(x=>`<option value="${x.id}">${esc(x.name)}</option>`)).join('');
 showModal(displayText('خطة اليوم / فتح المهام'),`<div class="note" style="margin-bottom:10px">${currentLang==='en'?'Default daily tasks remain under the existing workflow. You may also add other open tasks or create an ad-hoc task for today.':'المهام اليومية الافتراضية تظل تحت نفس آلية العمل الحالية. ويمكن أيضًا اختيار مهام أخرى مفتوحة أو إضافة مهمة خاصة باليوم.'}</div><h4>${currentLang==='en'?'Default daily tasks':'المهام اليومية الافتراضية'}</h4><div class="table-wrap"><table class="plan-table"><thead><tr><th>✓</th><th>${displayText('المسؤول')}</th><th>${displayText('المهمة')}</th><th>${displayText('الأولوية')}</th><th>${displayText('الوقت')}</th></tr></thead><tbody>${dailyHtml}</tbody></table></div><h4 style="margin-top:16px">${currentLang==='en'?'Other available tasks':'مهام أخرى متاحة لليوم'}</h4><div class="table-wrap"><table class="plan-table"><thead><tr><th>✓</th><th>${displayText('المهمة')}</th><th>${displayText('المسؤول')}</th><th>${displayText('الأولوية')}</th><th>${displayText('الوقت')}</th></tr></thead><tbody>${otherHtml}</tbody></table></div><h4 style="margin-top:16px">${currentLang==='en'?'Add an ad-hoc task':'إضافة مهمة خاصة باليوم'}</h4><div class="modal-grid"><div><label>${currentLang==='en'?'Reusable template':'اختيار من قوالب المهام'}</label><select id="plan_catalog" onchange='applyDailyPlanCatalog(${JSON.stringify(catalog||[]).replace(/'/g,"&#39;")})'>${catalogOpts}</select></div>${input('plan_new_name','المهمة')}${select('plan_new_owner','المسؤول',profiles.map(x=>({value:x.id,label:x.full_name})))}${select('plan_new_priority','الأولوية',['عادي','عاجل','حرج','عالي','متوسط','منخفض'])}${input('plan_new_time','الوقت','','time')}${input('plan_new_output','المخرج')}</div>${profile.role==='CFO'?`<label style="margin-top:10px;display:flex;gap:8px;align-items:center"><input id="plan_save_template" type="checkbox" style="width:auto"> ${currentLang==='en'?'Save this new task as a reusable template':'حفظ المهمة الجديدة كقالب قابل لإعادة الاستخدام'}</label>`:''}<div class="row" style="margin-top:14px"><button class="btn success" onclick="saveDailyPlan()">${currentLang==='en'?'Save and release plan':'حفظ وفتح خطة اليوم'}</button></div>`)
}
function applyDailyPlanCatalog(catalog){
 const id=val('plan_catalog');if(!id)return;const x=(catalog||[]).find(r=>r.id===id);if(!x)return;
 document.getElementById('plan_new_name').value=x.name||'';document.getElementById('plan_new_owner').value=x.default_owner_id||'';document.getElementById('plan_new_priority').value=x.default_priority||'عادي';document.getElementById('plan_new_output').value=x.output||'';
}
async function saveDailyPlan(){
 const defaults=[],flex=[];
 document.querySelectorAll('.plan-default-check:checked').forEach(c=>{const id=c.dataset.id,time=document.querySelector(`.plan-default-time[data-id="${id}"]`)?.value||'';defaults.push({id,due_time:time})});
 document.querySelectorAll('.plan-extra-check:checked').forEach(c=>{const id=c.dataset.id,time=document.querySelector(`.plan-extra-time[data-id="${id}"]`)?.value||'',owner_id=document.querySelector(`.plan-extra-owner[data-id="${id}"]`)?.value||'',priority=document.querySelector(`.plan-extra-priority[data-id="${id}"]`)?.value||'عادي';flex.push({id,owner_id,due_time:time,priority})});
 const name=(val('plan_new_name')||'').trim();if(name){flex.push({name,owner_id:val('plan_new_owner'),priority:val('plan_new_priority')||'عادي',due_time:val('plan_new_time'),output:val('plan_new_output')||null,save_as_template:profile.role==='CFO'&&!!document.getElementById('plan_save_template')?.checked})}
 if(!defaults.length&&!flex.length)return alert(currentLang==='en'?'Select or add at least one task.':'حدد أو أضف مهمة واحدة على الأقل.');
 if(defaults.some(x=>!x.due_time)||flex.some(x=>!x.due_time))return alert(currentLang==='en'?'Due time is required for every selected task.':'يجب تحديد وقت الاستحقاق لكل مهمة محددة.');
 if(flex.some(x=>!x.owner_id))return alert(currentLang==='en'?'Owner is required for every additional task.':'يجب تحديد المسؤول لكل مهمة إضافية.');
 const {data,error}=await sb.rpc('save_enhanced_daily_plan',{p_default_items:defaults,p_flexible_items:flex});if(error)return alert(error.message);closeModal();await reloadAll();alert(currentLang==='en'?`${data?.total||0} tasks released.`:`تم فتح ${data?.total||0} مهمة ضمن خطة اليوم.`)
}'''
s=s[:start]+new_daily+s[end:]

# Finance policies register UI, version control and acknowledgements.
insert_at=s.index('async function loadAudit()')
policy_js=r'''
function switchExceptionsTab(tab){
 const isPolicies=tab==='policies';document.getElementById('exceptionsPanel')?.classList.toggle('hidden',isPolicies);document.getElementById('policiesPanel')?.classList.toggle('hidden',!isPolicies);document.getElementById('exceptionsTabBtn')?.classList.toggle('active',!isPolicies);document.getElementById('policiesTabBtn')?.classList.toggle('active',isPolicies);if(isPolicies)renderPolicies()
}
function policyStatusBadge(status){const cls=status==='Active'?'green':status==='Suspended'?'amber':status==='Archived'?'red':'';return `<span class="badge ${cls}">${esc(displayText(status))}</span>`}
function renderPolicies(){
 const box=document.getElementById('policiesList');if(!box)return;
 box.innerHTML=(financePolicies||[]).map(p=>{const ack=p.acknowledged_current?`<span class="badge green">${displayText('تم الإقرار')}</span>`:`<span class="badge amber">${displayText('بانتظار الإقرار')}</span>`;const compliance=profile.role==='CFO'?`<span class="muted">${displayText('إقرارات النسخة الحالية')}: ${Number(p.acknowledged_count||0)}/${Number(p.active_team_count||0)}</span>`:'';return `<div class="card" style="margin-bottom:10px"><div class="row"><div><b>${esc(p.policy_code)} — ${esc(p.title)}</b><div class="muted">${esc(p.category)} | ${displayText('الإصدار')} ${p.current_version}.0 | ${displayText('تاريخ السريان')}: ${esc(p.effective_date||'—')}</div></div><div class="lang-actions">${policyStatusBadge(p.status)}${p.status==='Active'?ack:''}</div></div><div style="margin-top:8px;white-space:normal">${esc(p.purpose||p.policy_text||'')}</div><div class="row" style="margin-top:10px"><div>${compliance}</div><div class="lang-actions"><button class="btn" onclick="viewPolicy('${p.id}')">${displayText('عرض التفاصيل')}</button><button class="btn" onclick="viewPolicyVersions('${p.id}')">${displayText('سجل الإصدارات')}</button>${p.status==='Active'&&!p.acknowledged_current?`<button class="btn success" onclick="acknowledgePolicy('${p.id}')">${displayText('اطلعت وألتزم')}</button>`:''}${profile.role==='CFO'?`<button class="btn" onclick="openPolicyModal('${p.id}')">${displayText('تعديل')}</button>${p.status!=='Active'?`<button class="btn success" onclick="changePolicyStatus('${p.id}','Active')">${displayText('تفعيل')}</button>`:''}${p.status==='Active'?`<button class="btn" onclick="changePolicyStatus('${p.id}','Suspended')">${displayText('تعليق')}</button>`:''}${p.status!=='Archived'?`<button class="btn" onclick="changePolicyStatus('${p.id}','Archived')">${displayText('أرشفة')}</button>`:''}`:''}</div></div></div>`}).join('')||`<div class="muted">${currentLang==='en'?'No finance policies have been published yet.':'لا توجد سياسات مالية منشورة حتى الآن.'}</div>`;applyLanguage(box)
}
function policyCategories(){return ['عام','المدفوعات','البنوك','المبيعات والتحصيل','الموردون','الإقفال الشهري','العهد','المصروفات','المستندات','الصلاحيات','التقارير','الحضور والتسليم']}
function openPolicyModal(id=''){
 if(profile.role!=='CFO')return;const p=id?financePolicies.find(x=>x.id===id):null;
 showModal(p?'تعديل سياسة الإدارة المالية':'إضافة سياسة الإدارة المالية',`<div class="modal-grid">${input('pol_code','رمز السياسة',p?.policy_code||'')}${input('pol_title','عنوان السياسة',p?.title||'')}${select('pol_category','التصنيف',policyCategories())}${input('pol_effective','تاريخ السريان',p?.effective_date||'','date')}</div>${policyTextArea('pol_purpose','الغرض',p?.purpose)}${policyTextArea('pol_scope','نطاق التطبيق',p?.scope)}${policyTextArea('pol_text','النص التفصيلي للسياسة',p?.policy_text,6)}${policyTextArea('pol_procedures','الإجراءات المطلوبة',p?.procedures,4)}${policyTextArea('pol_responsibilities','المسؤوليات',p?.responsibilities,4)}${policyTextArea('pol_exceptions','الاستثناءات',p?.exceptions_text,3)}${!p?`<div style="margin-top:10px">${select('pol_status','الحالة',['Draft','Active'])}</div>`:''}<div class="note" style="margin-top:10px">${p?'حفظ التعديل ينشئ إصدارًا جديدًا ويستلزم إقرارًا جديدًا من الفريق للنسخة الحالية.':'يمكن إنشاء السياسة كمسودة أو تفعيلها مباشرة.'}</div><div class="row" style="margin-top:14px"><button class="btn primary" onclick="savePolicy('${id}')">${displayText('حفظ')}</button></div>`);setTimeout(()=>{if(p)document.getElementById('pol_category').value=p.category||'عام'},0)
}
function policyTextArea(id,label,value='',rows=3){return `<label style="margin-top:10px">${displayText(label)}</label><textarea id="${id}" rows="${rows}">${esc(value||'')}</textarea>`}
async function savePolicy(id=''){
 if(profile.role!=='CFO')return;const common={p_policy_code:val('pol_code'),p_title:val('pol_title'),p_category:val('pol_category'),p_purpose:val('pol_purpose')||null,p_scope:val('pol_scope')||null,p_policy_text:val('pol_text'),p_procedures:val('pol_procedures')||null,p_responsibilities:val('pol_responsibilities')||null,p_exceptions_text:val('pol_exceptions')||null,p_effective_date:val('pol_effective')||null};
 const call=id?sb.rpc('update_finance_policy',{p_policy_id:id,...common}):sb.rpc('create_finance_policy',{...common,p_status:val('pol_status')||'Draft'});const {error}=await call;if(error)return alert(error.message);closeModal();await reloadAll();switchExceptionsTab('policies')
}
function viewPolicy(id){const p=financePolicies.find(x=>x.id===id);if(!p)return;showModal(`${p.policy_code} — ${p.title}`,`<div class="row"><div>${policyStatusBadge(p.status)}</div><div class="muted">${displayText('الإصدار')} ${p.current_version}.0 | ${displayText('تاريخ السريان')}: ${esc(p.effective_date||'—')}</div></div>${policyDetail('التصنيف',p.category)}${policyDetail('الغرض',p.purpose)}${policyDetail('نطاق التطبيق',p.scope)}${policyDetail('النص التفصيلي للسياسة',p.policy_text)}${policyDetail('الإجراءات المطلوبة',p.procedures)}${policyDetail('المسؤوليات',p.responsibilities)}${policyDetail('الاستثناءات',p.exceptions_text)}${p.status==='Active'&&!p.acknowledged_current?`<div class="row" style="margin-top:14px"><button class="btn success" onclick="acknowledgePolicy('${p.id}')">${displayText('اطلعت وألتزم')}</button></div>`:''}`)}
function policyDetail(label,value){if(!value)return'';return `<div style="margin-top:12px"><b>${displayText(label)}</b><div class="note" style="margin-top:5px;white-space:pre-wrap">${esc(value)}</div></div>`}
async function acknowledgePolicy(id){const {error}=await sb.rpc('acknowledge_finance_policy',{p_policy_id:id});if(error)return alert(error.message);closeModal();await reloadAll();switchExceptionsTab('policies')}
async function changePolicyStatus(id,status){if(profile.role!=='CFO')return;const {error}=await sb.rpc('set_finance_policy_status',{p_policy_id:id,p_status:status});if(error)return alert(error.message);await reloadAll();switchExceptionsTab('policies')}
async function viewPolicyVersions(id){const {data,error}=await sb.rpc('get_finance_policy_versions',{p_policy_id:id});if(error)return alert(error.message);showModal(displayText('سجل الإصدارات'),`<div class="table-wrap"><table><thead><tr><th>${displayText('الإصدار')}</th><th>${displayText('التاريخ')}</th><th>${displayText('المستخدم')}</th><th>${displayText('عنوان السياسة')}</th></tr></thead><tbody>${(data||[]).map(v=>`<tr><td>${v.version_no}.0</td><td>${fmt(v.created_at)}</td><td>${esc(v.created_by_name||'—')}</td><td>${esc(v.snapshot?.title||'—')}</td></tr>`).join('')||'<tr><td colspan="4">—</td></tr>'}</tbody></table></div>`);installTableFilters()}
'''
s=s[:insert_at]+policy_js+'\n'+s[insert_at:]

# Extend bilingual dictionary for new controls without altering existing translations.
needle='Object.assign(I18N_AR_EN,{'
addition='''Object.assign(I18N_AR_EN,{\n"سياسات الإدارة المالية":"Finance Department Policies","إضافة سياسة":"Add Policy","رمز السياسة":"Policy Code","عنوان السياسة":"Policy Title","التصنيف":"Category","تاريخ السريان":"Effective Date","الغرض":"Purpose","نطاق التطبيق":"Scope","النص التفصيلي للسياسة":"Full Policy Text","الإجراءات المطلوبة":"Required Procedures","المسؤوليات":"Responsibilities","الاستثناءات":"Exceptions","الإصدار":"Version","تم الإقرار":"Acknowledged","بانتظار الإقرار":"Acknowledgement Pending","إقرارات النسخة الحالية":"Current Version Acknowledgements","عرض التفاصيل":"View Details","سجل الإصدارات":"Version History","اطلعت وألتزم":"I Have Read and Acknowledge","تفعيل":"Activate","تعليق":"Suspend","أرشفة":"Archive","Active":"Active","Draft":"Draft","Suspended":"Suspended","Archived":"Archived","عام":"General","الحضور والتسليم":"Attendance & Handover","حفظ المهمة الجديدة كقالب قابل لإعادة الاستخدام":"Save new task as reusable template",'''
assert needle in s
s=s.replace(needle,addition,1)

p.write_text(s)
print('patched daily plan + finance policies UI')
