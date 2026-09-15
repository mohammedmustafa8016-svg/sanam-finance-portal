from pathlib import Path
import re
p=Path('index.html')
s=p.read_text()
marker='/* CFO_MONITOR_RESERVES_2026_09_15 */'
if marker in s:
    print('already patched')
    raise SystemExit(0)
s=s.replace('/* OPS_CONTROL_V2_2026_09_14 */','/* OPS_CONTROL_V2_2026_09_14 */\n'+marker,1)

# Styles
style_anchor='.ops-grid .card{padding:11px}'
style_add='''.ops-grid .card{padding:11px}.monitor-grid{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:10px;margin-bottom:14px}.monitor-grid .card{padding:12px}.monitor-grid b{font-size:20px;display:block;margin-top:4px}.monitor-section{margin-top:14px}.reserve-monitor-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}.reserve-monitor-card{border-inline-start:4px solid var(--amber)}.reserve-monitor-card.vat{border-inline-start-color:var(--blue)}.reserve-meta{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:6px;margin-top:10px;font-size:12px}.monitor-table table{min-width:700px}.warning-box{padding:9px 11px;border:1px solid #e9c46a;background:#fff8e7;border-radius:7px;color:#7a4f00;font-size:12px;margin-top:10px}@media(max-width:1100px){.monitor-grid{grid-template-columns:repeat(3,minmax(0,1fr))}}@media(max-width:700px){.monitor-grid,.reserve-monitor-grid{grid-template-columns:1fr 1fr}}@media(max-width:500px){.monitor-grid,.reserve-monitor-grid{grid-template-columns:1fr}}'''
if style_anchor not in s: raise SystemExit('style anchor missing')
s=s.replace(style_anchor,style_add,1)

# Dashboard as CFO monitor without removing other pages.
dash=re.search(r'<section id="dashboard" class="section active">.*?</section>\n<section id="banks"',s,re.S)
if not dash: raise SystemExit('dashboard block missing')
new_dash='''<section id="dashboard" class="section active">
<div class="row"><div><h3 style="margin:0">CFO Financial & Operations Monitor</h3><div class="muted">مراقبة السيولة والتشغيل والمدفوعات والمهام والإقفال والاستثناءات من مكان واحد.</div></div><button class="btn" onclick="reloadAll()">تحديث</button></div>
<div class="monitor-grid" style="margin-top:12px">
 <div class="card kpi"><span>إجمالي النقد بالبنوك</span><b id="kpiTotalBankCash">—</b></div>
 <div class="card kpi"><span>السيولة التشغيلية</span><b id="kpiOperationalLiquidity">—</b></div>
 <div class="card kpi"><span>احتياطي رأس المال العامل</span><b id="kpiWorkingCapital">—</b></div>
 <div class="card kpi"><span>احتياطي ضريبة القيمة المضافة</span><b id="kpiVatReserve">—</b></div>
 <div class="card kpi"><span>محجوز لمدفوعات معلقة</span><b id="kpiPendingReserved">—</b></div>
 <div class="card kpi"><span>صافي السيولة التشغيلية المتاحة</span><b id="kpiNetOperational">—</b></div>
</div>
<div class="card monitor-section"><div class="row"><h3 style="margin:0">الحسابات المحمية</h3><span class="muted">Monitoring only — لا يتم منع التحويل آليًا.</span></div><div id="reserveMonitorCards" class="reserve-monitor-grid" style="margin-top:10px"></div></div>
<div class="grid g2 monitor-section"><div class="card"><h3 style="margin-top:0">مراقبة المدفوعات</h3><div id="dashboardPayments"></div></div><div class="card"><h3 style="margin-top:0">مراقبة المهام</h3><div id="dashboardTasks"></div></div></div>
<div class="grid g2 monitor-section"><div class="card"><h3 style="margin-top:0">حالة الإقفال الشهري</h3><div id="dashboardClose"></div></div><div class="card"><h3 style="margin-top:0">الاستثناءات التي تحتاج تدخلًا</h3><div id="dashboardExceptions"></div></div></div>
<div class="card monitor-section"><h3 style="margin-top:0">مراقبة أداء الفريق</h3><div class="table-wrap monitor-table"><table><thead><tr><th>الموظف</th><th>يعمل الآن على</th><th>مهام اليوم</th><th>المكتمل</th><th>المتأخر</th><th>متعثر</th><th>بانتظار المراجعة</th><th>إنجاز الشهر</th><th>في الموعد</th></tr></thead><tbody id="dashboardTeamBody"></tbody></table></div></div>
<div class="card monitor-section"><h3 style="margin-top:0">صحة الأتمتة</h3><div id="dashboardAutomation"></div></div>
</section>
<section id="banks"'''
s=s[:dash.start()]+new_dash+s[dash.end():]

