from pathlib import Path
import re
p=Path('index.html')
s=p.read_text(encoding='utf-8')

# Marker
s=s.replace('/* WORKCENTER_UI_CONSOLIDATION_V31_2026_09_17 */','/* WORKCENTER_UI_CONSOLIDATION_V31_2026_09_17 */\n/* PAYMENT_IMPREST_WORKFLOW_V32_2026_09_17 */')

# Payment navigation split.
old='<details class="nav-group" open><summary>المدفوعات</summary><button class="nav" data-page="payments">الاعتمادات</button><button class="nav" data-page="pending">المعلقة</button><button class="nav" data-page="posted">المرحلة</button></details>'
new='<details class="nav-group" open><summary>المدفوعات</summary><button class="nav" data-page="payments">الاعتمادات</button><button class="nav" data-page="executed">الاعتمادات المنفذة</button><button class="nav" data-page="pending">الاعتمادات المعلقة</button><button class="nav" data-page="posted">الاعتمادات المرحلة</button></details>'
if old not in s: raise SystemExit('payment nav anchor not found')
s=s.replace(old,new,1)

# Remove duplicate accounting queue panel from approvals page and add executed page.
pat=r'<section id="payments" class="section">(.*?)</section>\n<section id="posted"'
m=re.search(pat,s,re.S)
if not m: raise SystemExit('payments section not found')
pay=m.group(0)
pay=re.sub(r'<div id="accountingQueuePanel".*?</div></div></section>','</section>',pay,flags=re.S)
executed='''\n<section id="executed" class="section">\n<div class="row" style="margin-bottom:12px"><div><h3 style="margin:0">الاعتمادات المنفذة</h3><div class="muted">متابعة الاعتمادات من لحظة التنفيذ البنكي وحتى التسجيل والترحيل. تبدأ مهلة التسجيل 48 ساعة من تاريخ التنفيذ.</div></div><button class="btn" onclick="reloadAll()">تحديث</button></div>\n<div id="executedSummary" class="mini-kpis"></div>\n<div class="card" style="margin-bottom:12px"><div class="filters" style="margin-bottom:0"><label>من تاريخ التنفيذ<input id="executedFrom" type="date" onchange="renderExecutedPayments()"></label><label>إلى تاريخ التنفيذ<input id="executedTo" type="date" onchange="renderExecutedPayments()"></label><select id="executedRegFilter" onchange="renderExecutedPayments()"><option value="">كل مراحل التسجيل</option><option value="unregistered">بانتظار التسجيل</option><option value="registered">تم التسجيل</option></select><button class="btn" onclick="clearExecutedFilters()">مسح الفلاتر</button></div></div>\n<div class="table-wrap"><table id="executedPaymentsTable"><thead><tr><th>تاريخ التنفيذ</th><th>الشركة</th><th>المستفيد</th><th>المبلغ</th><th>الحساب</th><th>الحالة</th><th>تاريخ التسجيل</th><th>SLA التسجيل</th><th>الوقت المتبقي</th><th>الإجراء</th></tr></thead><tbody id="executedPaymentsBody"></tbody></table></div>\n</section>\n'''
pay=pay.replace('</section>\n<section id="posted"','</section>'+executed+'<section id="posted"',1)
s=s[:m.start()]+pay+s[m.end():]

# Replace Imprest section with settlement-aware monitoring/workflow.
old_imp=re.search(r'<section id="imprest" class="section">.*?</section>',s,re.S)
if not old_imp: raise SystemExit('imprest section not found')
imp='''<section id="imprest" class="section">\n<div class="row" style="margin-bottom:12px"><div><h3 style="margin:0">العهد</h3><div class="muted">متابعة أرصدة العهد وملفات التصفية المفتوحة حتى اعتماد المشرف.</div></div><button id="addImprestBtn" class="btn primary" type="button" onclick="openImprestModal()">+ إضافة عهدة</button></div>\n<div class="table-wrap"><table id="imprestTable"><thead><tr><th>النوع</th><th>الشركة</th><th>العهدة</th><th>المسؤول</th><th>الرصيد</th><th>غير مسوى</th><th>تحت التصفية</th><th>متاح للتصفية</th><th>مصفي معتمد</th><th>العمر</th><th>الحالة</th><th>إجراء</th></tr></thead><tbody id="imprestBody"></tbody></table></div>\n<div class="row" style="margin:18px 0 10px"><div><h3 style="margin:0">ملفات تصفية العهد</h3><div class="muted">كل ملف تصفية مرتبط بمهمة فعلية في مركز العمل ويخضع لمراجعة المشرف.</div></div></div>\n<div class="table-wrap"><table id="imprestSettlementsTable"><thead><tr><th>الاستلام</th><th>العهدة</th><th>الموظف</th><th>المبلغ</th><th>عدد الفواتير</th><th>موعد المهمة</th><th>حالة التصفية</th><th>حالة المهمة</th><th>المراجعة</th><th>إجراء</th></tr></thead><tbody id="imprestSettlementsBody"></tbody></table></div>\n</section>'''
s=s[:old_imp.start()]+imp+s[old_imp.end():]

