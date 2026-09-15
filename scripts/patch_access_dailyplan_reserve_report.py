from pathlib import Path
import re
p=Path('index.html')
s=p.read_text()
marker='/* ACCESS_DAILYPLAN_RESERVE_REPORT_2026_09_15 */'
if marker in s:
    print('already patched'); raise SystemExit(0)
s=s.replace('/* CFO_MONITOR_RESERVES_2026_09_15 */','/* CFO_MONITOR_RESERVES_2026_09_15 */\n'+marker,1)

# Navigation: merge workload into control, hide standalone workload, add CFO permissions screen.
s=s.replace('<button class="nav" data-page="control">مركز التحكم اليومي</button><button class="nav" data-page="workload">عبء العمل والطاقة</button>', '<button class="nav" data-page="control">مركز التشغيل اليومي وعبء العمل</button>',1)
s=s.replace('<button class="nav" data-page="audit">سجل العمليات</button></aside>', '<button class="nav" data-page="audit">سجل العمليات</button><button class="nav" data-page="permissions">إدارة الصلاحيات والظهور</button></aside>',1)

# Banks header/report and reference balance column.
s=s.replace('<div class="row" style="margin-bottom:12px"><h3>السيولة والبنوك</h3><button id="addBankBtn" class="btn primary" type="button" onclick="openBankModal()">+ إضافة حساب</button></div>', '<div class="row" style="margin-bottom:12px"><h3>السيولة والبنوك</h3><div class="lang-actions"><button id="reserveReportBtn" class="btn" type="button" onclick="openReserveReport()">تقرير الحسابات المحمية</button><button id="addBankBtn" class="btn primary" type="button" onclick="openBankModal()">+ إضافة حساب</button></div></div>',1)
s=s.replace('<th>نوع الحساب</th><th>آخر 4 أرقام</th><th>الرصيد</th>', '<th>نوع الحساب</th><th>آخر 4 أرقام</th><th>الرصيد المرجعي</th><th>الرصيد</th>',1)

# Merge control/workload content into control page, leave old section hidden for compatibility.
old_control=re.search(r'<section id="control" class="section">.*?</section>\n<section id="workload"',s,re.S)
if not old_control: raise SystemExit('control block missing')
new_control='''<section id="control" class="section"><div class="row" style="margin-bottom:12px"><div><h3 style="margin:0">مركز التشغيل اليومي وعبء العمل</h3><div class="muted">خطة اليوم، ما يعمل عليه كل موظف، التأخير، التعثر، المراجعة والطاقة الاستيعابية في شاشة واحدة.</div></div><div class="lang-actions"><button id="dailyPlanControlBtn" class="btn success" type="button" onclick="openDailyPlan()">إعداد / تعديل خطة اليوم</button><button id="capacityBtn" class="btn primary" onclick="openCapacitySettings()">إعداد الطاقة</button><button class="btn" onclick="reloadAll()">تحديث</button></div></div><div id="controlKpis" class="ops-grid"></div><div class="table-wrap"><table id="controlTable"><thead><tr><th>الموظف</th><th>الدور</th><th>يعمل الآن على</th><th>الحالة</th><th>الموعد التالي</th><th>المتبقي</th><th>مهام اليوم</th><th>المكتمل</th><th>المتأخر</th><th>التعثر</th><th>بانتظار المراجعة</th><th>تبرير مطلوب</th></tr></thead><tbody id="controlBody"></tbody></table></div><div class="card" style="margin-top:14px"><h3 style="margin-top:0">عبء العمل والطاقة الاستيعابية</h3><div class="note" style="margin-bottom:12px">الطاقة الاستيعابية يحددها المدير المالي أو المشرف لكل موظف، وتظهر بجانب مهام اليوم لاتخاذ قرار توزيع العمل قبل فتح الخطة.</div><div class="table-wrap"><table id="workloadMergedTable"><thead><tr><th>الموظف</th><th>الدور</th><th>الطاقة اليومية</th><th>المهام المفتوحة اليوم</th><th>حرجة</th><th>عالية</th><th>متأخرة</th><th>بانتظار المراجعة</th><th>متعثر</th><th>الاستخدام</th></tr></thead><tbody id="workloadMergedBody"></tbody></table></div></div></section>\n<section id="workload"'''
s=s[:old_control.start()]+new_control+s[old_control.end():]