# Bank table gets Account Type.
s=s.replace('<th>الحساب</th><th>آخر 4 أرقام</th>','<th>الحساب</th><th>نوع الحساب</th><th>آخر 4 أرقام</th>',1)
s=s.replace('الرصيد المحجوز يُحتسب تلقائياً من المدفوعات غير المنفذة المرتبطة بالحساب البنكي ولا يمكن إدخاله يدويًا.','حدد نوع الحساب من إعداد الحساب. الحسابات الاحتياطية تظل ضمن إجمالي النقد ولكن تُستبعد من السيولة التشغيلية، واستخدامها في المدفوعات يولد تحذيرًا ومراقبة فقط.',1)

# State
old='let session=null,profile=null,profiles=[],banks=[],payments=[],tasks=[],exceptions=[],closeTasks=[],imprest=[],performance=[],ownership=[],controlCenter=[],workload=[],escalations=[],automationHealth=[];'
new='let session=null,profile=null,profiles=[],banks=[],payments=[],tasks=[],exceptions=[],closeTasks=[],imprest=[],performance=[],ownership=[],controlCenter=[],workload=[],escalations=[],automationHealth=[],reserveAccounts=[];'
if old not in s: raise SystemExit('state anchor missing')
s=s.replace(old,new,1)

# Payment relation includes account type.
s=s.replace('bank_accounts(company,bank_name,account_name)','bank_accounts(company,bank_name,account_name,account_type)',1)
# Load reserve monitor data after base arrays are assigned.
anchor='ownership=ow.data||[];if(["CFO","Supervisor"].includes(profile.role))'
if anchor not in s: raise SystemExit('reload anchor missing')
s=s.replace(anchor,'ownership=ow.data||[];const rr=await sb.rpc("get_reserve_account_monitor");reserveAccounts=rr.data||[];if(["CFO","Supervisor"].includes(profile.role))',1)

