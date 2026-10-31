/* Additive controls above the existing finance engine. BC remains accounting source of truth. */
(() => {
 'use strict';
 const core=window.SanamOperationsCore;
 const T=(ar,en)=>currentLang==='en'?en:ar;
 const $=id=>document.getElementById(id);
 const escText=value=>esc(String(value??''));
 const roleIn=roles=>!!profile&&roles.includes(profile.role)&&!isReadonlyViewer();
 const canImport=()=>roleIn(['CFO','Supervisor','BankAccountant']);
 const canReadBC=()=>roleIn(['CFO','Supervisor','BankAccountant','GLAccountant','APAccountant']);
 const moneyValue=value=>value==null?'—':money(value);
 const number=value=>Number.isFinite(Number(value))?Number(value):0;
 const names={rent:['الإيجارات','Rent'],payroll:['الرواتب','Payroll'],purchases:['المشتريات','Purchases'],contractors:['المقاولون','Contractors'],maintenance:['الصيانة','Maintenance'],fuel:['الوقود','Fuel'],professional:['الخدمات المهنية','Professional services'],travel:['السفر','Travel'],imprest:['العهد','Imprest'],assets:['الأصول','Assets'],government:['الرسوم الحكومية','Government fees'],technology:['اشتراكات التقنية','Technology subscriptions']};
 const labels={source_id:['معرّف السجل الثابت في BC','Stable BC record ID'],amount:['المبلغ','Amount'],currency:['العملة','Currency'],posting_date:['تاريخ القيد / الرصيد','Posting / balance date'],due_date:['تاريخ الاستحقاق','Due date'],document_no:['رقم المستند','Document number'],beneficiary:['المستفيد','Beneficiary'],description:['الوصف','Description'],
 lease:['عقد إيجار ساري','Valid lease'],invoice:['فاتورة','Invoice'],payment_proof:['إثبات السداد','Payment proof'],benefit_period:['فترة الاستفادة','Benefit period'],renewal:['تجديد العقد','Lease renewal'],approved_payroll:['كشف رواتب معتمد','Approved payroll'],bank_transfer:['كشف التحويل البنكي','Bank transfer statement'],approval:['اعتماد المسؤول','Responsible approval'],exception_approval:['اعتماد استثنائي','Exception approval'],settlement:['تسوية معتمدة','Approved settlement'],purchase_approval:['اعتماد شراء','Purchase approval'],receipt:['إثبات استلام','Receipt'],purchase_order:['أمر شراء','Purchase order'],quotations:['عروض الأسعار','Quotations'],goods_receipt:['إذن استلام مخزني','Goods receipt'],contract:['العقد / أمر العمل','Contract / work order'],certified_progress:['مستخلص معتمد','Certified progress'],completion_approval:['اعتماد الإنجاز','Completion approval'],advance_approval:['اعتماد الدفعة المقدمة','Advance approval'],retention_schedule:['بيان الاحتجاز','Retention schedule'],work_order:['أمر صيانة','Maintenance order'],asset_reference:['مرجع الأصل / الموقع','Asset / location reference'],accident_report:['تقرير حادث','Accident report'],vehicle_or_project:['المركبة / المشروع','Vehicle / project'],detail_statement:['كشف تفصيلي','Detailed statement'],agreement:['اتفاقية الخدمة','Service agreement'],service_evidence:['إثبات تقديم الخدمة','Service evidence'],management_approval:['اعتماد الإدارة','Management approval'],tax_review:['مراجعة المعالجة الضريبية','Tax treatment review'],travel_approval:['موافقة السفر','Travel approval'],traveller_and_purpose:['المسافر والغرض','Traveller and purpose'],justification:['مبرر معتمد','Approved justification'],invoices:['فواتير التسوية','Settlement invoices'],settlement_approval:['اعتماد التسوية','Settlement approval'],asset_location:['موقع الأصل','Asset location'],custodian:['المسؤول عن الأصل','Custodian'],asset_id:['رقم الأصل','Asset ID'],in_service_date:['تاريخ بدء الاستخدام','In-service date'],official_demand:['مطالبة رسمية','Official demand'],calculation_basis:['أساس الاحتساب','Calculation basis'],explanation:['مذكرة تفسير','Explanation memo'],subscription_details:['تفاصيل الاشتراك','Subscription details'],service_name:['اسم الخدمة','Service name'],classification_review:['مراجعة التصنيف المحاسبي','Accounting classification review'],
 prepayment:['دفعة مقدمة','Prepayment'],exceptional_pay:['بدل أو مكافأة استثنائية','Exceptional compensation'],termination:['انتهاء الخدمة','Termination'],above_limit:['تجاوز الحد المالي المعتمد','Above the approved amount limit'],inventory:['مواد مخزنية','Inventory goods'],retention:['احتجاز','Retention'],accident:['حادث','Accident'],monthly_account:['حساب شهري','Monthly account'],foreign_supplier:['مورد خارجي','Foreign supplier'],cancellation:['إلغاء / تغيير سفر','Travel cancellation / change'],missing_invoice:['غياب فاتورة','Missing invoice'],capitalized:['أصل مرسمل','Capitalized asset'],penalty:['غرامة','Penalty'],annual:['اشتراك سنوي','Annual subscription'],perpetual_license:['ترخيص دائم','Perpetual license'],contract_expired:['العقد منتهٍ في تاريخ العملية','Contract expired on transaction date'],duplicate_invoice:['رقم فاتورة مكرر لنفس المورد','Duplicate invoice for the same supplier'],positive_amount:['مبلغ أكبر من صفر','Positive amount'],company:['تحديد الشركة','Company'],valid_contract:['عقد ساري','Valid contract'],unique_invoice:['فاتورة غير مكررة','Unique invoice'],
 WAITING_SUPERVISOR:['انتظار المشرف','Waiting for supervisor'],WAITING_MANAGEMENT:['انتظار الإدارة','Waiting for management'],EXTERNAL_DEPENDENCY:['اعتماد خارجي','External dependency'],SYSTEM_FAILURE:['عطل النظام','System failure'],EMPLOYEE_DELAY:['تأخير الموظف','Employee delay']};
 const label=key=>labels[key]?T(...labels[key]):String(key).replaceAll('_',' ');
 Object.assign(labels,{contract_expiring:['العقد قريب من الانتهاء','Contract expiring'],beneficiary_mismatch:['المستفيد غير مطابق','Beneficiary mismatch'],amount_variance:['فرق غير معتاد في المبلغ','Unusual amount variance'],duplicate_period:['تكرار الفترة','Duplicate period'],inactive_employee:['موظف غير نشط','Inactive employee'],new_supplier:['مورد جديد','New supplier'],price_variance:['فرق السعر','Price variance'],duplicate_document:['مستند مكرر','Duplicate document'],contract_overrun:['تجاوز العقد','Contract overrun'],repeat_repair:['صيانة متكررة','Repeated repair'],inactive_asset:['أصل غير نشط','Inactive asset'],high_consumption:['استهلاك مرتفع','High consumption'],unregistered_vehicle:['مركبة غير مسجلة','Unregistered vehicle'],expired_contract:['عقد منتهٍ','Expired contract'],unclear_scope:['نطاق خدمة غير واضح','Unclear scope'],outside_mission:['خارج فترة المهمة','Outside mission'],non_employee:['المستفيد ليس موظفًا','Non-employee'],old_imprest:['عهدة قديمة غير مسواة','Aged unsettled imprest'],duplicate_asset:['أصل مكرر','Duplicate asset'],period_mismatch:['فترة غير مطابقة','Period mismatch'],duplicate_subscription:['اشتراك مكرر','Duplicate subscription'],inactive_users:['مستخدمون غير نشطين','Inactive users']});
 const status=(id,message,error=false)=>{const box=$(id);if(box){box.className=error?'ops-error':'ops-status';box.textContent=message;}};
 const options=(values,selected='')=>values.map(([value,name])=>`<option value="${escText(value)}" ${value===selected?'selected':''}>${escText(name)}</option>`).join('');
 const button=(id,ar,en,cls='')=>`<button class="btn ${cls}" id="${id}" type="button">${T(ar,en)}</button>`;
 function insertToolbar(page,id){let toolbar=$(id);if(!toolbar){toolbar=document.createElement('div');toolbar.id=id;toolbar.className='ops-actions';$(page)?.prepend(toolbar);}return toolbar;}

 function renderHome(){
  let panel=$('opsHome');if(!panel){panel=document.createElement('section');panel.id='opsHome';panel.className='ops-panel';$('dashboard')?.prepend(panel);}
  panel.hidden=!profile||!canPage('dashboard')||isReadonlyViewer();if(panel.hidden)return;
  const groups=[];
  const add=(key,page,ar,en,count,description)=>{if(canPage(page)&&canDashboardElement(key))groups.push({page,title:T(ar,en),count,description});};
  const activePayments=payments.filter(p=>!p.posted_at&&p.status!=='مرحّل');
  add('payments','payments','اعتمادات تنتظر الإجراء','Approvals awaiting action',activePayments.filter(p=>(profile.role==='CFO'?p.supervisor_status==='موافق'&&p.cfo_status==='معلق':p.supervisor_status==='معلق')).length,T('افتح المدفوعات لمراجعة الصلاحية والإجراء المتاح.','Open payments to review authorized actions.'));
  add('tasks','workcenter','مهام متأخرة','Overdue work',tasks.filter(t=>isOperationalTask(t)&&isTaskOverdue(t)&&t.status!=='مكتمل').length,T('الانتقال إلى مركز العمل ومتابعة السبب والمسؤول.','Open Work Center to follow up owner and cause.'));
  add('tasks','workcenter','نتائج تنتظر المراجعة','Results awaiting review',tasks.filter(t=>isOperationalTask(t)&&t.status==='بانتظار المراجعة').length,T('تظل المراجعات ضمن محرك المهام الحالي.','Reviews use the existing task engine.'));
  const today=riyadhToday();
  const latest=closeTasks.map(x=>x.close_period).filter(Boolean).sort().at(-1);
  add('close','close','إقفال متأخر','Overdue close tasks',closeTasks.filter(t=>t.close_period===latest&&t.due_date&&(typeof sanamTaskEffectiveDueDate==='function'?sanamTaskEffectiveDueDate(t.due_date):t.due_date)<today&&t.status!=='مكتمل'&&number(t.progress)<100).length,T('الدورة الحالية فقط.','Current close cycle only.'));
  add('reserves','banks','احتياطيات تحتاج متابعة','Reserves requiring attention',reserveAccounts.filter(r=>number(r.outstanding_restoration)>0||(r.reference_balance!=null&&number(r.balance)<number(r.reference_balance))).length,T('نقص عن المستهدف أو استعادة معلقة.','Below target or awaiting restoration.'));
  if(canPage('imprest')&&canDashboardElement('exceptions'))groups.push({page:'imprest',title:T('عهد تحتاج متابعة','Imprest requiring follow-up'),count:imprest.filter(f=>/متأخرة|تحتاج تسوية|overdue|needs settlement/i.test(String(f.status||''))).length,description:T('عهد مصنفة متأخرة أو تحتاج تسوية؛ افتح سجل التسويات للتفاصيل.','Funds marked overdue or needing settlement; open the settlement register for detail.')});
  panel.innerHTML=`<h2>${T('ما يحتاج تدخلك اليوم','What needs your attention today')}</h2><p class="ops-status">${T('ملخص من بيانات التشغيل المحملة، حسب صلاحياتك. تاريخ العمل:','Summary of loaded operations within your permissions. Work date:')} ${escText(today)}</p><div class="ops-grid">${groups.map((g,i)=>`<div class="ops-alert"><div>${escText(g.title)}<small>${escText(g.description)}</small></div><b>${g.count}</b><button type="button" class="btn" data-ops-target="${g.page}" data-ops-index="${i}">${T('فتح','Open')}</button></div>`).join('')||`<p class="ops-status">${T('لا تتوفر مؤشرات مسموح بها لهذا الحساب.','No indicators are available for this account.')}</p>`}</div>`;
  panel.querySelectorAll('[data-ops-target]').forEach(b=>b.onclick=()=>openPage(b.dataset.opsTarget,groups[Number(b.dataset.opsIndex)].title));
 }
 function installActions(){
  if(!profile)return;
  const p=insertToolbar('payments','opsPaymentActions');
  if(p){p.hidden=!canPage('payments')||isReadonlyViewer();p.innerHTML=`${canReadBC()?button('opsBCPayments','بيانات Business Central','Business Central data'):''}${roleIn(['CFO','Supervisor','BankAccountant','APAccountant','GLAccountant'])?button('opsReadiness','جاهزية المستندات','Document readiness'):''}${profile.role==='CFO'?button('opsPolicy','إعداد متطلبات المصروفات','Expense requirements'):''}`;}
  const b=insertToolbar('banks','opsBankActions');
  if(b){b.hidden=!canPage('banks')||!canBankBalances()||isReadonlyViewer();b.innerHTML=canReadBC()?button('opsBCBanks','أرصدة Business Central المستوردة','Imported BC balances'):'';}
  $('opsBCPayments')?.addEventListener('click',()=>openBC('payable'));
  $('opsBCBanks')?.addEventListener('click',()=>openBC('bank_balance'));
  $('opsReadiness')?.addEventListener('click',openReadiness);
  $('opsPolicy')?.addEventListener('click',openPolicyEditor);
 }
 let importing=null;
 function openBC(kind){
  if(!canReadBC()||!canPage(kind==='bank_balance'?'banks':'payments'))return;
  importing=null;
  showModal(T('القراءة من ملفات Business Central','Read from Business Central exports'),`<p class="note">${T('تظل المحاسبة في BC. تُحفظ البيانات هنا كمرجع رقابي مستقل، ولا تغيّر أرصدة البنوك أو المدفوعات التشغيلية تلقائيًا. أعد استخدام نفس معرّف السجل عند تحديث التصدير.','Accounting remains in BC. Data is stored as a separate control reference and does not automatically overwrite operational balances or payments. Keep stable record IDs on later exports.')}</p><div class="ops-toolbar"><label>${T('الشركة كما تظهر في BC','Company as shown in BC')}<input id="opsBCCompany" maxlength="200"></label><label>${T('نوع البيانات','Data type')}<select id="opsBCKind">${options([['bank_balance',T('أرصدة البنوك','Bank balances')],['payable',T('مستحقات الموردين','Vendor payables')],['posted_document',T('المستندات المرحلة','Posted documents')]],kind)}</select></label>${button('opsBCBrowse','عرض السجلات المستوردة','View imported records')}</div>${canImport()?`<details class="ops-panel" open><summary>${T('استيراد ملف CSV','Import a CSV file')}</summary><p class="ops-status">${T('حتى 5 ميجابايت و5,000 سجل. احفظ Excel بصيغة CSV UTF-8. التواريخ YYYY-MM-DD. لا يُستخدم رقم الصف كمعرّف.','Up to 5 MB / 5,000 rows. Save Excel as CSV UTF-8. Dates use YYYY-MM-DD. Row numbers are not used as record IDs.')}</p><div class="ops-fields"><label>${T('الملف','File')}<input id="opsBCFile" type="file" accept=".csv,text/csv"></label><label>${T('فاصل الأعمدة','Column separator')}<select id="opsBCDelimiter"><option value=",">Comma (,)</option><option value=";">Semicolon (;)</option><option value="tab">Tab</option></select></label><label>${T('الفاصل العشري','Decimal separator')}<select id="opsBCDecimal"><option value=".">.</option><option value=",">,</option></select></label><label>${T('فاصل الآلاف','Thousands separator')}<select id="opsBCGroup"><option value="none">${T('بدون','None')}</option><option value=",">,</option><option value=".">.</option><option value=" ">${T('مسافة','Space')}</option></select></label></div>${button('opsBCParse','قراءة الأعمدة','Read columns')}<div id="opsBCMapping" class="ops-fields"></div><div id="opsBCPreview"></div></details>`:''}<div id="opsBCStatus" role="status" aria-live="polite"></div><div id="opsBCRecords" class="ops-results"></div>`);
  $('opsBCBrowse').onclick=()=>browseBC(0);
  $('opsBCParse')?.addEventListener('click',parseBC);
  for(const id of ['opsBCCompany','opsBCKind','opsBCFile','opsBCDelimiter','opsBCDecimal','opsBCGroup'])$(id)?.addEventListener('change',()=>{importing=null;$('opsBCPreview')?.replaceChildren();});
 }
 async function parseBC(){
  try{
   const file=$('opsBCFile').files[0];if(!file)throw Error(T('اختر ملفًا.','Select a file.'));if(file.size>5*1024*1024)throw Error('FILE_TOO_LARGE');
   const text=new TextDecoder('utf-8',{fatal:true}).decode(await file.arrayBuffer());
   const parsed=core.parseCsv(text,val('opsBCDelimiter')==='tab'?'\t':val('opsBCDelimiter'));
   if(!$('opsBCMapping'))return;
   importing={parsed,fileName:file.name};
   $('opsBCMapping').innerHTML=core.fields.map(key=>`<label>${escText(label(key))}${['source_id','amount','currency','posting_date'].includes(key)?' *':''}<select id="opsMap_${key}">${options([['',T('اختر العمود','Choose column')],...parsed.headers.map(h=>[h,h])],parsed.headers.find(h=>h.toLowerCase()===key)||'')}</select></label>`).join('')+button('opsBCValidate','معاينة والتحقق','Preview & validate');
   $('opsBCValidate').onclick=previewBC;
   $('opsBCMapping').querySelectorAll('select').forEach(select=>select.onchange=()=>$('opsBCPreview')?.replaceChildren());
   status('opsBCStatus',T('تمت قراءة الأعمدة؛ راجع الربط ثم اعرض المعاينة.','Columns read; review mapping then preview.'));
  }catch(error){importing=null;status('opsBCStatus',error.message,true);}
 }
 function previewBC(){
  try{
   if(!importing)throw Error('SELECT_FILE_AGAIN');
   const company=val('opsBCCompany').trim();if(!company)throw Error(T('حدد الشركة.','Specify the company.'));
   const mapping=Object.fromEntries(core.fields.map(key=>[key,val('opsMap_'+key)]));
   const rows=core.mapRows(importing.parsed,mapping,{decimal:val('opsBCDecimal'),group:val('opsBCGroup')});
   const snapshot={company,kind:val('opsBCKind'),rows,fileName:importing.fileName};
   const currencies=[...new Set(rows.map(r=>r.currency))];
   $('opsBCPreview').innerHTML=`<h3>${T('معاينة قبل الحفظ','Preview before saving')}</h3><p>${escText(company)} · ${rows.length} ${T('سجل','records')}</p><p class="ops-status">${currencies.map(c=>`${escText(c)}: ${moneyValue(rows.filter(r=>r.currency===c).reduce((s,r)=>s+r.amount,0))}`).join(' · ')}</p><div class="table-wrap ops-scroll">${bcTable(rows.slice(0,20))}</div><label class="ops-check"><input type="checkbox" id="opsBCConfirm">${T('راجعت الشركة والربط والمبالغ. الاستيراد سيضيف الجديد ويحدّث نفس معرّفات المصدر فقط.','I reviewed company, mapping and amounts. Import adds new records and updates only matching source IDs.')}</label>${button('opsBCCommit','حفظ الاستيراد','Save import','primary')}`;
   $('opsBCCommit').onclick=async()=>{
    if(!$('opsBCConfirm')?.checked)return status('opsBCStatus',T('أكد مراجعة المعاينة أولًا.','Confirm the preview first.'),true);
    const btn=$('opsBCCommit');btn.disabled=true;
    try{
     if(!canImport())throw Error('NOT_AUTHORIZED');
     const {data,error}=await sb.rpc('import_bc_control_file',{p_company:snapshot.company,p_record_type:snapshot.kind,p_file_name:snapshot.fileName,p_rows:snapshot.rows});if(error)throw error;
     if(!data?.batch_id)throw Error('INVALID_IMPORT_RESPONSE');
     status('opsBCStatus',`${T('تم الحفظ: جديد','Saved: new')} ${data.inserted} · ${T('محدث','updated')} ${data.updated} · ${T('دون تغيير','unchanged')} ${data.unchanged}`);
     $('opsBCCompany').value=snapshot.company;$('opsBCKind').value=snapshot.kind;
     $('opsBCPreview').replaceChildren();await browseBC(0,true);
    }catch(error){status('opsBCStatus',error.message,true);btn.disabled=false;}
   };
  }catch(error){$('opsBCPreview')?.replaceChildren();status('opsBCStatus',error.message,true);}
 }
 function bcTable(rows){return `<table><thead><tr>${['source_id','document_no','beneficiary','posting_date','due_date','amount','currency'].map(key=>`<th>${escText(label(key))}</th>`).join('')}</tr></thead><tbody>${rows.map(row=>`<tr>${['source_id','document_no','beneficiary','posting_date','due_date','amount','currency'].map(key=>`<td>${key==='amount'?moneyValue(row[key]):escText(row[key]||'—')}</td>`).join('')}</tr>`).join('')||'<tr><td colspan="7">—</td></tr>'}</tbody></table>`;}
 async function browseBC(offset,keepStatus=false){
  try{
   const company=val('opsBCCompany').trim();if(!company)throw Error(T('حدد الشركة.','Specify the company.'));
   const {data,error}=await sb.rpc('get_bc_control_records',{p_company:company,p_record_type:val('opsBCKind'),p_limit:100,p_offset:offset});if(error)throw error;
   if(!$('opsBCRecords'))return;
   const rows=(data?.items||[]).map(r=>r.payload);
   $('opsBCRecords').innerHTML=`<h3>${T('البيانات المستوردة للقراءة','Imported reference data')}</h3><p class="ops-status">${T('آخر استيراد','Last import')}: ${escText(data?.last_batch?.imported_at||'—')} · ${escText(data?.last_batch?.file_name||'—')} · ${T('إجمالي السجلات','Total records')}: ${number(data?.total)}</p><div class="table-wrap ops-scroll">${bcTable(rows)}</div><div class="ops-actions">${button('opsBCPrev','السابق','Previous')}${button('opsBCNext','التالي','Next')}</div>`;
   $('opsBCPrev').disabled=offset===0;$('opsBCNext').disabled=offset+100>=number(data?.total);
   $('opsBCPrev').onclick=()=>browseBC(Math.max(0,offset-100));$('opsBCNext').onclick=()=>browseBC(offset+100);
   if(val('opsBCKind')==='payable'&&roleIn(['CFO','Supervisor','BankAccountant','APAccountant'])&&rows.length){
    const area=document.createElement('div');area.className='ops-toolbar';area.innerHTML=`<label>${T('إنشاء طلب دفع من المصدر دون إعادة إدخال البيانات','Create a payment request without re-entering source data')}<select id="opsBCRequestSource">${options(rows.map((r,i)=>[String(i),`${r.source_id} — ${r.beneficiary||''} — ${moneyValue(r.amount)} ${r.currency}`]))}</select></label>${button('opsBCRequestPayment','إنشاء طلب مرتبط','Create linked request')}`;$('opsBCRecords').appendChild(area);
    $('opsBCRequestPayment').onclick=()=>openBCPayment(company,rows[Number(val('opsBCRequestSource'))]);
   }
   if(!keepStatus)status('opsBCStatus',T('عرض بيانات المصدر؛ لا تمثل تسوية تلقائية مع الأرصدة التشغيلية.','Source data view; not an automatic reconciliation with operational balances.'));
  }catch(error){status('opsBCStatus',error.message,true);}
 }
 function openBCPayment(company,row){
  if(!roleIn(['CFO','Supervisor','BankAccountant','APAccountant'])||!canPage('payments'))return;
  if(row.currency!=='SAR')return status('opsBCStatus',T('مسار المدفوعات الحالي بالريال؛ لا يمكن إنشاء طلب بعملة أخرى قبل تجهيز مسار العملات.','The current payment workflow uses SAR; other currencies require a currency-aware workflow.'),true);
  showModal(T('طلب دفع مرتبط بـBC','BC-linked payment request'),`<p class="note">${escText(company)} — ${escText(row.document_no||row.source_id)}<br>${escText(row.beneficiary)} — ${moneyValue(row.amount)} SAR<br>${T('تؤخذ الشركة والمستفيد والمبلغ وموعد الاستحقاق من المصدر على الخادم. يبدأ الطلب بمستندات ناقصة حتى مراجعتها.','Company, beneficiary, amount and due date are read from the source on the server. Documents start incomplete pending review.')}</p><div class="ops-fields"><label>${T('حساب التنفيذ','Execution bank account')}<select id="opsBCRequestBank">${options(bankDirectory.filter(b=>b.company===company).map(b=>[b.id,`${b.bank_name||''} — ${b.account_name||''}`]))}</select></label><label>${T('الأولوية','Priority')}<select id="opsBCRequestPriority">${options(['عادي','عاجل','حرج'].map(k=>[k,displayText(k)]))}</select></label>${row.due_date?`<p>${T('الاستحقاق','Due')}: ${escText(row.due_date)}</p>`:`<label>${T('موعد تشغيلي لعدم وجود استحقاق في المصدر','Operational date when source has no due date')}<input id="opsBCRequestDue" type="date"></label>`}</div><div id="opsBCRequestStatus" role="status"></div>${button('opsBCRequestSave','إنشاء طلب واحد','Create one request','primary')}`);
  $('opsBCRequestSave').onclick=async()=>{
   const btn=$('opsBCRequestSave');btn.disabled=true;
   try{
    const bank=bankDirectory.find(b=>b.id===val('opsBCRequestBank'));
    if(!bank)throw Error(T('اختر حسابًا تابعًا لنفس الشركة.','Choose an account for the same company.'));
    if(isProtectedBank(bank)&&!confirm(T('هذا حساب محمي؛ هل تريد طلب الدفع منه؟','This account is protected. Request payment from it?'))){btn.disabled=false;return;}
    const {data,error}=await sb.rpc('request_payment_from_bc',{p_company:company,p_source_id:row.source_id,p_bank_account_id:bank.id,p_due_date:row.due_date||val('opsBCRequestDue')||null,p_priority:val('opsBCRequestPriority')});if(error)throw error;if(!data)throw Error('PAYMENT_REQUEST_NOT_CREATED');
    closeModal();await reloadAll();openPage('payments',T('المدفوعات','Payments'));
   }catch(error){status('opsBCRequestStatus',error.message,true);btn.disabled=false;}
  };
 }
 let readinessPolicies=[];
 async function policies(){const {data,error}=await sb.rpc('get_readiness_policies');if(error)throw error;if(!Array.isArray(data)||!data.length)throw Error('READINESS_POLICIES_UNAVAILABLE');readinessPolicies=data;return data;}
 async function openReadiness(){
  if(!roleIn(['CFO','Supervisor','BankAccountant','APAccountant','GLAccountant'])||!canPage('payments'))return;
  showModal(T('الجاهزية المستندية والتشغيلية','Document & operational readiness'),`<p class="note">${T('مرجع المستند قد يكون رقمه أو رابطه داخل BC. إدخال المرجع إقرار من المستخدم بوجوده، وليس فحصًا آليًا لمحتوى الملف. هذا الفحص لا يرحّل قيدًا ولا يستبدل اعتماد الدفع.','A document reference may be its number or link in BC. Providing it is a user attestation, not automatic file-content verification. This check does not post accounting entries or replace payment approval.')}</p><div id="opsReadyStatus" role="status"></div><div id="opsReadyForm"></div>`);
  try{
   const list=await policies();if(!$('opsReadyForm'))return;
   $('opsReadyForm').innerHTML=`<div class="ops-fields"><label>${T('الدفعة','Payment')}<select id="opsReadyPayment">${options(payments.map(p=>[p.id,`${p.company} — ${p.beneficiary} — ${moneyValue(p.amount)}`]))}</select></label><label>${T('نوع المصروف','Expense type')}<select id="opsReadyType">${options(list.map(p=>[p.expense_type,names[p.expense_type]?T(...names[p.expense_type]):p.expense_type]))}</select></label></div><div id="opsReadyChecklist"></div><div id="opsReadyResult"></div>`;
   $('opsReadyType').onchange=()=>renderReadinessChecklist();$('opsReadyPayment').onchange=restoreReadiness;
   await restoreReadiness();
  }catch(error){status('opsReadyStatus',error.message,true);}
 }
 async function restoreReadiness(){
  const payment=val('opsReadyPayment');if(!payment)return renderReadinessChecklist();
  status('opsReadyStatus',T('تحميل آخر فحص…','Loading last assessment…'));
  const {data,error}=await sb.rpc('get_payment_readiness_assessment',{p_payment_id:payment});
  if(!$('opsReadyChecklist')||val('opsReadyPayment')!==payment)return;
  if(error){status('opsReadyStatus',error.message,true);renderReadinessChecklist();return;}
  if(data?.expense_type)$('opsReadyType').value=data.expense_type;
  renderReadinessChecklist(data||{});status('opsReadyStatus',data?`${T('آخر حفظ','Last saved')}: ${data.assessed_at}`:'');
 }
 function renderReadinessChecklist(saved={}){
  const pol=readinessPolicies.find(p=>p.expense_type===val('opsReadyType'));if(!pol)return;
  const keys=[...new Set([...pol.required_documents,...pol.conditional_documents.flatMap(c=>c.requires)])];
  const flags=[...new Set([...pol.conditional_documents.map(c=>c.flag),...pol.warning_flags,...(pol.blocking_flags||[]),'contract_expired','duplicate_invoice'])];
  $('opsReadyChecklist').innerHTML=`<h3>${T('ظروف العملية والتحذيرات','Conditions & warnings')}</h3><p class="ops-status">${T('حدد الظروف المعروفة من المستندات. الحد المالي يتبع سياسة الشركة المعتمدة؛ لا يفترض النظام قيمة له.','Select circumstances evidenced by source documents. Amount limits follow approved company policy; no limit is assumed.')}</p><div class="ops-fields">${flags.map(key=>`<label class="ops-check"><input data-ready-flag="${escText(key)}" type="checkbox" ${saved.context?.[key]===true?'checked':''}>${escText(label(key))}</label>`).join('')}</div><h3>${T('مراجع المستندات','Document references')}</h3><div class="ops-fields">${keys.map(key=>`<label>${escText(label(key))}${pol.required_documents.includes(key)?' *':''}<input data-ready-evidence="${escText(key)}" maxlength="500" value="${escText(saved.evidence?.[key]||'')}" placeholder="${T('رقم / مرجع / رابط المستند','Document number / reference / link')}"></label>`).join('')}</div><div class="ops-actions">${button('opsReadyCheck','فحص الجاهزية','Check readiness')}${profile.role!=='GLAccountant'?button('opsReadySave','فحص وحفظ في السجل','Check & save to audit','primary'):''}</div>`;
  $('opsReadyResult').replaceChildren();$('opsReadyCheck').onclick=()=>checkReadiness(false);$('opsReadySave')?.addEventListener('click',()=>checkReadiness(true));
  $('opsReadyChecklist').querySelectorAll('input').forEach(input=>input.addEventListener('input',()=>$('opsReadyResult')?.replaceChildren()));
  if(pol.amount_limit!=null){
   const flag=$('opsReadyChecklist').querySelector('[data-ready-flag="above_limit"]');
   if(flag){flag.disabled=true;flag.checked=number(payments.find(p=>p.id===val('opsReadyPayment'))?.amount)>Number(pol.amount_limit);flag.parentElement.appendChild(document.createTextNode(` — ${T('يحسب تلقائيًا من حد','Automatically calculated from limit')} ${moneyValue(pol.amount_limit)}`));}
  }
 }
 async function checkReadiness(save){
  const payment=val('opsReadyPayment');if(!payment)return status('opsReadyStatus',T('لا توجد دفعة للاختيار.','No payment is available.'),true);
  const evidence=Object.fromEntries([...document.querySelectorAll('[data-ready-evidence]')].map(x=>[x.dataset.readyEvidence,x.value.trim()]));
  const context=Object.fromEntries([...document.querySelectorAll('[data-ready-flag]')].map(x=>[x.dataset.readyFlag,x.checked]));
  const btn=$(save?'opsReadySave':'opsReadyCheck');btn.disabled=true;
  try{
   const {data,error}=await sb.rpc('check_payment_readiness',{p_payment_id:payment,p_expense_type:val('opsReadyType'),p_evidence:evidence,p_context:context,p_save:save});if(error)throw error;
   if(!data||typeof data.ready!=='boolean')throw Error('INVALID_READINESS_RESPONSE');
   if(!$('opsReadyResult'))return;
   $('opsReadyResult').innerHTML=`<div class="ops-panel"><h3>${data.ready?T('جاهز مستنديًا','Document-ready'):T('غير جاهز مستنديًا','Not document-ready')}</h3>${(data.missing||[]).map(key=>`<p class="ops-error">✕ ${escText(label(key))}</p>`).join('')}${(data.warnings||[]).map(key=>`<p class="warning-box">! ${escText(label(key))}</p>`).join('')}<p class="ops-status">${T('إصدار السياسة','Policy revision')} ${number(data.policy_revision)} · ${T('وقت الفحص','Checked at')} ${escText(data.checked_at)}</p></div>`;
   status('opsReadyStatus',save?T('حُفظ الفحص ومراجعه في سجل التدقيق.','Assessment and references saved to audit.'):T('معاينة فقط؛ لم يُحفظ الفحص.','Preview only; not saved.'));
  }catch(error){status('opsReadyStatus',error.message,true);}finally{btn.disabled=false;}
 }
 async function openPolicyEditor(){
  if(!roleIn(['CFO']))return;
  showModal(T('إعداد متطلبات المصروفات','Configure expense requirements'),`<div id="opsPolicyStatus" role="status"></div><div id="opsPolicyForm"></div>`);
  try{const list=await policies();if(!$('opsPolicyForm'))return;$('opsPolicyForm').innerHTML=`<label>${T('نوع المصروف','Expense type')}<select id="opsPolicyType">${options(list.map(p=>[p.expense_type,T(...names[p.expense_type])]))}</select></label><div id="opsPolicyDetails"></div>`;$('opsPolicyType').onchange=renderPolicy;renderPolicy();}catch(error){status('opsPolicyStatus',error.message,true);}
 }
 function renderPolicy(){
  const pol=readinessPolicies.find(p=>p.expense_type===val('opsPolicyType'));if(!pol)return;
  const docs=[...new Set(readinessPolicies.flatMap(p=>[...p.required_documents,...p.conditional_documents.flatMap(c=>c.requires)]))];
  $('opsPolicyDetails').innerHTML=`<h3>${T('المستندات الإلزامية','Required documents')}</h3><div class="ops-fields">${docs.map(key=>`<label class="ops-check"><input type="checkbox" data-policy-required="${key}" ${pol.required_documents.includes(key)?'checked':''}>${escText(label(key))}</label>`).join('')}</div><h3>${T('المتطلبات المشروطة','Conditional requirements')}</h3>${pol.conditional_documents.map((c,i)=>`<div class="ops-panel"><label class="ops-check"><input type="checkbox" data-policy-condition="${i}" checked>${T('عند','When')} ${escText(label(c.flag))}</label><div class="ops-fields">${docs.map(key=>`<label class="ops-check"><input type="checkbox" data-policy-condition-doc="${i}" value="${key}" ${c.requires.includes(key)?'checked':''}>${escText(label(key))}</label>`).join('')}</div></div>`).join('')}<h3>${T('التحذيرات غير المانعة','Non-blocking warnings')}</h3>${pol.warning_flags.map(key=>`<label class="ops-check"><input type="checkbox" data-policy-warning="${key}" checked>${escText(label(key))}</label>`).join('')}${button('opsPolicySave','حفظ السياسة','Save policy','primary')}`;
  $('opsPolicyDetails').querySelectorAll('[data-policy-warning]').forEach(input=>input.parentElement.remove());
  const severity=document.createElement('div');severity.className='ops-fields';
  const flags=[...new Set(readinessPolicies.flatMap(p=>[...p.warning_flags,...(p.blocking_flags||[])]))];
  severity.innerHTML=flags.map(key=>`<label>${escText(label(key))}<select data-policy-severity="${escText(key)}">${options([['ignore',T('غير مفعّل','Inactive')],['warning',T('تحذير','Warning')],['blocking',T('مانع للجاهزية','Blocks readiness')]],(pol.blocking_flags||[]).includes(key)?'blocking':pol.warning_flags.includes(key)?'warning':'ignore')}</select></label>`).join('')+`<label>${T('الحد المالي المعتمد (اختياري)','Approved amount limit (optional)')}<input id="opsPolicyLimit" type="number" min="0.01" step="0.01" value="${pol.amount_limit==null?'':escText(pol.amount_limit)}"></label>`;
  $('opsPolicySave').before(severity);
  $('opsPolicySave').onclick=async()=>{
   const btn=$('opsPolicySave');btn.disabled=true;
   try{
    const required=[...document.querySelectorAll('[data-policy-required]:checked')].map(x=>x.dataset.policyRequired);
    const conditional=[...document.querySelectorAll('[data-policy-condition]:checked')].map(x=>{const i=Number(x.dataset.policyCondition);return {flag:pol.conditional_documents[i].flag,requires:[...document.querySelectorAll(`[data-policy-condition-doc="${i}"]:checked`)].map(x=>x.value)};});
    const rules=[...document.querySelectorAll('[data-policy-severity]')];
    const warnings=rules.filter(x=>x.value==='warning').map(x=>x.dataset.policySeverity),blocking=rules.filter(x=>x.value==='blocking').map(x=>x.dataset.policySeverity);
    const amountLimit=val('opsPolicyLimit')?Number(val('opsPolicyLimit')):null;
    const {error}=await sb.rpc('set_readiness_policy',{p_expense_type:pol.expense_type,p_required:required,p_conditional:conditional,p_warnings:warnings,p_revision:pol.revision,p_blocking:blocking,p_amount_limit:amountLimit});if(error)throw error;
    await policies();status('opsPolicyStatus',T('حُفظ إصدار جديد من السياسة وسُجل التغيير.','A new policy revision was saved and audited.'));renderPolicy();
   }catch(error){status('opsPolicyStatus',error.message,true);btn.disabled=false;}
  };
 }

 loadEmployeePerformanceReport=async function(){
  const uid=val('perfEmp'),from=val('perfFrom'),to=val('perfTo'),out=$('employeePerformanceOutput');if(!uid||!out)return;
  out.textContent=T('جارٍ التحميل…','Loading…');
  try{
   const {data,error}=await sb.rpc('get_employee_performance_report_v5',{p_user_id:uid,p_from:from||null,p_to:to||null});if(error)throw error;
   if(!data?.employee||!data.adjusted_summary)throw Error('PERFORMANCE_REPORT_UNAVAILABLE');
   if(!$('employeePerformanceOutput')||val('perfEmp')!==uid||val('perfFrom')!==from||val('perfTo')!==to)return;
   employeePerformanceReport=data;const sm=data.adjusted_summary;
   out.innerHTML=`<div class="mini-kpis"><div class="card">${T('منجز','Completed')}<b>${number(sm.completed)}</b></div><div class="card">${T('الالتزام بعد المراجعة','Reviewed on-time rate')}<b>${sm.on_time_rate==null?'—':number(sm.on_time_rate).toFixed(1)+'%'}</b></div><div class="card">${T('متوسط جودة النتائج','Average result quality')}<b>${sm.avg_quality_score==null?'—':number(sm.avg_quality_score).toFixed(1)+'%'}</b></div><div class="card">${T('طلبات تأخير قيد المراجعة','Delay requests pending review')}<b>${number(sm.pending_delay_reviews)}</b></div></div><p class="note">${escText(data.employee.full_name)} · ${escText(data.from)} → ${escText(data.to)}<br>${T('الموعد الأصلي محفوظ. تستبعد مدد الانتظار المعتمدة من مسؤول مستقل، وتدمج الفترات المتداخلة مرة واحدة. طلبات التأخير المعلقة تجعل نتيجة الالتزام مؤقتة، والتمديدات السابقة محسوبة في موعد الاستحقاق الحالي. المدة المعروضة زمن منقضٍ وليست ساعات عمل تعاقدية.','Original timing is retained. Independently approved waiting intervals are excluded, with overlaps counted once. Pending delay requests make timing provisional; prior extensions are already reflected in the due date. Durations are elapsed time, not contracted working hours.')}</p><p class="ops-status">${T('النتائج النهائية المؤقتة المستبعدة من النسبة لا تُعد نجاحًا أو إخفاقًا. لا تدخل تقييمات الجودة الفارغة كصفر.','Provisional timing outcomes count as neither success nor failure. Missing quality scores are not counted as zero.')}</p><div class="table-wrap"><table><thead><tr>${[T('المهمة','Work item'),T('الموعد الأصلي','Original due'),T('الإنهاء','Completed'),T('الوقت المستبعد بالدقائق','Excluded minutes'),T('الموعد المعدل','Adjusted due'),T('النتيجة','Outcome'),T('إعادة عمل','Rework'),T('الجودة','Quality')].map(h=>`<th>${h}</th>`).join('')}</tr></thead><tbody>${data.items.map(i=>`<tr><td>${escText(i.title)}</td><td>${escText(i.due_at||'—')}</td><td>${escText(i.completed_at||'—')}</td><td>${(number(i.excluded_seconds)/60).toFixed(1)}</td><td>${escText(i.adjusted_due_at||'—')}</td><td>${number(i.pending_delay_reviews)>0?T('قيد المراجعة','Under review'):i.adjusted_on_time==null?'—':i.adjusted_on_time?T('في الموعد','On time'):T('متأخر','Late')}</td><td>${number(i.rework_count)}</td><td>${i.quality_score==null?'—':number(i.quality_score).toFixed(1)+'%'}</td></tr>`).join('')||'<tr><td colspan="8">—</td></tr>'}</tbody></table></div><div class="ops-actions">${button('opsDelayOpen','توضيح أسباب التأخير ومراجعتها','Document & review delay causes')}</div><div id="opsDelayArea"></div>`;
   $('opsDelayOpen').onclick=()=>openDelayArea(data);
  }catch(error){out.innerHTML=`<div class="ops-error">${escText(error.message)}</div>`;employeePerformanceReport=null;}
 };
 async function openDelayArea(report){
  if(!$('opsDelayArea'))return;
  $('opsDelayArea').innerHTML=`<div class="ops-panel"><h3>${T('أسباب التأخير','Delay causes')}</h3><p class="ops-status">${T('لا يُعتمد طلبك بواسطة نفسك أو الموظف محل التقييم. استخدم توقيتًا صريحًا مثل 2026-10-31T09:00:00+03:00. الفترات يجب أن تقع داخل مدة المهمة.','Requests require approval by someone other than the requester or evaluated employee. Use an explicit timestamp such as 2026-10-31T09:00:00+03:00. Intervals must fall within the work item duration.')}</p><div class="ops-fields"><label>${T('المهمة','Work item')}<select id="opsDelayItem">${options(report.items.map(i=>[i.work_item_id,i.title]))}</select></label><label>${T('سبب التأخير','Delay reason')}<select id="opsDelayReason">${options(['WAITING_SUPERVISOR','WAITING_MANAGEMENT','EXTERNAL_DEPENDENCY','SYSTEM_FAILURE','EMPLOYEE_DELAY'].map(k=>[k,label(k)]))}</select></label><label>${T('بداية الفترة','Interval start')}<input id="opsDelayFrom" placeholder="2026-10-31T09:00:00+03:00"></label><label>${T('نهاية الفترة','Interval end')}<input id="opsDelayTo" placeholder="2026-10-31T10:00:00+03:00"></label><label>${T('التفسير','Explanation')}<textarea id="opsDelayExplanation" maxlength="2000"></textarea></label><label>${T('مرجع الدليل','Evidence reference')}<input id="opsDelayEvidence" maxlength="500"></label></div>${button('opsDelayRequest','إرسال للمراجعة','Submit for review')}<div id="opsDelayStatus" role="status"></div><div id="opsDelayList"></div></div>`;
  $('opsDelayRequest').onclick=async()=>{
   const btn=$('opsDelayRequest');btn.disabled=true;
   try{
    for(const id of ['opsDelayFrom','opsDelayTo'])if(!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?(Z|[+-]\d{2}:\d{2})$/.test(val(id))||!Number.isFinite(Date.parse(val(id))))throw Error(T('استخدم تاريخًا ووقتًا مع المنطقة الزمنية.','Use a timestamp including its time zone.'));
    const {error}=await sb.rpc('request_work_delay_attribution',{p_work_item_id:val('opsDelayItem'),p_reason:val('opsDelayReason'),p_starts_at:val('opsDelayFrom'),p_ends_at:val('opsDelayTo'),p_explanation:val('opsDelayExplanation'),p_evidence_reference:val('opsDelayEvidence')});if(error)throw error;
    status('opsDelayStatus',T('أُرسل الطلب؛ سيبقى أثره مؤقتًا حتى قرار المراجع.','Request submitted; its timing outcome remains provisional until reviewed.'));await loadDelayList(report.employee.id);
   }catch(error){status('opsDelayStatus',error.message,true);}finally{btn.disabled=false;}
  };
  await loadDelayList(report.employee.id);
 }
 async function loadDelayList(uid){
  const {data,error}=await sb.rpc('get_work_delay_attributions',{p_employee_id:uid});if(!$('opsDelayList'))return;if(error)return status('opsDelayStatus',error.message,true);
  const rows=Array.isArray(data)?data:[];
  $('opsDelayList').innerHTML=rows.map((r,index)=>`<div class="ops-panel"><b>${escText(label(r.reason))} — ${escText(r.status)}</b><p>${escText(r.explanation)}</p><p class="ops-status">${escText(r.starts_at)} → ${escText(r.ends_at)}<br>${escText(r.evidence_reference)}</p>${r.status==='Pending'&&roleIn(['CFO','Supervisor'])&&profile.id!==r.employee_id&&profile.id!==r.requested_by?`<label>${T('ملاحظة القرار','Decision note')}<input data-delay-note="${index}" maxlength="2000"></label><div class="ops-actions"><button class="btn" data-delay-decision="${index}" data-approved="true">${T('اعتماد','Approve')}</button><button class="btn" data-delay-decision="${index}" data-approved="false">${T('رفض','Reject')}</button></div>`:`<p class="ops-status">${escText(r.decision_note||'')}</p>`}</div>`).join('')||`<p>${T('لا توجد طلبات مسجلة.','No requests recorded.')}</p>`;
  document.querySelectorAll('[data-delay-decision]').forEach(btn=>btn.onclick=async()=>{
   btn.disabled=true;try{const index=Number(btn.dataset.delayDecision),r=rows[index],note=document.querySelector(`[data-delay-note="${index}"]`).value;const {error}=await sb.rpc('decide_work_delay_attribution',{p_id:r.id,p_approved:btn.dataset.approved==='true',p_note:note});if(error)throw error;await loadEmployeePerformanceReport();await openDelayArea(employeePerformanceReport);}catch(error){status('opsDelayStatus',error.message,true);btn.disabled=false;}
  });
 }
 printEmployeePerformanceReport=function(){
  if(!employeePerformanceReport?.employee||!$('employeePerformanceOutput'))return;
  const clone=$('employeePerformanceOutput').cloneNode(true);
  clone.querySelectorAll('.ops-actions,#opsDelayArea,button,input,textarea,select').forEach(node=>node.remove());
  const reportWindow=window.open('','_blank');if(!reportWindow)return;
  reportWindow.document.write(`<!doctype html><html lang="${currentLang}" dir="${currentLang==='en'?'ltr':'rtl'}"><head><meta charset="utf-8"><title>${escText(employeePerformanceReport.employee.full_name)}</title><style>@page{size:A4 landscape;margin:12mm}body{font:12px Arial,Tahoma;color:#172033}header{background:#0f2740;color:#fff;border-bottom:4px solid #b99b5f;padding:16px;margin-bottom:16px}table{width:100%;border-collapse:collapse;font-size:10px}th,td{border:1px solid #cbd2dc;padding:7px;text-align:start}th{background:#edf1f5}tr{break-inside:avoid}.mini-kpis{display:flex;gap:10px;margin-block:12px}.card{padding:12px;border:1px solid #ccd3dd;flex:1}.card b{display:block;font-size:18px;margin-top:6px}.note{line-height:1.8}.ops-status{color:#576479;font-size:10px}.table-wrap{overflow:visible}footer{margin-top:18px;border-top:1px solid #ccd3dd;padding-top:8px}</style></head><body><header><b>Sanam Finance Portal</b><h2>${T('تقرير أداء الموظف','Employee performance report')}</h2></header>${clone.innerHTML}<footer>${T('نسخة تقرير عند الطلب — السجل الأصلي محفوظ في النظام.','Report generated on demand — source history remains in the system.')} · ${escText(riyadhToday())}</footer></body></html>`);
  reportWindow.document.close();reportWindow.focus();reportWindow.print();
 };
 const previousDashboard=renderDashboard;
 renderDashboard=function(...args){const result=previousDashboard.apply(this,args);renderHome();return result;};
 const previousAccess=applyAccess;
 applyAccess=function(...args){const result=previousAccess.apply(this,args);installActions();renderHome();return result;};
 const previousLanguage=applyLanguage;
 applyLanguage=function(...args){const result=previousLanguage.apply(this,args);renderHome();installActions();return result;};
 let errorBudget={user:null,count:0,since:0};
 function reportClientError(code){
  if(!profile||!session?.user)return;
  if(errorBudget.user!==profile.id||Date.now()-errorBudget.since>600000)errorBudget={user:profile.id,count:0,since:Date.now()};
  if(errorBudget.count>=20)return;errorBudget.count++;
  const page=document.querySelector('.section.active')?.id||'other';
  // Do not transmit messages, stack traces, URLs, file contents or credentials.
  void Promise.resolve().then(()=>sb.rpc('record_portal_client_error',{p_code:code,p_page:page})).catch(()=>{});
 }
 window.addEventListener('error',()=>reportClientError('WINDOW_ERROR'));
 window.addEventListener('unhandledrejection',()=>reportClientError('UNHANDLED_REJECTION'));
 async function renderOperationsHealth(){
  if(!roleIn(['CFO','Supervisor'])||!canPage('automation'))return;
  let panel=$('opsHealth');if(!panel){panel=document.createElement('section');panel.id='opsHealth';panel.className='ops-panel';$('automation')?.prepend(panel);}
  panel.innerHTML=`<h2>${T('صحة التشغيل والاستيراد','Operations & import health')}</h2>${button('opsHealthRefresh','تحديث','Refresh')}<div id="opsHealthStatus" role="status"></div><div id="opsHealthResults"></div>`;
  $('opsHealthRefresh').onclick=renderOperationsHealth;
  try{
   const {data,error}=await sb.rpc('get_operations_health');if(error)throw error;if(!data||!Array.isArray(data.client_errors_24h))throw Error('OPERATIONS_HEALTH_UNAVAILABLE');
   if(!$('opsHealthResults'))return;
   $('opsHealthResults').innerHTML=`<p>${T('طلبات أسباب التأخير المعلقة','Pending delay reviews')}: ${number(data.pending_delay_decisions)} · ${T('أقدم طلب','Oldest request')}: ${escText(data.oldest_delay_request||'—')}</p><h3>${T('أخطاء الواجهة خلال 24 ساعة','Client errors in the last 24 hours')}</h3>${data.client_errors_24h.map(x=>`<p>${escText(x.code)} · ${escText(x.page)} · ${number(x.count)} · ${escText(x.last_at)}</p>`).join('')||`<p>${T('لا توجد أخطاء مسجلة خلال الفترة.','No errors recorded in this window.')}</p>`}<h3>${T('أحدث ملفات BC حسب الشركة والنوع','Latest BC imports by company and type')}</h3>${(data.latest_imports||[]).map(x=>`<p>${escText(x.company)} · ${escText(x.record_type)} · ${escText(x.imported_at)}</p>`).join('')||'—'}<p class="ops-status">${T('تُسجل رموز أخطاء عامة دون الرسائل أو الروابط أو محتويات الملفات. هذا السجل لا يغني عن مراقبة الخادم.','Only generic error codes are recorded; messages, URLs and file contents are excluded. This does not replace server monitoring.')}</p>`;
   status('opsHealthStatus',`${T('وقت القراءة','Read at')}: ${data.as_of}`);
  }catch(error){status('opsHealthStatus',error.message,true);}
 }
 const previousOpenPage=openPage;
 openPage=function(id,title){const result=previousOpenPage(id,title);if(id==='automation'&&canPage(id))void renderOperationsHealth();return result;};
})();