# Add permissions section before modal.
perm_section='''\n<section id="permissions" class="section"><div class="row" style="margin-bottom:12px"><div><h3 style="margin:0">إدارة الصلاحيات والظهور</h3><div class="muted">هذه الشاشة للمدير المالي فقط لتحديد الصفحات التي تظهر لكل موظف ومن يمكنه رؤية أرصدة البنوك.</div></div><button class="btn" onclick="reloadAll()">تحديث</button></div><div class="note" style="margin-bottom:12px">إخفاء الصفحة يغير واجهة المستخدم، وصلاحية «أرصدة البنوك» تتحكم كذلك في تحميل بيانات السيولة التفصيلية داخل البوابة.</div><div class="table-wrap"><table id="permissionsTable"><thead><tr><th>الموظف</th><th>الدور</th><th>Dashboard</th><th>البنوك</th><th>المدفوعات</th><th>المهام</th><th>التشغيل اليومي</th><th>التصعيد</th><th>الأتمتة</th><th>الإقفال</th><th>العهد</th><th>الأداء</th><th>المسؤوليات</th><th>الاستثناءات</th><th>Audit</th><th>أرصدة البنوك</th></tr></thead><tbody id="permissionsBody"></tbody></table></div></section>\n'''
s=s.replace('<div id="modalBg" class="modal-bg">',perm_section+'<div id="modalBg" class="modal-bg">',1)

# Globals.
s=s.replace('let session=null,profile=null,profiles=[],banks=[],payments=[],tasks=[],exceptions=[],closeTasks=[],imprest=[],performance=[],ownership=[],controlCenter=[],workload=[],escalations=[],automationHealth=[],reserveAccounts=[];', 'let session=null,profile=null,profiles=[],banks=[],bankDirectory=[],payments=[],tasks=[],exceptions=[],closeTasks=[],imprest=[],performance=[],ownership=[],controlCenter=[],workload=[],escalations=[],automationHealth=[],reserveAccounts=[],permissionRows=[];let permissionMap={};',1)

# Enter app loads permissions before access rules.
s=s.replace('profile=u;authScreen.classList.add("hidden");app.classList.remove("hidden");userRole.textContent=`${profile.full_name} — ${displayText(ROLE_LABEL[profile.role]||profile.role)}`;applyAccess();await reloadAll();applyLanguage()', 'profile=u;authScreen.classList.add("hidden");app.classList.remove("hidden");userRole.textContent=`${profile.full_name} — ${displayText(ROLE_LABEL[profile.role]||profile.role)}`;await loadMyPermissions();applyAccess();await reloadAll();applyLanguage()',1)

# Dynamic permissions replace applyAccess/openPage.
pat=r'function applyAccess\(\)\{.*?\}\nfunction openPage\(id,title\)\{.*?\}\nasync function reloadAll\(\)\{'
m=re.search(pat,s,re.S)
if not m: raise SystemExit('access/reload anchor missing')
replacement='''async function loadMyPermissions(){const {data,error}=await sb.rpc("get_my_permissions");permissionMap={};if(!error)(data||[]).forEach(x=>permissionMap[x.permission_key]=!!x.allowed)}
function canPage(id){return !!permissionMap[`page.${id}`]}
function canBankBalances(){return !!permissionMap['data.bank_balances']}
function applyAccess(){document.querySelectorAll(".nav").forEach(b=>b.classList.toggle("hidden",!canPage(b.dataset.page)));addBankBtn?.classList.toggle("hidden",!["CFO","Supervisor","BankAccountant"].includes(profile.role));reserveReportBtn?.classList.toggle("hidden",!canBankBalances());addPaymentBtn?.classList.toggle("hidden",!["CFO","Supervisor","BankAccountant","APAccountant"].includes(profile.role));paymentReportBtn?.classList.toggle("hidden",!["CFO","Supervisor","BankAccountant"].includes(profile.role));addTaskBtn?.classList.toggle("hidden",!["CFO","Supervisor"].includes(profile.role));dailyPlanBtn?.classList.toggle("hidden",!["CFO","Supervisor"].includes(profile.role));dailyPlanControlBtn?.classList.toggle("hidden",!["CFO","Supervisor"].includes(profile.role));capacityBtn?.classList.toggle("hidden",!["CFO","Supervisor"].includes(profile.role));addExceptionBtn?.classList.toggle("hidden",profile.role!=="CFO");addCloseBtn?.classList.toggle("hidden",!["CFO","Supervisor"].includes(profile.role));addImprestBtn?.classList.toggle("hidden",!["CFO","Supervisor","BankAccountant","APAccountant"].includes(profile.role))}
function openPage(id,title){if(!canPage(id))return;document.querySelectorAll(".section").forEach(x=>x.classList.remove("active"));document.getElementById(id)?.classList.add("active");document.querySelectorAll(".nav").forEach(x=>x.classList.remove("active"));document.querySelector(`.nav[data-page="${id}"]`)?.classList.add("active");pageTitle.textContent=title;if(id==="audit")loadAudit()}
async function reloadAll(){'''
s=s[:m.start()]+replacement+s[m.end():]