# Helpers and CFO monitor renderer
rd=re.search(r'function renderDashboard\(\)\{.*?\}\nfunction maskAccountNo',s,re.S)
if not rd: raise SystemExit('renderDashboard anchor missing')
render='''const ACCOUNT_TYPES=[{value:"Operational",label:"تشغيلي"},{value:"Working Capital Reserve",label:"احتياطي رأس المال العامل"},{value:"VAT Reserve",label:"احتياطي ضريبة القيمة المضافة"},{value:"Restricted / Other",label:"مقيد / آخر"}];
function accountTypeLabel(v){const x=ACCOUNT_TYPES.find(a=>a.value===(v||"Operational"));return currentLang==='en'?(v||'Operational'):(x?.label||v||'تشغيلي')}
function isProtectedBank(b){return !!b&&((b.account_type||'Operational')!=='Operational')}
function metricLine(label,value,cls=''){return `<div class="row" style="padding:5px 0;border-bottom:1px solid #eef2f6"><span class="muted">${displayText(label)}</span><b class="${cls}">${value}</b></div>`}
function renderDashboard(){
 const totalCash=banks.reduce((s,b)=>s+Number(b.balance||0),0),pendingReserved=banks.reduce((s,b)=>s+Number(b.reserved_balance||0),0);
 const operational=banks.filter(b=>(b.account_type||'Operational')==='Operational'),opCash=operational.reduce((s,b)=>s+Number(b.balance||0),0),opAvailable=operational.reduce((s,b)=>s+Number(b.available_balance||0),0);
 const wc=banks.filter(b=>b.account_type==='Working Capital Reserve').reduce((s,b)=>s+Number(b.balance||0),0),vat=banks.filter(b=>b.account_type==='VAT Reserve').reduce((s,b)=>s+Number(b.balance||0),0);
 kpiTotalBankCash.textContent=money(totalCash);kpiOperationalLiquidity.textContent=money(opCash);kpiWorkingCapital.textContent=money(wc);kpiVatReserve.textContent=money(vat);kpiPendingReserved.textContent=money(pendingReserved);kpiNetOperational.textContent=money(opAvailable);
 const canMove=['CFO','Supervisor','BankAccountant'].includes(profile.role);
 reserveMonitorCards.innerHTML=reserveAccounts.map(r=>`<div class="card reserve-monitor-card ${r.account_type==='VAT Reserve'?'vat':''}"><div class="row"><div><b>${esc(accountTypeLabel(r.account_type))}</b><div class="muted">${esc(r.bank_name)} — ${esc(r.account_name)} — •••• ${esc(r.account_no_last4||'—')}</div></div><span class="badge amber">Protected / Monitor</span></div><div class="reserve-meta"><div><span class="muted">الرصيد الحالي</span><b>${moneyHtml(r.balance)}</b></div><div><span class="muted">المتاح بالحساب</span><b>${moneyHtml(r.available_balance)}</b></div><div><span class="muted">سحوبات منفذة عبر النظام</span><b>${moneyHtml(r.executed_outflows)}</b></div><div><span class="muted">سحب دعم خارجي مسجل</span><b>${moneyHtml(r.manual_support_draws)}</b></div><div><span class="muted">مبالغ تمت استعادتها</span><b>${moneyHtml(r.restorations)}</b></div><div><span class="muted">استعادة معلقة</span><b class="${Number(r.outstanding_restoration)>0?'negative-amount':''}">${money(r.outstanding_restoration)}</b></div></div>${canMove?`<div class="row" style="margin-top:10px"><button class="btn" onclick="openReserveMovement('${r.bank_account_id}','Support Draw')">تسجيل سحب دعم خارجي</button><button class="btn success" onclick="openReserveMovement('${r.bank_account_id}','Restoration')">تسجيل استعادة</button></div>`:''}</div>`).join('')||`<div class="note">لم يتم تصنيف أي حساب كحساب احتياطي حتى الآن. يمكن للفريق تحديد Account Type من صفحة السيولة والبنوك.</div>`;
 const active=payments.filter(p=>p.status!=='مرحّل'),awaitSup=active.filter(p=>p.supervisor_status==='معلق').length,awaitCfo=active.filter(p=>p.supervisor_status==='موافق'&&p.cfo_status==='معلق').length,readyBank=active.filter(p=>p.cfo_status==='موافق'&&!p.executed_at).length,execUnposted=active.filter(p=>p.executed_at&&!p.posted_at).length,protectedActive=active.filter(p=>isProtectedBank(p.bank_accounts)).length;
 dashboardPayments.innerHTML=metricLine('بانتظار المشرف',awaitSup)+metricLine('بانتظار CFO',awaitCfo)+metricLine('جاهز للتنفيذ البنكي',readyBank)+metricLine('منفذ وغير مرحل',execUnposted)+metricLine('مدفوعات تستخدم حسابًا محميًا',protectedActive,protectedActive?'negative-amount':'');
 const today=new Date().toISOString().slice(0,10),todayTasks=tasks.filter(t=>t.due_date===today),done=todayTasks.filter(t=>t.status==='مكتمل').length,over=tasks.filter(t=>isTaskOverdue(t)&&t.status!=='مكتمل').length,block=tasks.filter(t=>t.blocker_note).length,pendingReview=tasks.filter(t=>t.status==='بانتظار المراجعة').length,just=tasks.filter(taskJustificationRequired).length;
 dashboardTasks.innerHTML=metricLine('مهام اليوم',todayTasks.length)+metricLine('مكتمل اليوم',done)+metricLine('متأخر الآن',over,over?'negative-amount':'')+metricLine('متعثر',block,block?'negative-amount':'')+metricLine('بانتظار المراجعة',pendingReview)+metricLine('تبرير مطلوب',just,just?'negative-amount':'');
 const periods=closeTasks.map(x=>x.close_period).filter(Boolean).sort(),latest=periods.at(-1),cycle=latest?closeTasks.filter(x=>x.close_period===latest):[],complete=cycle.filter(x=>x.status==='مكتمل'||Number(x.progress||0)>=100).length,rate=cycle.length?complete*100/cycle.length:0,closeOver=cycle.filter(x=>x.due_date&&x.due_date<today&&x.status!=='مكتمل'&&Number(x.progress||0)<100).length,nextClose=cycle.filter(x=>x.status!=='مكتمل'&&Number(x.progress||0)<100&&x.due_date).sort((a,b)=>String(a.due_date).localeCompare(String(b.due_date)))[0];
 dashboardClose.innerHTML=metricLine('دورة الإقفال',latest||'—')+metricLine('نسبة الإنجاز',`${rate.toFixed(1)}%`)+metricLine('مهام متأخرة',closeOver,closeOver?'negative-amount':'')+metricLine('أقرب استحقاق',nextClose?`${esc(nextClose.code||'')} — ${esc(nextClose.due_date)}`:'—');
 const currentByUser=Object.fromEntries(controlCenter.map(x=>[x.user_id,x]));dashboardTeamBody.innerHTML=performance.map(x=>{const c=currentByUser[x.user_id]||{};return `<tr><td>${esc(x.full_name||'—')}</td><td style="white-space:normal">${esc(c.current_task||'—')}</td><td>${x.today_total||0}</td><td>${x.today_completed||0}</td><td>${x.today_overdue||0}</td><td>${c.blocker_count||0}</td><td>${x.pending_review||0}</td><td><button class="link-metric" onclick="openPerformanceDrilldown('${x.user_id}','month')">${Number(x.month_completion_rate||0).toFixed(1)}%</button></td><td><button class="link-metric" onclick="openPerformanceDrilldown('${x.user_id}','ontime')">${Number(x.tracked_on_time_rate||0).toFixed(1)}%</button></td></tr>`}).join('')||`<tr><td colspan="9" class="muted">لا توجد بيانات أداء بعد.</td></tr>`;
 const issues=[];reserveAccounts.filter(r=>Number(r.outstanding_restoration)>0).forEach(r=>issues.push(`استعادة معلقة — ${accountTypeLabel(r.account_type)} — ${r.bank_name}: ${money(r.outstanding_restoration)}`));active.filter(p=>isProtectedBank(p.bank_accounts)).forEach(p=>issues.push(`استخدام حساب محمي — ${p.beneficiary} — ${money(p.amount)}`));if(over)issues.push(`مهام متأخرة: ${over}`);if(block)issues.push(`مهام متعثرة: ${block}`);if(closeOver)issues.push(`مهام إقفال متأخرة: ${closeOver}`);automationHealth.filter(a=>String(a.last_status||a.status||'').toLowerCase().includes('fail')||Number(a.missing_count||0)>0).forEach(a=>issues.push(`Automation: ${a.job_name||a.name||'—'} يحتاج مراجعة`));dashboardExceptions.innerHTML=issues.length?issues.slice(0,12).map(x=>`<div class="warning-box">${esc(x)}</div>`).join(''):`<div class="note">لا توجد استثناءات حرجة حالية.</div>`;
 dashboardAutomation.innerHTML=automationHealth.length?automationHealth.map(a=>metricLine(a.job_name||a.name||'Automation',`${esc(a.active===false?'Inactive':(a.last_status||a.status||'Active'))}${Number(a.missing_count||0)>0?` — Missing: ${Number(a.missing_count)}`:''}`)).join(''):`<div class="muted">—</div>`;
}
function maskAccountNo'''
s=s[:rd.start()]+render+s[rd.end():]

