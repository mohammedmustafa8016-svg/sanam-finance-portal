from pathlib import Path
p=Path('index.html')
s=p.read_text(encoding='utf-8')
marker='WORKFLOW_ENGINE_V3_UI_2026_09_17'
if marker in s:
    print('Workflow V3 UI already applied')
    raise SystemExit(0)

s=s.replace('/* UI_FILTER_COLUMN_RESERVE_HOTFIX_2026_09_16 */','/* UI_FILTER_COLUMN_RESERVE_HOTFIX_2026_09_16 */\n/* WORKFLOW_ENGINE_V3_UI_2026_09_17 */',1)
css='''\n.workflow-toolbar{display:flex;gap:7px;flex-wrap:wrap;margin-bottom:12px}.workflow-toolbar .btn.active{background:var(--nav);color:#fff;border-color:var(--nav)}\n.workflow-kpis{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:10px;margin-bottom:12px}.workflow-kpis .card{padding:11px}.workflow-kpis b{font-size:19px;display:block;margin-top:3px}.workflow-source{font-size:11px;color:var(--muted)}.workflow-due-late{color:var(--red);font-weight:700}.workflow-stage{white-space:normal;min-width:150px}.workflow-empty{padding:20px;text-align:center;color:var(--muted)}\n@media(max-width:1000px){.workflow-kpis{grid-template-columns:repeat(3,minmax(0,1fr))}}@media(max-width:620px){.workflow-kpis{grid-template-columns:1fr 1fr}}\n'''
s=s.replace('</style>',css+'</style>',1)

old='<button class="nav" data-page="tasks">المهام</button><button class="nav" data-page="control">التحكم اليومي</button>'
new='<button class="nav" data-page="tasks">المهام</button><button class="nav" data-page="workflow">سير العمل</button><button class="nav" data-page="control">التحكم اليومي</button>'
if old not in s: raise SystemExit('NAV anchor missing')
s=s.replace(old,new,1)

start=s.index('<section id="tasks"')
end=s.index('</section>',start)+len('</section>')
section='''\n<section id="workflow" class="section"><div class="row" style="margin-bottom:12px"><div><h3 style="margin:0">مركز سير العمل</h3><div class="muted">مساحة عمل موحدة للمهام اليدوية ومراحل المدفوعات والتنفيذ البنكي والتسجيل المحاسبي. السجلات الأصلية تظل في وحداتها الحالية.</div></div><button class="btn" onclick="loadWorkflowCenter(workflowScope)">تحديث</button></div>\n<div class="workflow-toolbar"><button id="workflowActiveBtn" class="btn active" onclick="workflowSetScope('ACTIVE')">نشط الآن</button><button id="workflowCompletedBtn" class="btn" onclick="workflowSetScope('COMPLETED_TODAY')">مكتمل اليوم</button><button id="workflowAllBtn" class="btn" onclick="workflowSetScope('ALL')">الكل</button></div>\n<div id="workflowKpis" class="workflow-kpis"></div>\n<div class="table-wrap"><table id="workflowTable"><thead><tr><th>عنصر العمل</th><th>النوع</th><th>المصدر</th><th>المسؤول</th><th>المراجع</th><th>المرحلة الحالية</th><th>الحالة</th><th>الموعد</th><th>إجراء</th></tr></thead><tbody id="workflowBody"></tbody></table></div>\n<div class="card monitor-section"><div class="row"><div><h3 style="margin:0">إنجاز العمل اليوم</h3><div class="muted">يجمع المهام اليدوية وWork Items الناتجة من العمليات الفعلية دون احتساب المهمة اليدوية مرتين.</div></div></div><div class="table-wrap" style="margin-top:10px"><table id="workflowPerformanceTable"><thead><tr><th>الموظف</th><th>الدور</th><th>إجمالي المنجز</th><th>مهام يدوية</th><th>عمليات / معاملات</th><th>في الموعد</th><th>متأخر</th><th>نسبة الالتزام</th><th>وحدات العمل</th></tr></thead><tbody id="workflowPerformanceBody"></tbody></table></div></div></section>'''
s=s[:end]+section+s[end:]

anchor='let taskOperationalStartDate="2026-09-17";let activeTaskView=localStorage.getItem("sanam_task_view")||"all",closeQuickView=false;'
if anchor not in s: raise SystemExit('GLOBAL anchor missing')
s=s.replace(anchor,anchor+'let workflowQueue=[],workflowCompletedToday=[],workflowPerformance=[],workflowScope="ACTIVE";',1)

pa_start=s.index('const PAGE_ACCESS=')
pa_end=s.index(';',pa_start)+1
pa=s[pa_start:pa_end]
pa2=pa.replace('"tasks",','"tasks","workflow",')
if pa2==pa: raise SystemExit('PAGE_ACCESS anchor missing')
s=s[:pa_start]+pa2+s[pa_end:]