# Replace reloadAll body up to renderAll.
pat=r'async function reloadAll\(\)\{.*?\}\nfunction renderAll\(\)\{'
m=re.search(pat,s,re.S)
if not m: raise SystemExit('reloadAll block missing')
reload='''async function reloadAll(){
 const baseCalls=[sb.from("profiles").select("id,email,full_name,role").eq("active",true),sb.rpc("get_bank_account_directory"),sb.from("payments").select("*,bank_accounts(company,bank_name,account_name,account_type)").order("created_at",{ascending:false}),sb.from("tasks").select("*,owner:profiles!tasks_owner_id_fkey(full_name),reviewer:profiles!tasks_reviewer_id_fkey(full_name)").order("due_date",{ascending:false}).order("created_at",{ascending:false}),sb.from("exceptions").select("*,owner:profiles!exceptions_owner_id_fkey(full_name),leave_delegations(*,absent:profiles!leave_delegations_absent_user_id_fkey(full_name),substitute:profiles!leave_delegations_substitute_user_id_fkey(full_name))").order("created_at",{ascending:false}),sb.from("monthly_close_tasks").select("*,owner:profiles!monthly_close_tasks_owner_id_fkey(full_name)").order("due_date").order("code"),sb.from("imprest_funds").select("*,custodian:profiles!imprest_funds_custodian_id_fkey(full_name)").order("created_at",{ascending:false}),sb.rpc("get_finance_team_performance"),sb.from("ownership_matrix").select("*").order("sort_order")];
 const [pr,bd,py,tk,ex,cl,im,pf,ow]=await Promise.all(baseCalls);profiles=pr.data||[];bankDirectory=bd.data||[];payments=py.data||[];tasks=tk.data||[];exceptions=ex.data||[];closeTasks=cl.data||[];imprest=im.data||[];performance=pf.data||[];ownership=ow.data||[];
 if(canBankBalances()){const [bk,rr]=await Promise.all([sb.rpc("get_visible_bank_liquidity"),sb.rpc("get_reserve_account_monitor")]);banks=bk.data||[];reserveAccounts=rr.data||[]}else{banks=[];reserveAccounts=[]}
 if(canPage('control')||canPage('escalations')){const [cc,wl,es]=await Promise.all([sb.rpc("get_supervisor_control_center"),sb.rpc("get_workload_capacity"),sb.rpc("get_escalation_center")]);controlCenter=cc.data||[];workload=wl.data||[];escalations=es.data||[]}else{controlCenter=[];workload=[];escalations=[]}
 if(canPage('automation')){const ah=await sb.rpc("get_automation_health");automationHealth=ah.data||[]}else automationHealth=[];
 if(profile.role==='CFO'){const up=await sb.from('user_permissions').select('*');permissionRows=up.data||[]}else permissionRows=[];
 renderAll();
}
function renderAll(){'''
s=s[:m.start()]+reload+s[m.end():]

# Add permission render into renderAll.
s=s.replace('renderOwnership();renderExceptions();renderDashboard();installTableFilters();applyLanguage()', 'renderOwnership();renderExceptions();renderPermissions();renderDashboard();installTableFilters();applyLanguage()',1)