# Banks renderer / editor / saver
rb=re.search(r'function renderBanks\(\)\{.*?\}\nfunction openBankModal',s,re.S)
if not rb: raise SystemExit('renderBanks block missing')
new_rb='''function renderBanks(){const canDelete=["CFO","Supervisor","BankAccountant"].includes(profile.role);banksBody.innerHTML=banks.map(b=>`<tr><td>${esc(b.company)}</td><td>${esc(b.bank_name)}</td><td>${esc(b.account_name)}</td><td>${badge(accountTypeLabel(b.account_type))}</td><td>${maskAccountNo(b.account_no)}</td><td>${moneyHtml(b.balance)}</td><td>${moneyHtml(b.reserved_balance)}</td><td>${moneyHtml(b.available_balance)}</td><td>${fmt(b.updated_at)}</td><td><button class="btn" onclick="openBankModal('${b.id}')">${displayText('تعديل')}</button>${canDelete?` <button class="btn danger" onclick="deleteBankAccount('${b.id}')">${displayText('حذف')}</button>`:''}</td></tr>`).join("")||`<tr><td colspan="10" class="muted">—</td></tr>`}
function openBankModal'''
s=s[:rb.start()]+new_rb+s[rb.end():]

ob=re.search(r'function openBankModal\(id=""\)\{.*?\}\nasync function saveBank\(id=""\)\{.*?\}\nasync function deleteBankAccount',s,re.S)
if not ob: raise SystemExit('bank modal block missing')
new_ob='''function openBankModal(id=""){
 if(!["CFO","Supervisor","BankAccountant"].includes(profile.role))return;
 const b=banks.find(x=>x.id===id)||{};
 showModal(id?"تعديل حساب بنكي":"إضافة حساب بنكي",`<div class="modal-grid">${input("b_company","الشركة",b.company||"")}${input("b_bank","البنك",b.bank_name||"")}${input("b_name","اسم الحساب",b.account_name||"")}${input("b_no","رقم الحساب / IBAN",b.account_no||"")}${select("b_type","نوع الحساب البنكي",ACCOUNT_TYPES.map(x=>({value:x.value,label:x.label})))}${input("b_balance","الرصيد",b.balance||0,"number")}</div><div class="note" style="margin-top:12px">الحساب الاحتياطي يظل ضمن إجمالي النقد، لكنه يُستبعد من السيولة التشغيلية. الاختيار يولد مراقبة وتحذيرًا فقط ولا يمنع الدفع.</div><div class="row" style="margin-top:14px"><button class="btn primary" onclick="saveBank('${id}')">حفظ</button></div>`);setTimeout(()=>{const el=document.getElementById('b_type');if(el)el.value=b.account_type||'Operational'},0)
}
async function saveBank(id=""){const payload={company:val("b_company"),bank_name:val("b_bank"),account_name:val("b_name"),account_no:val("b_no")||null,account_type:val("b_type")||'Operational',balance:Number(val("b_balance")||0),created_by:profile.id,updated_at:new Date().toISOString()};let q=id?sb.from("bank_accounts").update(payload).eq("id",id):sb.from("bank_accounts").insert(payload);const {error}=await q;if(error)return alert(error.message);closeModal();await reloadAll()}
async function deleteBankAccount'''
s=s[:ob.start()]+new_ob+s[ob.end():]