# State variables.
s=s.replace('imprest=[],performance=[]','imprest=[],imprestSettlements=[],imprestFundSummary=[],performance=[]',1)

# Page access add executed where appropriate.
s=s.replace('"payments","posted","pending"','"payments","executed","posted","pending"')
s=s.replace('"payments","posted","tasks"','"payments","executed","posted","tasks"')

# Translation additions.
anchor='Object.assign(I18N_AR_EN,{'
idx=s.find(anchor)
if idx<0: raise SystemExit('translation anchor missing')
trans='''Object.assign(I18N_AR_EN,{"الاعتمادات المنفذة":"Executed Approvals","الاعتمادات المعلقة":"Pending Approvals","الاعتمادات المرحلة":"Posted Approvals","من تاريخ التنفيذ":"Execution Date From","إلى تاريخ التنفيذ":"Execution Date To","كل مراحل التسجيل":"All Registration Stages","بانتظار التسجيل":"Awaiting Registration","تم التسجيل":"Registered","SLA التسجيل":"Registration SLA","الوقت المتبقي":"Time Remaining","تحت التصفية":"Under Settlement","متاح للتصفية":"Available to Settle","مصفي معتمد":"Approved Settlements","ملفات تصفية العهد":"Imprest Settlement Files","فتح تصفية عهدة":"Open Imprest Settlement","عدد الفواتير":"Invoice Count","تاريخ استلام الملف":"File Received At","حالة التصفية":"Settlement Status","فتح المهمة":"Open Task"});\n'''
s=s[:idx]+trans+s[idx:]

# Permission key.
s=s.replace("['page.payments','المدفوعات والاعتمادات'],['page.posted'","['page.payments','المدفوعات والاعتمادات'],['page.executed','الاعتمادات المنفذة'],['page.posted'",1)

# Load settlement data after core assignment.
needle='imprest=im.data||[];performance=pf.data||[];ownership=ow.data||[];'
if needle not in s: raise SystemExit('reload core anchor missing')
s=s.replace(needle,needle+"\n const [isr,ifs]=await Promise.all([sb.rpc('get_imprest_settlement_register'),sb.rpc('get_imprest_fund_summary')]);imprestSettlements=isr.data||[];imprestFundSummary=ifs.data||[];",1)

# Render all adds executed and settlement render.
s=s.replace("['payments',renderPayments],['accountingQueue',renderAccountingQueue]","['payments',renderPayments],['executedPayments',renderExecutedPayments]",1)
s=s.replace("['imprest',renderImprest],['performance'","['imprest',renderImprest],['imprestSettlements',renderImprestSettlements],['performance'",1)

# Replace renderPayments active filtering and inject executed renderer before paymentActions.
old_render=re.search(r'function renderPayments\(\)\{.*?\n\}',s,re.S)
if not old_render: raise SystemExit('renderPayments not found')
block=old_render.group(0)
block=block.replace('const active=payments.filter(p=>p.status!=="مرحّل"&&p.status!=="معلقة"),posted=payments.filter(p=>p.status==="مرحّل"),pending=payments.filter(p=>p.status==="معلقة");','const active=payments.filter(p=>!p.executed_at&&!p.posted_at&&p.status!=="معلقة"),posted=payments.filter(p=>!!p.posted_at||p.status==="مرحّل"),pending=payments.filter(p=>p.status==="معلقة");')
s=s[:old_render.start()]+block+s[old_render.end():]