# Banks rendering/reference balance and modal/save payload.
s=s.replace('<td>${maskAccountNo(b.account_no)}</td><td>${moneyHtml(b.balance)}</td>', '<td>${maskAccountNo(b.account_no)}</td><td>${b.reference_balance==null?"—":moneyHtml(b.reference_balance)}</td><td>${moneyHtml(b.balance)}</td>',1)
s=s.replace('colspan="10"', 'colspan="11"',1)
s=s.replace('${select("b_type","نوع الحساب البنكي",ACCOUNT_TYPES.map(x=>({value:x.value,label:x.label})))}${input("b_balance","الرصيد",b.balance||0,"number")}', '${select("b_type","نوع الحساب البنكي",ACCOUNT_TYPES.map(x=>({value:x.value,label:x.label})))}${input("b_reference","الرصيد المرجعي / الافتراضي",b.reference_balance==null?"":b.reference_balance,"number")}${input("b_balance","الرصيد",b.balance||0,"number")}',1)
s=s.replace('account_type:val("b_type")||\'Operational\',balance:Number(val("b_balance")||0)', 'account_type:val("b_type")||\'Operational\',reference_balance:val("b_reference")===""?null:Number(val("b_reference")),balance:Number(val("b_balance")||0)',1)

# Payment account directory instead of balance dataset.
s=s.replace('if(!banks.length){alert("أضف حسابًا بنكيًا أولًا.");return}\n const bankOpts=banks.map', 'if(!bankDirectory.length){alert("أضف حسابًا بنكيًا أولًا.");return}\n const bankOpts=bankDirectory.map',1)
s=s.replace('async function savePayment(){const bank=banks.find(b=>b.id===val("p_bank"));', 'async function savePayment(){const bank=bankDirectory.find(b=>b.id===val("p_bank"));',1)

# Flexible daily plan replacing old implementation.
pat=r'function openDailyPlan\(\)\{.*?\}\nasync function saveDailyPlan\(\)\{.*?\}\nasync function startTask'
m=re.search(pat,s,re.S)
if not m: raise SystemExit('daily plan functions missing')
flex='''function planOwnerOptions(selected){return profiles.filter(p=>p.role!=="CFO").map(p=>`<option value="${p.id}" ${p.id===selected?'selected':''}>${esc(p.full_name)}</option>`).join('')}
function planPriorityOptions(selected){return ['عادي','عالي','عاجل','حرج'].map(x=>`<option ${x===(selected||'عادي')?'selected':''}>${x}</option>`).join('')}
function openDailyPlan(){if(!["CFO","Supervisor"].includes(profile.role))return;const rows=tasks.filter(t=>t.status!=='مكتمل');const html=rows.map(t=>`<tr><td><input type="checkbox" class="plan-check" data-id="${t.id}" ${t.due_date===riyadhToday()?'checked':''}></td><td style="white-space:normal">${esc(t.name)}</td><td><select class="plan-owner" data-id="${t.id}">${planOwnerOptions(t.owner_id)}</select></td><td><select class="plan-priority" data-id="${t.id}">${planPriorityOptions(t.priority)}</select></td><td><input type="time" class="plan-time" data-id="${t.id}" value="${t.due_time?String(t.due_time).slice(0,5):''}"></td><td>${esc(t.due_date||'—')}</td><td>${badge(t.status||'لم يبدأ')}</td></tr>`).join('');showModal(displayText('خطة اليوم / فتح المهام'),`<div class="note" style="margin-bottom:10px">اختر من جميع المهام المفتوحة للفريق، ويمكنك إعادة توزيع المسؤول والأولوية والموعد لليوم. المهام غير المحددة لن يتم فتحها ضمن خطة اليوم.</div><div class="table-wrap"><table class="plan-table"><thead><tr><th>✓</th><th>المهمة</th><th>المسؤول</th><th>الأولوية</th><th>وقت اليوم</th><th>تاريخها الحالي</th><th>الحالة</th></tr></thead><tbody>${html}</tbody></table></div><div class="card" style="margin-top:12px"><h4 style="margin-top:0">إضافة مهمة جديدة مباشرة إلى خطة اليوم</h4><div class="modal-grid">${input('plan_new_name','المهمة')}${select('plan_new_owner','المسؤول',profiles.filter(p=>p.role!=='CFO').map(p=>({value:p.id,label:p.full_name})))}${select('plan_new_priority','الأولوية',['عادي','عالي','عاجل','حرج'])}${input('plan_new_time','وقت الاستحقاق','','time')}${input('plan_new_output','المخرج المطلوب')}</div></div><div class="row" style="margin-top:14px"><button class="btn success" onclick="saveDailyPlan()">حفظ وفتح خطة اليوم</button></div>`)}
async function saveDailyPlan(){const items=[];document.querySelectorAll('.plan-check:checked').forEach(c=>{const id=c.dataset.id,owner_id=document.querySelector(`.plan-owner[data-id="${id}"]`)?.value||'',priority=document.querySelector(`.plan-priority[data-id="${id}"]`)?.value||'عادي',due_time=document.querySelector(`.plan-time[data-id="${id}"]`)?.value||'';items.push({id,owner_id,priority,due_time})});const newName=val('plan_new_name');if(newName){items.push({name:newName,owner_id:val('plan_new_owner'),priority:val('plan_new_priority')||'عادي',due_time:val('plan_new_time'),output:val('plan_new_output')||null})}if(!items.length)return alert('حدد مهمة واحدة على الأقل أو أضف مهمة جديدة.');if(items.some(x=>!x.owner_id||!x.due_time))return alert('يجب تحديد المسؤول ووقت الاستحقاق لكل مهمة ضمن خطة اليوم.');const {data,error}=await sb.rpc('save_flexible_daily_plan',{p_items:items});if(error)return alert(error.message);closeModal();await reloadAll();alert(`تم حفظ وفتح ${data} مهمة ضمن خطة اليوم.`)}
async function startTask'''
s=s[:m.start()]+flex+s[m.end():]

