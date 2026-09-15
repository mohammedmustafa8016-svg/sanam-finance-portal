from pathlib import Path
import re

p=Path('index.html')
s=p.read_text()
marker='/* UNIVERSAL_COLUMN_CUSTOMIZATION_2026_09_15 */'
if marker in s:
    print('already patched'); raise SystemExit(0)

s=s.replace('/* PAYMENT_LIST_COLUMN_VISIBILITY_2026_09_15 */','/* PAYMENT_LIST_COLUMN_VISIBILITY_2026_09_15 */\n'+marker,1)

# Remove the one-off payment-only column button. Universal controls will be injected for every eligible table.
s=s.replace('<button id="paymentColumnsBtn" class="btn" type="button" onclick="openPaymentColumnSettings()">تخصيص الأعمدة</button>','',1)

old_header='<table id="paymentsTable"><thead><tr><th>الاستحقاق</th><th>الشركة</th><th>المستفيد</th><th>المبلغ</th><th>الحساب</th><th>المشرف</th><th>CFO</th><th>الحالة</th><th>إجراء</th></tr></thead><tbody id="paymentsBody"></tbody></table>'
new_header='<table id="paymentsTable"><thead><tr><th>الاستحقاق</th><th>الشركة</th><th>المستفيد</th><th>المبلغ</th><th>الحساب</th><th data-default-hidden="1">الغرض</th><th data-default-hidden="1">الأولوية</th><th data-default-hidden="1">المستندات</th><th>المشرف</th><th>CFO</th><th>الحالة</th><th>إجراء</th></tr></thead><tbody id="paymentsBody"></tbody></table>'
assert old_header in s, 'payment table header not found'
s=s.replace(old_header,new_header,1)

old_render='function renderPayments(){const active=payments.filter(p=>p.status!=="مرحّل"),posted=payments.filter(p=>p.status==="مرحّل");paymentsBody.innerHTML=active.map(p=>`<tr><td>${esc(p.due_date)}</td><td>${esc(p.company)}</td><td>${esc(p.beneficiary)}</td><td>${moneyHtml(p.amount)}</td><td>${esc(bankLabel(p))}</td><td>${badge(p.supervisor_status)}</td><td>${badge(p.cfo_status)}</td><td>${badge(p.status)}</td><td>${paymentActions(p)}</td></tr>`).join("");postedBody.innerHTML=posted.map(p=>`<tr><td>${fmt(p.posted_at)}</td><td>${esc(p.company)}</td><td>${esc(p.beneficiary)}</td><td>${moneyHtml(p.amount)}</td><td>${esc(bankLabel(p))}</td><td>${esc(p.purpose||"—")}</td></tr>`).join("");applyPaymentColumnVisibility()}'
new_render='function renderPayments(){const active=payments.filter(p=>p.status!=="مرحّل"),posted=payments.filter(p=>p.status==="مرحّل");paymentsBody.innerHTML=active.map(p=>`<tr><td>${esc(p.due_date)}</td><td>${esc(p.company)}</td><td>${esc(p.beneficiary)}</td><td>${moneyHtml(p.amount)}</td><td>${esc(bankLabel(p))}</td><td style="white-space:normal;min-width:220px">${esc(p.purpose||"—")}</td><td>${badge(p.priority||"عادي")}</td><td>${badge(p.documents_status||"—")}</td><td>${badge(p.supervisor_status)}</td><td>${badge(p.cfo_status)}</td><td>${badge(p.status)}</td><td>${paymentActions(p)}</td></tr>`).join("");postedBody.innerHTML=posted.map(p=>`<tr><td>${fmt(p.posted_at)}</td><td>${esc(p.company)}</td><td>${esc(p.beneficiary)}</td><td>${moneyHtml(p.amount)}</td><td>${esc(bankLabel(p))}</td><td>${esc(p.purpose||"—")}</td></tr>`).join("");applyPaymentColumnVisibility()}'
assert old_render in s, 'renderPayments not found'
s=s.replace(old_render,new_render,1)