anchor2='function paymentActions(p)'
if anchor2 not in s: raise SystemExit('paymentActions anchor missing')
executed_js=r'''function clearExecutedFilters(){['executedFrom','executedTo','executedRegFilter'].forEach(id=>{const e=document.getElementById(id);if(e)e.value=''});renderExecutedPayments()}
function paymentSlaInfo(p){if(!p.executed_at)return {label:'—',cls:'',remaining:'—'};const deadline=new Date(new Date(p.executed_at).getTime()+48*3600000);const reg=p.accounting_registered_at?new Date(p.accounting_registered_at):null;if(reg){const ontime=reg<=deadline;return {label:ontime?'تم التسجيل داخل المهلة':'تم التسجيل متأخرًا',cls:ontime?'sla-ok':'sla-overdue',remaining:'مكتمل'}}const hours=(deadline-Date.now())/3600000;if(hours<0)return {label:'متجاوز المهلة',cls:'sla-overdue',remaining:`${Math.abs(hours).toFixed(1)}h متأخر`};if(hours<=12)return {label:'قرب انتهاء المهلة',cls:'sla-due',remaining:`${hours.toFixed(1)}h`};return {label:'داخل المهلة',cls:'sla-ok',remaining:`${hours.toFixed(1)}h`}}
function renderExecutedPayments(){const body=document.getElementById('executedPaymentsBody'),sum=document.getElementById('executedSummary');if(!body||!sum)return;let rows=payments.filter(p=>p.executed_at&&!p.posted_at&&p.status!=='معلقة');const from=document.getElementById('executedFrom')?.value,to=document.getElementById('executedTo')?.value,rf=document.getElementById('executedRegFilter')?.value;if(from)rows=rows.filter(p=>String(p.executed_at).slice(0,10)>=from);if(to)rows=rows.filter(p=>String(p.executed_at).slice(0,10)<=to);if(rf==='registered')rows=rows.filter(p=>!!p.accounting_registered_at);if(rf==='unregistered')rows=rows.filter(p=>!p.accounting_registered_at);const overdue=rows.filter(p=>!p.accounting_registered_at&&new Date(p.executed_at).getTime()+48*3600000<Date.now()).length,registered=rows.filter(p=>!!p.accounting_registered_at).length;sum.innerHTML=`<div class="card"><span class="muted">${displayText('عدد الدفعات')}</span><b>${latinDigits(rows.length)}</b></div><div class="card"><span class="muted">${displayText('بانتظار التسجيل')}</span><b>${latinDigits(rows.length-registered)}</b></div><div class="card"><span class="muted">${displayText('تم التسجيل')}</span><b>${latinDigits(registered)}</b></div><div class="card"><span class="muted">${displayText('متجاوز المهلة')}</span><b>${latinDigits(overdue)}</b></div>`;body.innerHTML=rows.map(p=>{const sla=paymentSlaInfo(p);return `<tr class="${sla.cls==='sla-overdue'&&!p.accounting_registered_at?'task-overdue':''}"><td>${fmt(p.executed_at)}</td><td>${esc(p.company)}</td><td>${esc(p.beneficiary)}</td><td>${moneyHtml(p.amount)}</td><td>${esc(bankLabel(p))}</td><td>${badge(p.status)}</td><td>${p.accounting_registered_at?fmt(p.accounting_registered_at):'—'}</td><td><span class="badge ${sla.cls}">${displayText(sla.label)}</span></td><td>${esc(displayText(sla.remaining))}</td><td>${paymentActions(p)}</td></tr>`}).join('')||`<tr><td colspan="10" class="muted">—</td></tr>`;applyTableFilters(document.getElementById('executedPaymentsTable'))}
'''
s=s.replace(anchor2,executed_js+anchor2,1)