# Bank label makes reserve use obvious.
s=s.replace('function bankLabel(p){const b=p.bank_accounts;return b?`${b.bank_name} — ${b.account_name}`:"—"}','function bankLabel(p){const b=p.bank_accounts;return b?`${isProtectedBank(b)?"⚠ ":""}${b.bank_name} — ${b.account_name}${isProtectedBank(b)?` [${accountTypeLabel(b.account_type)}]`:""}`:"—"}',1)

# Payment modal labels protected account and save warns/monitors only.
op=re.search(r'function openPaymentModal\(\)\{.*?\}\nasync function savePayment\(\)\{.*?\}\nasync function supervisorApprove',s,re.S)
if not op: raise SystemExit('payment modal block missing')
new_op='''function openPaymentModal(){
 if(!["CFO","Supervisor","BankAccountant","APAccountant"].includes(profile.role))return;
 if(!banks.length){alert("أضف حسابًا بنكيًا أولًا.");return}
 const bankOpts=banks.map(b=>({value:b.id,label:`${isProtectedBank(b)?"⚠ ":""}${b.bank_name} — ${b.account_name} (${b.company})${isProtectedBank(b)?` — ${accountTypeLabel(b.account_type)}`:""}`}));
 showModal("إضافة دفعة",`<div class="modal-grid">${input("p_due","تاريخ الاستحقاق","","date")}${input("p_company","الشركة")}${input("p_beneficiary","المستفيد")}${input("p_amount","المبلغ",0,"number")}${select("p_bank","حساب البنك",bankOpts)}${select("p_priority","الأولوية",["عادي","عاجل","حرج"])}${select("p_docs","المستندات",["مكتملة","ناقصة"])}${input("p_purpose","الغرض")}</div><div class="warning-box">عند اختيار حساب احتياطي سيظهر تحذير قبل الحفظ. التحذير للمراقبة ولا يمنع إنشاء الدفعة.</div><div class="row" style="margin-top:14px"><button class="btn primary" onclick="savePayment()">حفظ</button></div>`)
}
async function savePayment(){const bank=banks.find(b=>b.id===val("p_bank"));if(isProtectedBank(bank)){const msg=currentLang==='en'?`WARNING: This is a protected ${bank.account_type} account. Use should be exceptional and monitored. Continue creating this payment?`:`تحذير: الحساب المختار من نوع «${accountTypeLabel(bank.account_type)}» وهو حساب محمي للاستخدام الاستثنائي وتتم مراقبة السحب منه. هل تريد الاستمرار في إنشاء الدفعة؟`;if(!confirm(msg))return}const payload={due_date:val("p_due"),company:val("p_company"),beneficiary:val("p_beneficiary"),amount:Number(val("p_amount")||0),bank_account_id:val("p_bank"),priority:val("p_priority"),documents_status:val("p_docs"),purpose:val("p_purpose")||null,requested_by:profile.id};const {error}=await sb.from("payments").insert(payload);if(error)return alert(error.message);closeModal();await reloadAll()}
async function supervisorApprove'''
s=s[:op.start()]+new_op+s[op.end():]