tr='''\nObject.assign(I18N_AR_EN,{"سير العمل":"Workflow","مركز سير العمل":"Workflow Center","مساحة عمل موحدة للمهام اليدوية ومراحل المدفوعات والتنفيذ البنكي والتسجيل المحاسبي. السجلات الأصلية تظل في وحداتها الحالية.":"Unified workspace for manual tasks, payment stages, bank execution and accounting registration. Source records remain in their existing modules.","نشط الآن":"Active Now","مكتمل اليوم":"Completed Today","الكل":"All","عنصر العمل":"Work Item","المصدر":"Source","المرحلة الحالية":"Current Stage","إنجاز العمل اليوم":"Today's Work Completion","يجمع المهام اليدوية وWork Items الناتجة من العمليات الفعلية دون احتساب المهمة اليدوية مرتين.":"Combines manual tasks and transaction-generated work items without double-counting manual tasks.","إجمالي المنجز":"Total Completed","مهام يدوية":"Manual Tasks","عمليات / معاملات":"Transactions","في الموعد":"On Time","نسبة الالتزام":"On-Time Rate","وحدات العمل":"Work Units","Ready":"Ready","Waiting":"Waiting","In Progress":"In Progress","Pending Review":"Pending Review","Completed":"Completed","Blocked":"Blocked","Cancelled":"Cancelled","مهمة يدوية":"Manual Task","اعتماد المشرف للدفعة":"Payment Supervisor Approval","اعتماد المدير المالي للدفعة":"Payment CFO Approval","تنفيذ بنكي":"Bank Execution","تسجيل محاسبي":"Accounting Registration","ترحيل وإقفال":"Posting & Closure","عرض المسار":"View Timeline","فتح المصدر":"Open Source","لا توجد عناصر عمل في هذا العرض.":"No work items in this view.","لا توجد بيانات أداء لليوم.":"No performance data for today."});\n'''
anchor='function displayText(v){return tr(v)}'
if anchor not in s: raise SystemExit('I18N anchor missing')
s=s.replace(anchor,tr+anchor,1)

perm="['page.tasks','المهام'],"
if perm in s:
    s=s.replace(perm,perm+"['page.workflow','سير العمل'],",1)
else:
    raise SystemExit('PERMISSION_KEYS anchor missing')

op="if(id===\"audit\")loadAudit();if(id==='permissions')loadPermissionsAdmin()"
if op not in s: raise SystemExit('openPage anchor missing')
s=s.replace(op,op+";if(id==='workflow')loadWorkflowCenter(workflowScope)",1)