# Replace renderImprest and add settlement helpers.
old_ri=re.search(r'function renderImprest\(\)\{.*?\n\}',s,re.S)
if not old_ri: raise SystemExit('renderImprest not found')
imp_js=r'''function imprestSummaryFor(id){return imprestFundSummary.find(x=>x.imprest_fund_id===id)||{under_settlement:0,approved_settlements:0,available_to_settle:0}}
function renderImprest(){imprestBody.innerHTML=imprest.map(x=>{const sm=imprestSummaryFor(x.id);const canOpen=['CFO','Supervisor','BankAccountant','APAccountant'].includes(profile.role);return `<tr><td>${esc(x.type)}</td><td>${esc(x.company)}</td><td>${esc(x.name)}</td><td>${esc(x.custodian?.full_name||'—')}</td><td>${moneyHtml(x.balance)}</td><td>${moneyHtml(x.unsettled)}</td><td>${moneyHtml(sm.under_settlement||0)}</td><td>${moneyHtml(sm.available_to_settle||0)}</td><td>${moneyHtml(sm.approved_settlements||0)}</td><td>${Number(x.aging||0)} يوم</td><td>${badge(x.status)}</td><td>${canOpen?`<button class="btn primary" onclick="openImprestSettlementModal('${x.id}')">${displayText('فتح تصفية عهدة')}</button>`:'—'}</td></tr>`}).join('')||`<tr><td colspan="12" class="muted">${displayText('لا توجد عهد مسجلة حتى الآن.')}</td></tr>`;applyTableFilters(document.getElementById('imprestTable'))}
function settlementStatusLabel(s){return ({'In Progress':'قيد التنفيذ','Pending Review':'بانتظار المراجعة','Returned for Rework':'إعادة للعمل','Approved':'مكتمل','Cancelled':'ملغي'})[s]||s}
function renderImprestSettlements(){const body=document.getElementById('imprestSettlementsBody');if(!body)return;body.innerHTML=(imprestSettlements||[]).map(x=>{const canReview=['CFO','Supervisor'].includes(profile.role)&&x.task_status==='بانتظار المراجعة';const mine=x.handler_id===profile.id;const actions=[`<button class="btn" onclick="openTaskWorkspace('${x.task_id}')">${displayText('فتح المهمة')}</button>`];if(mine&&x.task_status==='قيد التنفيذ')actions.push(`<button class="btn success" onclick="completeTask('${x.task_id}')">${displayText('إرسال للمراجعة')}</button>`);if(canReview){actions.push(`<button class="btn success" onclick="reviewTask('${x.task_id}',true)">${displayText('اعتماد المهمة')}</button>`);actions.push(`<button class="btn" onclick="reviewTask('${x.task_id}',false)">${displayText('إعادة للعمل')}</button>`)}return `<tr><td>${fmt(x.received_at)}</td><td>${esc(x.imprest_name)}</td><td>${esc(x.handler_name||'—')}</td><td>${moneyHtml(x.amount)}</td><td>${latinDigits(x.invoice_count||0)}</td><td>${esc(x.due_date||'—')} ${esc(x.due_time?String(x.due_time).slice(0,5):'')}</td><td>${badge(settlementStatusLabel(x.settlement_status))}</td><td>${badge(x.task_status||'—')}</td><td>${x.reviewed_at?fmt(x.reviewed_at):'—'}</td><td>${actions.join(' ')}</td></tr>`}).join('')||`<tr><td colspan="10" class="muted">—</td></tr>`;applyTableFilters(document.getElementById('imprestSettlementsTable'))}
function openImprestSettlementModal(id){if(!['CFO','Supervisor','BankAccountant','APAccountant'].includes(profile.role))return;const f=imprest.find(x=>x.id===id);if(!f)return;showModal(displayText('فتح تصفية عهدة'),`<div class="note">${esc(f.company)} — ${esc(f.name)} | ${displayText('غير مسوى')}: ${moneyHtml(f.unsettled)}</div><div class="modal-grid" style="margin-top:12px">${input('is_amount','المبلغ','','number')}${input('is_invoices','عدد الفواتير','','number')}${input('is_due_date','تاريخ التسليم','','date')}${input('is_due_time','وقت التسليم','','time')}${select('is_priority','الأولوية',['عادي','عالي','حرج'])}</div><label style="margin-top:10px">${displayText('ملاحظات')}</label><textarea id="is_notes" rows="3"></textarea><div class="row" style="margin-top:14px"><button class="btn primary" onclick="saveImprestSettlement('${id}')">${displayText('فتح المهمة')}</button></div>`)}
async function saveImprestSettlement(id){const amount=Number(val('is_amount')||0),count=Number(val('is_invoices')||0),due=val('is_due_date'),time=val('is_due_time');if(amount<=0||count<1||!due||!time)return alert(currentLang==='en'?'Amount, invoice count, due date and due time are required.':'المبلغ وعدد الفواتير وتاريخ ووقت التسليم حقول إلزامية.');const {error}=await sb.rpc('open_imprest_settlement_task',{p_fund_id:id,p_amount:amount,p_invoice_count:count,p_due_date:due,p_due_time:time,p_priority:val('is_priority')||'عادي',p_notes:val('is_notes')||null});if(error)return alert(error.message);closeModal();await reloadAll();openPage('imprest',displayText('العهد'))}
'''
s=s[:old_ri.start()]+imp_js+s[old_ri.end():]

p.write_text(s,encoding='utf-8')