# Workload merged render: append duplicate rendering into merged body after existing function.
pat=r'function renderWorkload\(\)\{(.*?)\}\nfunction openCapacitySettings'
m=re.search(pat,s,re.S)
if not m: raise SystemExit('renderWorkload missing')
old_body=m.group(1)
new_body=old_body+'''\n if(document.getElementById('workloadMergedBody')){workloadMergedBody.innerHTML=workloadBody.innerHTML;applyTableFilters(document.getElementById('workloadMergedTable'))}'''
s=s[:m.start()]+ 'function renderWorkload(){'+new_body+'}\nfunction openCapacitySettings' + s[m.end():]

# Permission management + reserve report functions injected before init.
anchor="document.addEventListener('click',e=>{if(filterPopover&&!filterPopover.contains(e.target)&&!e.target.closest('.filter-arrow'))closeHeaderFilter()});"
if anchor not in s: raise SystemExit('init anchor missing')
extra=r'''
const PERMISSION_COLUMNS=[['page.dashboard','Dashboard'],['page.banks','البنوك'],['page.payments','المدفوعات'],['page.tasks','المهام'],['page.control','التشغيل اليومي'],['page.escalations','التصعيد'],['page.automation','الأتمتة'],['page.close','الإقفال'],['page.imprest','العهد'],['page.performance','الأداء'],['page.ownership','المسؤوليات'],['page.exceptions','الاستثناءات'],['page.audit','Audit'],['data.bank_balances','أرصدة البنوك']];
function renderPermissions(){if(!document.getElementById('permissionsBody'))return;if(profile?.role!=='CFO'){permissionsBody.innerHTML='';return}const map={};permissionRows.forEach(r=>map[`${r.user_id}|${r.permission_key}`]=!!r.allowed);permissionsBody.innerHTML=profiles.map(u=>`<tr><td>${esc(u.full_name)}</td><td>${esc(ROLE_LABEL[u.role]||u.role)}</td>${PERMISSION_COLUMNS.map(([k])=>`<td><input type="checkbox" style="width:auto" ${map[`${u.id}|${k}`]?'checked':''} onchange="changeUserPermission('${u.id}','${k}',this.checked)" ${u.id===profile.id&&k==='page.permissions'?'disabled':''}></td>`).join('')}</tr>`).join('')}
async function changeUserPermission(userId,key,allowed){const {error}=await sb.rpc('set_user_permission',{p_user_id:userId,p_permission_key:key,p_allowed:allowed});if(error){alert(error.message);await reloadAll();return}if(userId===profile.id){await loadMyPermissions();applyAccess()}const up=await sb.from('user_permissions').select('*');permissionRows=up.data||[];renderPermissions()}
async function openReserveReport(){if(!canBankBalances())return;const today=riyadhToday(),first=today.slice(0,8)+'01';const {data,error}=await sb.rpc('get_reserve_account_report',{p_from:first,p_to:today});if(error)return alert(error.message);const rows=data||[];const table=rows.map(r=>`<tr><td>${esc(accountTypeLabel(r.account_type))}</td><td>${esc(r.bank_name)}</td><td>${esc(r.account_name)}</td><td>${esc(r.account_no_last4||'—')}</td><td>${r.reference_balance==null?'—':moneyHtml(r.reference_balance)}</td><td>${moneyHtml(r.current_balance)}</td><td>${moneyHtml(r.period_support_draws)}</td><td>${moneyHtml(r.period_restorations)}</td><td>${moneyHtml(r.tracked_outstanding_restoration)}</td><td>${moneyHtml(r.amount_to_restore_reference)}</td><td>${r.variance_to_reference==null?'—':moneyHtml(r.variance_to_reference)}</td></tr>`).join('')||'<tr><td colspan="11">لا توجد حسابات محمية مصنفة حتى الآن.</td></tr>';showModal('تقرير الحسابات المحمية',`<div class="row" style="margin-bottom:10px"><div class="muted">الفترة الحالية: ${first} — ${today}</div><div class="lang-actions"><button class="btn" onclick="exportReserveReportCsv()">CSV</button><button class="btn" onclick="printReserveReport()">طباعة / PDF</button></div></div><div id="reserveReportArea" class="table-wrap"><table><thead><tr><th>النوع</th><th>البنك</th><th>الحساب</th><th>آخر 4</th><th>الرصيد المرجعي</th><th>الرصيد الحالي</th><th>مسحوبات الفترة</th><th>استردادات الفترة</th><th>المتبقي حسب سجل السحب</th><th>المطلوب لاستعادة الرصيد المرجعي</th><th>الانحراف</th></tr></thead><tbody>${table}</tbody></table></div>`);window.__reserveReportRows=rows}
function exportReserveReportCsv(){const rows=window.__reserveReportRows||[];const h=['Type','Bank','Account','Last4','Reference Balance','Current Balance','Period Draws','Period Restorations','Tracked Outstanding','Restore to Reference','Variance'];const q=v=>'"'+String(v??'').replace(/"/g,'""')+'"';const csv='\ufeff'+[h,...rows.map(r=>[r.account_type,r.bank_name,r.account_name,r.account_no_last4,r.reference_balance,r.current_balance,r.period_support_draws,r.period_restorations,r.tracked_outstanding_restoration,r.amount_to_restore_reference,r.variance_to_reference])].map(x=>x.map(q).join(',')).join('\n');const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([csv],{type:'text/csv;charset=utf-8'}));a.download='reserve-accounts-report.csv';a.click();URL.revokeObjectURL(a.href)}
function printReserveReport(){const area=document.getElementById('reserveReportArea');if(!area)return;const w=window.open('','_blank');w.document.write(`<html><head><title>Reserve Accounts Report</title><style>body{font-family:Arial;padding:20px}table{width:100%;border-collapse:collapse}th,td{border:1px solid #bbb;padding:6px;font-size:11px}th{background:#eee}</style></head><body dir="rtl"><h2>تقرير الحسابات المحمية</h2>${area.innerHTML}</body></html>`);w.document.close();w.print()}
'''
s=s.replace(anchor,anchor+'\n'+extra,1)

# Dashboard automation card hidden when no automation permission and permission dashboard itself is access-controlled.
s=s.replace('dashboardAutomation.innerHTML=automationHealth.length?', 'dashboardAutomation.closest(".card")?.classList.toggle("hidden",!canPage("automation")); dashboardAutomation.innerHTML=automationHealth.length?',1)

p.write_text(s)
print('patched')
