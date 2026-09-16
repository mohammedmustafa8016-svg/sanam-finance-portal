from pathlib import Path

p=Path('index.html')
s=p.read_text()
marker='/* AUDIT_REFRESH_FIX_2026_09_16 */'
if marker in s:
    print('already patched')
    raise SystemExit(0)

s=s.replace('/* FILTER_RESERVE_PENDING_2026_09_16 */','/* FILTER_RESERVE_PENDING_2026_09_16 */\n'+marker,1)

old_section='<section id="audit" class="section"><div class="row" style="margin-bottom:12px"><h3>سجل العمليات</h3><button class="btn" onclick="loadAudit()">تحديث</button></div><div class="table-wrap"><table><thead><tr><th>التاريخ</th><th>المستخدم</th><th>الإجراء</th><th>الكيان</th><th>المعرف</th></tr></thead><tbody id="auditBody"></tbody></table></div></section>'
new_section='<section id="audit" class="section"><div class="row" style="margin-bottom:12px"><div><h3 style="margin:0">سجل العمليات</h3><div id="auditRefreshStatus" class="muted" style="margin-top:4px"></div></div><button id="auditRefreshBtn" class="btn" type="button" onclick="loadAudit(true)">تحديث</button></div><div class="table-wrap"><table id="auditTable"><thead><tr><th>التاريخ</th><th>المستخدم</th><th>الإجراء</th><th>الكيان</th><th>المعرف</th></tr></thead><tbody id="auditBody"></tbody></table></div></section>'
assert old_section in s, 'audit section not found'
s=s.replace(old_section,new_section,1)

old_func='async function loadAudit(){if(profile.role!=="CFO")return;const {data,error}=await sb.from("audit_log").select("*,actor:profiles!audit_log_actor_id_fkey(full_name,email)").order("created_at",{ascending:false}).limit(200);if(error){auditBody.innerHTML=`<tr><td colspan="5">${esc(error.message)}</td></tr>`;return}auditBody.innerHTML=(data||[]).map(x=>`<tr><td>${fmt(x.created_at)}</td><td>${esc(x.actor?.full_name||x.actor?.email||"—")}</td><td>${esc(x.action)}</td><td>${esc(x.entity_type||"—")}</td><td>${esc(x.entity_id||"—")}</td></tr>`).join("")}'
new_func='''async function loadAudit(showFeedback=false){\n if(profile.role!=="CFO")return;\n const btn=document.getElementById("auditRefreshBtn"),status=document.getElementById("auditRefreshStatus");\n const oldText=btn?.textContent||displayText("تحديث");\n if(btn){btn.disabled=true;btn.textContent=currentLang==="en"?"Refreshing...":"جارٍ التحديث..."}\n if(status&&showFeedback)status.textContent=currentLang==="en"?"Loading latest audit records...":"جارٍ تحميل أحدث سجل للعمليات...";\n const {data,error}=await sb.from("audit_log").select("*,actor:profiles!audit_log_actor_id_fkey(full_name,email)").order("created_at",{ascending:false}).limit(200);\n if(error){auditBody.innerHTML=`<tr><td colspan="5">${esc(error.message)}</td></tr>`;if(status)status.textContent=currentLang==="en"?"Refresh failed":"تعذر تحديث السجل";if(btn){btn.disabled=false;btn.textContent=oldText}return}\n auditBody.innerHTML=(data||[]).map(x=>`<tr><td>${fmt(x.created_at)}</td><td>${esc(x.actor?.full_name||x.actor?.email||"—")}</td><td>${esc(x.action)}</td><td>${esc(x.entity_type||"—")}</td><td>${esc(x.entity_id||"—")}</td></tr>`).join("");\n const table=document.getElementById("auditTable");if(table){applyTableFilters(table);applyUniversalColumnVisibility?.(table)}\n if(status)status.textContent=(currentLang==="en"?"Last refreshed: ":"آخر تحديث: ")+new Date().toLocaleTimeString(currentLang==="en"?"en-US":"ar-SA");\n if(btn){btn.disabled=false;btn.textContent=displayText("تحديث")}\n}'''
assert old_func in s, 'loadAudit function not found'
s=s.replace(old_func,new_func,1)
p.write_text(s)