funcs=r'''
function workflowTypeLabel(t){return {MANUAL_TASK:'مهمة يدوية',PAYMENT_SUPERVISOR_APPROVAL:'اعتماد المشرف للدفعة',PAYMENT_CFO_APPROVAL:'اعتماد المدير المالي للدفعة',PAYMENT_BANK_EXECUTION:'تنفيذ بنكي',PAYMENT_ACCOUNTING_REGISTRATION:'تسجيل محاسبي',PAYMENT_POSTING_FINALIZATION:'ترحيل وإقفال'}[t]||t}
function workflowStatusBadge(s){let c='';if(s==='Completed')c='green';else if(['Ready','Pending Review','Waiting'].includes(s))c='amber';else if(['Blocked','Cancelled'].includes(s))c='red';return `<span class="badge ${c}">${esc(displayText(s||'—'))}</span>`}
function workflowSourceLabel(x){return x==='payment'?(currentLang==='en'?'Payment':'دفعة'):x==='task'?(currentLang==='en'?'Task':'مهمة'):x||'—'}
function workflowDueHtml(d,status){if(!d)return '—';const late=status!=='Completed'&&new Date(d)<new Date();return `<span class="${late?'workflow-due-late':''}">${fmt(d)}</span>`}
function workflowSetScope(scope){workflowScope=scope;['Active','Completed','All'].forEach(x=>document.getElementById(`workflow${x}Btn`)?.classList.toggle('active',scope===(x==='Active'?'ACTIVE':x==='Completed'?'COMPLETED_TODAY':'ALL')));loadWorkflowCenter(scope)}
async function loadWorkflowCenter(scope=workflowScope){
 workflowScope=scope;
 const today=new Date().toLocaleDateString('en-CA',{timeZone:'Asia/Riyadh'});
 const [q,done,pf]=await Promise.all([sb.rpc('get_my_work_queue',{p_scope:scope}),sb.rpc('get_my_work_queue',{p_scope:'COMPLETED_TODAY'}),sb.rpc('get_workflow_v3_performance',{p_date_from:today,p_date_to:today})]);
 if(q.error){console.error(q.error);workflowQueue=[]}else workflowQueue=q.data||[];
 if(done.error){console.error(done.error);workflowCompletedToday=[]}else workflowCompletedToday=done.data||[];
 if(pf.error){console.error(pf.error);workflowPerformance=[]}else workflowPerformance=pf.data||[];
 renderWorkflowCenter();
}
function renderWorkflowCenter(){
 const box=document.getElementById('workflowBody'),k=document.getElementById('workflowKpis'),pb=document.getElementById('workflowPerformanceBody');if(!box||!k||!pb)return;
 const activeAll=workflowScope==='COMPLETED_TODAY'?workflowCompletedToday:workflowQueue;
 const ready=activeAll.filter(x=>x.status==='Ready').length,inprog=activeAll.filter(x=>x.status==='In Progress').length,review=activeAll.filter(x=>x.status==='Pending Review').length,blocked=activeAll.filter(x=>x.status==='Blocked').length,txn=activeAll.filter(x=>x.source_entity_type==='payment').length;
 k.innerHTML=`<div class="card"><span class="muted">${displayText('Ready')}</span><b>${ready}</b></div><div class="card"><span class="muted">${displayText('In Progress')}</span><b>${inprog}</b></div><div class="card"><span class="muted">${displayText('Pending Review')}</span><b>${review}</b></div><div class="card"><span class="muted">${displayText('Blocked')}</span><b>${blocked}</b></div><div class="card"><span class="muted">${displayText('مكتمل اليوم')}</span><b>${workflowCompletedToday.length}</b><span class="muted">${displayText('عمليات / معاملات')}: ${txn}</span></div>`;
 box.innerHTML=(activeAll||[]).map(w=>`<tr><td><b>${esc(w.title)}</b><div class="workflow-source">${esc(w.source_entity_id||'')}</div></td><td>${esc(displayText(workflowTypeLabel(w.item_type)))}</td><td>${esc(workflowSourceLabel(w.source_entity_type))}</td><td>${esc(w.assignee_name||'—')}</td><td>${esc(w.reviewer_name||'—')}</td><td class="workflow-stage">${esc(displayText(w.current_step_key||'—'))}</td><td>${workflowStatusBadge(w.status)}</td><td>${workflowDueHtml(w.due_at,w.status)}</td><td><div class="task-actions-wrap"><button class="btn" onclick="openWorkflowTimeline('${esc(w.source_entity_type)}','${esc(w.source_entity_id)}','${esc(w.title)}')">${displayText('عرض المسار')}</button><button class="btn" onclick="openWorkflowSource('${esc(w.source_entity_type)}','${esc(w.source_entity_id)}')">${displayText('فتح المصدر')}</button></div></td></tr>`).join('')||`<tr><td colspan="9"><div class="workflow-empty">${displayText('لا توجد عناصر عمل في هذا العرض.')}</div></td></tr>`;
 pb.innerHTML=(workflowPerformance||[]).map(x=>`<tr><td>${esc(x.full_name||'—')}</td><td>${esc(displayText(ROLE_LABEL[x.role]||x.role||'—'))}</td><td>${Number(x.completed_items||0)}</td><td>${Number(x.manual_tasks||0)}</td><td>${Number(x.transaction_items||0)}</td><td>${Number(x.on_time_items||0)}</td><td>${Number(x.late_items||0)}</td><td>${Number(x.on_time_rate||0).toFixed(1)}%</td><td>${Number(x.total_units||0).toFixed(2)}</td></tr>`).join('')||`<tr><td colspan="9">${displayText('لا توجد بيانات أداء لليوم.')}</td></tr>`;
 applyLanguage(document.getElementById('workflow'));installTableFilters();
}
async function openWorkflowTimeline(sourceType,sourceId,title){const {data,error}=await sb.rpc('get_workflow_timeline',{p_source_entity_type:sourceType,p_source_entity_id:String(sourceId)});if(error)return alert(error.message);showModal(`${displayText('سجل النشاط')} — ${title}`,`<div class="task-thread">${(data||[]).map(e=>`<div class="task-thread-item"><div class="task-thread-meta">${fmt(e.event_time)} — ${esc(e.actor_name||'System')} — ${esc(displayText(e.event_type||''))}</div><div class="task-thread-body"><b>${esc(e.title||'')}</b>${e.details?`<div class="muted" style="margin-top:4px">${esc(JSON.stringify(e.details))}</div>`:''}</div></div>`).join('')||'<div class="muted">—</div>'}</div>`)}
function openWorkflowSource(sourceType,sourceId){if(sourceType==='payment'&&canPage('payments'))openPage('payments',displayText('المدفوعات والاعتمادات'));else if(sourceType==='task'&&canPage('tasks'))openPage('tasks',displayText('المهام'));else alert(currentLang==='en'?'Source module is not available for this role.':'وحدة المصدر غير متاحة لهذا الدور.')}
'''
anchor='async function loadAudit(showFeedback=false)'
if anchor not in s: raise SystemExit('FUNCTION anchor missing')
s=s.replace(anchor,funcs+'\n'+anchor,1)

p.write_text(s,encoding='utf-8')
print('Workflow V3 UI patch applied')