# Universal per-user/per-table visibility framework. It works on every main page table, preserving existing columns as defaults.
universal = r'''
const UNIVERSAL_COLUMN_PREF_PREFIX='sanam_columns_v2';
function universalColumnStorageKey(table){return `${UNIVERSAL_COLUMN_PREF_PREFIX}_${profile?.id||'default'}_${table.dataset.columnTableKey}`}
function universalTableKey(table){
 if(table.dataset.columnTableKey)return table.dataset.columnTableKey;
 const section=table.closest('.section');
 const sectionId=section?.id||'page';
 const tables=[...(section?.querySelectorAll('.table-wrap table')||[])];
 const idx=Math.max(0,tables.indexOf(table));
 const key=`${sectionId}_${table.id||('table'+(idx+1))}`;
 table.dataset.columnTableKey=key;
 return key;
}
function universalColumnDefs(table){
 universalTableKey(table);
 return [...table.querySelectorAll('thead tr:first-child th')].map((th,i)=>{
   if(!th.dataset.universalColKey)th.dataset.universalColKey=th.dataset.colKey||`c${i+1}`;
   if(!th.dataset.universalLabel){const clone=th.cloneNode(true);clone.querySelectorAll('button,.filter-arrow').forEach(x=>x.remove());th.dataset.universalLabel=(clone.textContent||'').trim()||`Column ${i+1}`;}
   return {key:th.dataset.universalColKey,label:th.dataset.universalLabel,index:i+1,defaultVisible:th.dataset.defaultHidden!=='1'};
 })
}
function universalVisibleSet(table){
 const defs=universalColumnDefs(table),fallback=defs.filter(d=>d.defaultVisible).map(d=>d.key);
 try{const raw=localStorage.getItem(universalColumnStorageKey(table));if(!raw)return new Set(fallback);const v=JSON.parse(raw);return new Set(Array.isArray(v)&&v.length?v:fallback)}catch{return new Set(fallback)}
}
function applyUniversalColumnVisibility(table){
 if(!table)return;const visible=universalVisibleSet(table);const defs=universalColumnDefs(table);
 defs.forEach(d=>table.querySelectorAll(`tr > *:nth-child(${d.index})`).forEach(el=>el.classList.toggle('hidden',!visible.has(d.key))));
}
function openUniversalColumnSettings(tableKey){
 const table=[...document.querySelectorAll('.section .table-wrap table')].find(t=>universalTableKey(t)===tableKey);if(!table)return;
 const defs=universalColumnDefs(table),current=universalVisibleSet(table);
 showModal(displayText('تخصيص الأعمدة'),`<div class="note">${displayText('حدد الأعمدة التي تريد ظهورها في هذا الجدول. يتم حفظ الاختيار لهذا المستخدم على هذا الجهاز دون تغيير البيانات.')}</div><div class="report-columns" style="margin-top:12px">${defs.map(d=>`<label><input type="checkbox" class="universal-column-choice" value="${d.key}" ${current.has(d.key)?'checked':''}> ${displayText(d.label)}</label>`).join('')}</div><div class="row" style="margin-top:14px"><div class="lang-actions"><button class="btn" onclick="resetUniversalColumns('${tableKey}',false)">${displayText('استعادة الافتراضي')}</button><button class="btn" onclick="resetUniversalColumns('${tableKey}',true)">${displayText('إظهار الكل')}</button></div><button class="btn primary" onclick="saveUniversalColumns('${tableKey}')">${displayText('حفظ')}</button></div>`)
}
function saveUniversalColumns(tableKey){
 const table=[...document.querySelectorAll('.section .table-wrap table')].find(t=>universalTableKey(t)===tableKey);if(!table)return;
 const selected=[...document.querySelectorAll('.universal-column-choice:checked')].map(x=>x.value);if(!selected.length)return alert(displayText('يجب اختيار عمود واحد على الأقل.'));
 localStorage.setItem(universalColumnStorageKey(table),JSON.stringify(selected));closeModal();applyUniversalColumnVisibility(table);installTableFilters();
}
function resetUniversalColumns(tableKey,showAll){
 const table=[...document.querySelectorAll('.section .table-wrap table')].find(t=>universalTableKey(t)===tableKey);if(!table)return;
 const defs=universalColumnDefs(table),values=(showAll?defs:defs.filter(d=>d.defaultVisible)).map(d=>d.key);
 localStorage.setItem(universalColumnStorageKey(table),JSON.stringify(values));closeModal();applyUniversalColumnVisibility(table);installTableFilters();
}
function installUniversalColumnCustomizers(){
 document.querySelectorAll('.section .table-wrap table').forEach(table=>{
   const wrap=table.closest('.table-wrap');if(!wrap)return;const key=universalTableKey(table);universalColumnDefs(table);
   let bar=wrap.previousElementSibling;
   if(!(bar&&bar.classList.contains('column-customizer-bar'))){bar=document.createElement('div');bar.className='row column-customizer-bar';bar.style.cssText='justify-content:flex-end;margin:6px 0';wrap.parentNode.insertBefore(bar,wrap)}
   bar.innerHTML=`<button class="btn" type="button" onclick="openUniversalColumnSettings('${key}')">${displayText('تخصيص الأعمدة')}</button>`;
   applyUniversalColumnVisibility(table);
 });
}
// Compatibility with the previous payment-only control. The universal framework now owns visibility.
function applyPaymentColumnVisibility(){const t=document.getElementById('paymentsTable');if(t&&t.dataset.columnTableKey)applyUniversalColumnVisibility(t)}
'''

needle='function renderAll(){renderBanks();renderPayments();renderSavedViews();renderTasks();renderControlCenter();renderWorkload();renderEscalations();renderAutomationHealth();renderClose();renderImprest();renderPerformance();renderOwnership();renderExceptions();renderDashboard();installTableFilters();applyLanguage()}'
replacement=universal+'\nfunction renderAll(){renderBanks();renderPayments();renderSavedViews();renderTasks();renderControlCenter();renderWorkload();renderEscalations();renderAutomationHealth();renderClose();renderImprest();renderPerformance();renderOwnership();renderExceptions();renderDashboard();installUniversalColumnCustomizers();installTableFilters();applyLanguage()}'
assert needle in s, 'renderAll not found'
s=s.replace(needle,replacement,1)

# Add translations used by the universal control and the newly exposed payment fields.
i18n='''Object.assign(I18N_AR_EN,{'''
assert i18n in s
s=s.replace(i18n,'''Object.assign(I18N_AR_EN,{\n"استعادة الافتراضي":"Restore Default","حدد الأعمدة التي تريد ظهورها في هذا الجدول. يتم حفظ الاختيار لهذا المستخدم على هذا الجهاز دون تغيير البيانات.":"Select the columns to show in this table. The choice is saved for this user on this device without changing data.","الغرض":"Purpose","المستندات":"Documents",''',1)

p.write_text(s)
print('patched universal columns')