# Reserve movement monitoring actions (no bank transaction execution).
anchor='const PAYMENT_REPORT_COLUMNS='
if anchor not in s: raise SystemExit('payment report anchor missing')
reserve_fn='''function openReserveMovement(bankId,type){if(!['CFO','Supervisor','BankAccountant'].includes(profile.role))return;const b=banks.find(x=>x.id===bankId);if(!b||!isProtectedBank(b))return;showModal(type==='Restoration'?'تسجيل استعادة مبلغ للحساب المحمي':'تسجيل سحب دعم خارجي',`<div class="note">${esc(b.bank_name)} — ${esc(b.account_name)} — ${esc(accountTypeLabel(b.account_type))}</div><div class="modal-grid" style="margin-top:10px">${input('rm_amount','المبلغ',0,'number')}${input('rm_date','التاريخ',new Date().toISOString().slice(0,10),'date')}</div><label style="margin-top:10px">ملاحظة</label><textarea id="rm_note" rows="3"></textarea><div class="row" style="margin-top:14px"><button class="btn primary" onclick="saveReserveMovement('${bankId}','${type}')">حفظ سجل المراقبة</button></div>`)}
async function saveReserveMovement(bankId,type){const amount=Number(val('rm_amount')||0);if(amount<=0)return alert('أدخل مبلغًا أكبر من صفر.');const {error}=await sb.rpc('record_reserve_movement',{p_bank_account_id:bankId,p_movement_type:type,p_amount:amount,p_movement_date:val('rm_date')||null,p_note:val('rm_note')||null});if(error)return alert(error.message);closeModal();await reloadAll()}

'''
s=s.replace(anchor,reserve_fn+anchor,1)

# Translation additions where available.
i18n='const I18N_EN_AR=Object.fromEntries(Object.entries(I18N_AR_EN).map(([a,e])=>[e,a]));'
if i18n in s:
    adds='''I18N_AR_EN["إجمالي النقد بالبنوك"]="Total Bank Cash";I18N_AR_EN["السيولة التشغيلية"]="Operational Liquidity";I18N_AR_EN["احتياطي رأس المال العامل"]="Working Capital Reserve";I18N_AR_EN["احتياطي ضريبة القيمة المضافة"]="VAT Reserve";I18N_AR_EN["محجوز لمدفوعات معلقة"]="Reserved for Pending Payments";I18N_AR_EN["صافي السيولة التشغيلية المتاحة"]="Net Available Operational Cash";I18N_AR_EN["الحسابات المحمية"]="Protected Accounts";I18N_AR_EN["نوع الحساب البنكي"]="Bank Account Type";I18N_AR_EN["مراقبة المدفوعات"]="Payments Monitor";I18N_AR_EN["مراقبة المهام"]="Tasks Monitor";I18N_AR_EN["حالة الإقفال الشهري"]="Monthly Close Status";I18N_AR_EN["الاستثناءات التي تحتاج تدخلًا"]="Exceptions Requiring Action";I18N_AR_EN["مراقبة أداء الفريق"]="Team Performance Monitor";'''
    s=s.replace(i18n,adds+i18n,1)

p.write_text(s)
print('CFO monitor reserve patch complete')
