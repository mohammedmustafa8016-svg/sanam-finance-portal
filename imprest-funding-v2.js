(() => {
  if(typeof I18N_AR_EN!=="undefined"){
    Object.assign(I18N_AR_EN,{
      "إضافة مبلغ للعهدة":"Add Funding to Imprest",
      "كشف حركة العهدة":"Imprest Ledger",
      "تسجيل استرداد":"Record Refund",
      "تمويل إضافي":"Additional Funding",
      "تمويل قيد الاعتماد":"Pending Funding",
      "الرصيد القائم بالسجل":"Ledger Outstanding",
      "الرصيد الأساسي":"Base Funding",
      "تمت تسويته":"Settled",
      "تم استرداده":"Refunded",
      "زيادة العهدة الحالية":"Top-up Existing Imprest",
      "عهدة مؤقتة لغرض محدد":"Temporary Funding",
      "الغرض":"Purpose",
      "المشروع / مركز التكلفة":"Project / Cost Center",
      "تاريخ التسوية المتوقع":"Expected Settlement Date",
      "تاريخ استحقاق الدفعة":"Payment Due Date",
      "حساب الصرف":"Funding Bank Account",
      "طلبات تمويل العهد":"Imprest Funding Requests",
      "لا توجد طلبات تمويل إضافية حتى الآن.":"No additional funding requests yet.",
      "الرصيد لا يزيد إلا بعد تنفيذ الدفعة بنكيًا.":"The imprest balance increases only after the linked payment is executed.",
      "إنشاء طلب التمويل":"Create Funding Request",
      "مرجع الاسترداد":"Refund Reference",
      "تاريخ الاسترداد":"Refund Date",
      "حفظ الاسترداد":"Post Refund",
      "عكس / تصحيح الحركة":"Reverse / Correct Entry",
      "سبب التصحيح":"Correction Reason",
      "سجل الحركات غير قابل للتعديل بعد التنفيذ؛ التصحيح يتم بحركة عكس مستقلة.":"Posted ledger entries are immutable; corrections are made through a separate reversal entry.",
      "يوجد حساب عهدة نشط لنفس الجهة أو الاسم. استخدم إضافة مبلغ إلى العهدة الحالية بدلاً من إنشاء عهدة مكررة.":"An active imprest already exists for the same entity or name. Add funding to the existing imprest instead of creating a duplicate.",
      "إنشاء عهدة مكررة استثنائيًا":"Create Duplicate as Exception",
      "سبب الاستثناء إلزامي للمدير المالي.":"An exception reason is mandatory for the CFO.",
      "الحركات":"Ledger Entries",
      "حالة الطلب":"Request Status",
      "حالة الدفعة":"Payment Status",
      "المنفذ":"Executed",
      "النوع":"Type",
      "المبلغ":"Amount",
      "الرصيد بعد الحركة":"Running Balance"
    });
  }

  const state={overview:[],requests:[],loaded:false,error:null};

  const canRead=()=>typeof profile!=="undefined" && !!profile && typeof canPage==="function" && canPage("imprest");
  const canFund=()=>canRead() && ["CFO","Supervisor","BankAccountant","APAccountant"].includes(profile.role) && !(typeof isReadonlyViewer==="function"&&isReadonlyViewer());
  const canRefund=()=>canRead() && ["CFO","Supervisor","BankAccountant"].includes(profile.role) && !(typeof isReadonlyViewer==="function"&&isReadonlyViewer());
  const moneyV=v=>typeof moneyHtml==="function"?moneyHtml(v):Number(v||0).toFixed(2);
  const escV=v=>typeof esc==="function"?esc(v):String(v??"");
  const tx=(ar,en)=>typeof currentLang!=="undefined"&&currentLang==="en"?en:ar;
  const overviewFor=id=>state.overview.find(x=>x.imprest_fund_id===id)||{base_funding:0,additional_funding:0,settled_amount:0,refunded_amount:0,ledger_outstanding:0,pending_funding:0,funding_count:0,currency_code:"SAR"};
  const fundById=id=>(typeof imprest!=="undefined"?imprest:[]).find(x=>x.id===id);

  function fundingTypeLabel(v){
    return v==="TOP_UP"?tx("زيادة العهدة الحالية","Top-up"):v==="TEMPORARY_FUNDING"?tx("عهدة مؤقتة","Temporary Funding"):v||"—";
  }
  function requestStatusLabel(v){
    return ({PAYMENT_CREATED:tx("بانتظار دورة الدفع","Payment Workflow"),FUNDED:tx("تم التمويل","Funded"),CANCELLED:tx("ملغي","Cancelled"),REVERSED:tx("معكوس","Reversed")})[v]||v||"—";
  }
  function entryTypeLabel(v){
    return ({
      OPENING_BALANCE:tx("الرصيد الأساسي","Base Funding"),
      OPENING_RECONCILIATION:tx("تسوية رصيد افتتاحية","Opening Reconciliation"),
      TOP_UP:tx("زيادة عهدة","Top-up"),
      TEMPORARY_FUNDING:tx("عهدة مؤقتة","Temporary Funding"),
      SETTLEMENT:tx("تصفية معتمدة","Approved Settlement"),
      REFUND:tx("استرداد","Refund"),
      MANUAL_ADJUSTMENT:tx("تعديل يدوي موثق","Audited Manual Adjustment"),
      REVERSAL:tx("عكس / تصحيح","Reversal")
    })[v]||v||"—";
  }

  async function loadData(){
    if(!canRead() || (typeof isReadonlyViewer==="function"&&isReadonlyViewer()))return;
    try{
      const [ov,req]=await Promise.all([
        sb.rpc("get_imprest_funding_overview"),
        sb.rpc("get_imprest_funding_requests",{p_fund_id:null})
      ]);
      const failed=[ov,req].find(x=>x.error);
      if(failed)throw failed.error;
      state.overview=ov.data||[];
      state.requests=req.data||[];
      state.loaded=true;state.error=null;
      renderEnhancements();
    }catch(err){
      console.error("Imprest Funding V2 load failed",err);
      state.error=err?.message||String(err);
      renderEnhancements();
    }
  }

  function legacyDuplicateCount(){
    const rows=typeof imprest!=="undefined"?imprest:[];
    const seen=new Map();let duplicateGroups=0;
    for(const f of rows){
      if(!f.custodian_id)continue;
      const k=`${String(f.company||"").trim().toLowerCase()}|${f.custodian_id}`;
      const n=(seen.get(k)||0)+1;seen.set(k,n);
    }
    for(const n of seen.values())if(n>1)duplicateGroups++;
    return duplicateGroups;
  }

  function renderPanel(){
    const box=document.getElementById("imprestFundingV2Panel");if(!box)return;
    if(typeof isReadonlyViewer==="function"&&isReadonlyViewer()){box.innerHTML="";return}
    const total=state.overview.reduce((a,x)=>{
      a.base+=Number(x.base_funding||0);a.add+=Number(x.additional_funding||0);
      a.pending+=Number(x.pending_funding||0);a.out+=Number(x.ledger_outstanding||0);
      return a;
    },{base:0,add:0,pending:0,out:0});
    const legacy=legacyDuplicateCount();
    const ledgerVariances=state.overview.filter(x=>{
      const f=fundById(x.imprest_fund_id);
      return f && Math.abs(Number(x.ledger_outstanding||0)-Number(f.unsettled||0))>0.01;
    });
    const rows=state.requests.slice(0,50).map(r=>`<tr>
      <td>${typeof fmt==="function"?fmt(r.requested_at):escV(r.requested_at)}</td>
      <td>${escV(r.fund_name)}</td>
      <td>${escV(fundingTypeLabel(r.funding_type))}</td>
      <td>${moneyV(r.amount)}</td>
      <td style="white-space:normal">${escV(r.purpose||"—")}</td>
      <td>${r.payment_id?`<span class="badge">${escV(r.payment_status||"—")}</span>`:"—"}</td>
      <td>${escV(r.supervisor_status||"—")} / ${escV(r.cfo_status||"—")}</td>
      <td>${r.executed_at?(typeof fmt==="function"?fmt(r.executed_at):escV(r.executed_at)):"—"}</td>
      <td>${typeof badge==="function"?badge(requestStatusLabel(r.request_status)):escV(requestStatusLabel(r.request_status))}</td>
    </tr>`).join("");
    box.innerHTML=`
      <div class="imprest-v2-summary">
        <div class="card"><span class="muted">${tx("الرصيد الأساسي","Base Funding")}</span><b>${moneyV(total.base)}</b></div>
        <div class="card"><span class="muted">${tx("تمويل إضافي منفذ","Executed Additional Funding")}</span><b>${moneyV(total.add)}</b></div>
        <div class="card"><span class="muted">${tx("تمويل قيد الاعتماد","Pending Funding")}</span><b>${moneyV(total.pending)}</b></div>
        <div class="card"><span class="muted">${tx("الرصيد القائم بالسجل","Ledger Outstanding")}</span><b>${moneyV(total.out)}</b></div>
      </div>
      ${ledgerVariances.length?`<div class="warning-box"><b>${tx("تنبيه رقابي:","Control alert:")}</b> ${tx("يوجد فرق بين الرصيد القائم في سجل الحركات وحقل «غير مسوى» في بعض العهد. لم يتم إجراء أي تصحيح تلقائي؛ راجع الحركة قبل أي تعديل.","A variance exists between the ledger outstanding balance and the operational unsettled field for one or more imprests. No automatic correction was made; review the movements before changing data.")} (${ledgerVariances.length})</div>`:""}
      <div class="note imprest-v2-control-note">
        <b>${tx("ضابط رقابي:","Control rule:")}</b>
        ${tx("أي مبلغ إضافي ينشئ دفعة داخل دورة المدفوعات الحالية، ولا يزيد رصيد العهدة إلا بعد التنفيذ البنكي الفعلي. مبلغ العهدة الأصلي محفوظ في سجل الحركات ولا يتم استبداله.","Each additional amount creates a payment in the existing payment workflow. The imprest balance increases only after actual bank execution. The base funding remains preserved in the ledger.")}
        ${legacy?`<br><span class="muted">${tx("توجد عهد تاريخية متعددة لنفس المسؤول في البيانات الحالية؛ تم الإبقاء عليها دون دمج تلقائي، وأصبح النظام يمنع إنشاء تكرارات جديدة.","Legacy multiple imprests for the same custodian exist in current data; they were preserved unchanged, while new duplicates are now blocked.")}</span>`:""}
      </div>
      ${state.error?`<div class="warning-box">${escV(state.error)}</div>`:""}
      <div class="row" style="margin:18px 0 10px"><div><h3 style="margin:0">${tx("طلبات تمويل العهد","Imprest Funding Requests")}</h3><div class="muted">${tx("الطلبات الجديدة تمر بنفس اعتماد المشرف والمدير المالي والتنفيذ البنكي المعتمد حاليًا.","New requests use the existing Supervisor, CFO and bank-execution workflow.")}</div></div></div>
      <div class="table-wrap"><table id="imprestFundingRequestsTable"><thead><tr>
        <th>${tx("التاريخ","Date")}</th><th>${tx("العهدة","Imprest")}</th><th>${tx("النوع","Type")}</th><th>${tx("المبلغ","Amount")}</th><th>${tx("الغرض","Purpose")}</th><th>${tx("حالة الدفعة","Payment Status")}</th><th>${tx("الاعتمادات","Approvals")}</th><th>${tx("المنفذ","Executed")}</th><th>${tx("حالة الطلب","Request Status")}</th>
      </tr></thead><tbody>${rows||`<tr><td colspan="9" class="muted">${tx("لا توجد طلبات تمويل إضافية حتى الآن.","No additional funding requests yet.")}</td></tr>`}</tbody></table></div>
    `;
    try{applyTableFilters?.(document.getElementById("imprestFundingRequestsTable"));applyLanguage?.(box)}catch{}
  }

  function injectRowActions(){
    if(typeof isReadonlyViewer==="function"&&isReadonlyViewer())return;
    const rows=[...document.querySelectorAll("#imprestBody tr")];
    const funds=typeof imprest!=="undefined"?imprest:[];
    rows.forEach((tr,i)=>{
      const f=funds[i];if(!f)return;
      const cell=tr.lastElementChild;if(!cell||cell.querySelector(".imprest-v2-actions"))return;
      const wrap=document.createElement("span");wrap.className="imprest-v2-actions";
      let html=` <button class="btn" type="button" onclick="openImprestLedgerV2('${escV(f.id)}')">${tx("كشف حركة العهدة","Imprest Ledger")}</button>`;
      if(canFund())html+=` <button class="btn primary" type="button" onclick="openImprestFundingV2('${escV(f.id)}')">+ ${tx("إضافة مبلغ للعهدة","Add Funding")}</button>`;
      if(canRefund())html+=` <button class="btn" type="button" onclick="openImprestRefundV2('${escV(f.id)}')">${tx("تسجيل استرداد","Record Refund")}</button>`;
      wrap.innerHTML=html;
      // The workspace moves buttons out of this wrapper. Check the actual action,
      // so another enhancement pass cannot append the same operation again.
      const existing=new Set([...cell.querySelectorAll('button[onclick]')].map(b=>b.getAttribute('onclick').trim()));
      [...wrap.querySelectorAll('button')].forEach(button=>{if(existing.has(button.getAttribute('onclick').trim()))button.remove();});
      if(wrap.children.length)cell.appendChild(wrap);
    });
  }

  function renderEnhancements(){renderPanel();injectRowActions()}

  window.openImprestFundingV2=function(id){
    if(!canFund())return;
    const f=fundById(id);if(!f)return;
    const options=(typeof bankDirectory!=="undefined"?bankDirectory:[]).map(b=>({
      value:b.id,label:`${b.bank_name} — ${b.account_name} — ${b.company}${b.account_type&&b.account_type!=="Operational"?` ⚠ ${b.account_type}`:""}`
    }));
    if(!options.length)return alert(tx("لا توجد حسابات بنكية متاحة لاستخدامها في طلب التمويل.","No bank accounts are available for the funding request."));
    const ov=overviewFor(id);
    showModal(tx("إضافة مبلغ للعهدة","Add Funding to Imprest"),`
      <div class="note"><b>${escV(f.company)} — ${escV(f.name)}</b><br>
      ${tx("الرصيد القائم بالسجل","Ledger Outstanding")}: ${moneyV(ov.ledger_outstanding||0)} |
      ${tx("تمويل قيد الاعتماد","Pending Funding")}: ${moneyV(ov.pending_funding||0)}<br>
      ${tx("الرصيد لا يزيد إلا بعد تنفيذ الدفعة بنكيًا.","The imprest balance increases only after the linked payment is executed.")}<br>
      ${tx("مستفيد الدفعة يُثبت باسم العهدة الرئيسية لضمان عدم تحويل التمويل إلى جهة مختلفة عن الحساب المرتبط.","The payment beneficiary is fixed to the master imprest name so funding cannot be redirected to a different entity.")}</div>
      <div class="modal-grid" style="margin-top:12px">
        ${select("ifv2_type",tx("نوع التمويل","Funding Type"),[{value:"TOP_UP",label:tx("زيادة العهدة الحالية","Top-up Existing Imprest")},{value:"TEMPORARY_FUNDING",label:tx("عهدة مؤقتة لغرض محدد","Temporary Funding")}])}
        ${input("ifv2_amount",tx("المبلغ","Amount"),0,"number")}
        ${input("ifv2_purpose",tx("الغرض","Purpose"),"")}
        ${input("ifv2_cost_center",tx("المشروع / مركز التكلفة","Project / Cost Center"),"")}
        ${input("ifv2_expected",tx("تاريخ التسوية المتوقع","Expected Settlement Date"),"","date")}
        ${input("ifv2_due",tx("تاريخ استحقاق الدفعة","Payment Due Date"),typeof riyadhToday==="function"?riyadhToday():"","date")}
        ${select("ifv2_bank",tx("حساب الصرف","Funding Bank Account"),options)}
        ${select("ifv2_priority",tx("الأولوية","Priority"),["عادي","عاجل","حرج"])}
        ${select("ifv2_docs",tx("المستندات","Documents"),["مكتملة","ناقصة"])}
      </div>
      <div class="row" style="margin-top:14px"><button class="btn primary" type="button" onclick="saveImprestFundingV2('${escV(id)}')">${tx("إنشاء طلب التمويل","Create Funding Request")}</button></div>
    `);
  };

  window.saveImprestFundingV2=async function(id){
    if(!canFund())return;
    const type=val("ifv2_type"),amount=Number(val("ifv2_amount")||0),purpose=(val("ifv2_purpose")||"").trim();
    const expected=val("ifv2_expected")||null,due=val("ifv2_due"),bankId=val("ifv2_bank");
    if(amount<=0||!purpose||!due||!bankId)return alert(tx("المبلغ والغرض وتاريخ الاستحقاق وحساب الصرف حقول إلزامية.","Amount, purpose, due date and bank account are required."));
    if(type==="TEMPORARY_FUNDING"&&!expected)return alert(tx("تاريخ التسوية المتوقع إلزامي للعهدة المؤقتة.","Expected settlement date is required for temporary funding."));
    const b=(typeof bankDirectory!=="undefined"?bankDirectory:[]).find(x=>x.id===bankId);
    if(b&&b.account_type&&b.account_type!=="Operational"){
      if(!confirm(tx(`تحذير: تم اختيار حساب محمي من نوع «${b.account_type}». هل تريد الاستمرار؟`,`Warning: a protected ${b.account_type} account is selected. Continue?`)))return;
    }
    const {data,error}=await sb.rpc("request_imprest_funding",{
      p_fund_id:id,p_funding_type:type,p_amount:amount,p_purpose:purpose,
      p_project_cost_center:(val("ifv2_cost_center")||"").trim()||null,
      p_expected_settlement_date:expected,p_due_date:due,p_bank_account_id:bankId,
      p_priority:val("ifv2_priority")||"عادي",p_documents_status:val("ifv2_docs")||"مكتملة"
    });
    if(error)return alert(imprestFundingError(error.message));
    closeModal();await reloadAll();openPage("imprest",displayText("العهد"));
    alert(tx("تم إنشاء طلب التمويل وربطه بدفعة في دورة الاعتمادات الحالية. لن يزداد رصيد العهدة إلا بعد تنفيذ الدفعة.","Funding request created and linked to the existing payment approval workflow. The imprest balance will increase only after execution."));
  };

  window.openImprestRefundV2=function(id){
    if(!canRefund())return;
    const f=fundById(id);if(!f)return;
    const ov=overviewFor(id);
    const options=(typeof bankDirectory!=="undefined"?bankDirectory:[]).map(b=>({value:b.id,label:`${b.bank_name} — ${b.account_name} — ${b.company}`}));
    showModal(tx("تسجيل استرداد","Record Refund"),`
      <div class="note">${escV(f.company)} — ${escV(f.name)} | ${tx("الرصيد القائم بالسجل","Ledger Outstanding")}: ${moneyV(ov.ledger_outstanding||0)}</div>
      <div class="modal-grid" style="margin-top:12px">
        ${input("irv2_amount",tx("المبلغ","Amount"),0,"number")}
        ${input("irv2_date",tx("تاريخ الاسترداد","Refund Date"),typeof riyadhToday==="function"?riyadhToday():"","date")}
        ${select("irv2_bank",tx("الحساب البنكي","Bank Account"),options)}
        ${input("irv2_ref",tx("مرجع الاسترداد","Refund Reference"),"")}
      </div>
      <label style="margin-top:10px">${tx("ملاحظات","Notes")}</label><textarea id="irv2_note" rows="3"></textarea>
      <div class="row" style="margin-top:14px"><button class="btn primary" type="button" onclick="saveImprestRefundV2('${escV(id)}')">${tx("حفظ الاسترداد","Post Refund")}</button></div>
    `);
  };

  window.saveImprestRefundV2=async function(id){
    const amount=Number(val("irv2_amount")||0),dateV=val("irv2_date"),bank=val("irv2_bank"),ref=(val("irv2_ref")||"").trim();
    if(amount<=0||!dateV||!bank||!ref)return alert(tx("المبلغ والتاريخ والحساب ومرجع الاسترداد حقول إلزامية.","Amount, date, bank account and refund reference are required."));
    const {error}=await sb.rpc("record_imprest_refund",{p_fund_id:id,p_amount:amount,p_refund_date:dateV,p_bank_account_id:bank,p_reference:ref,p_note:val("irv2_note")||null});
    if(error)return alert(imprestFundingError(error.message));
    closeModal();await reloadAll();openPage("imprest",displayText("العهد"));
  };

  window.openImprestLedgerV2=async function(id){
    if(!canRead())return;
    const f=fundById(id);if(!f)return;
    const {data,error}=await sb.rpc("get_imprest_ledger_entries",{p_fund_id:id});
    if(error)return alert(error.message);
    const rows=data||[],reversed=new Set(rows.filter(x=>x.reversal_of_entry_id).map(x=>x.reversal_of_entry_id));
    const ov=overviewFor(id);
    showModal(tx("كشف حركة العهدة","Imprest Ledger"),`
      <div class="imprest-v2-ledger-kpis">
        <div class="card"><span class="muted">${tx("الرصيد الأساسي","Base Funding")}</span><b>${moneyV(ov.base_funding)}</b></div>
        <div class="card"><span class="muted">${tx("تمويل إضافي","Additional Funding")}</span><b>${moneyV(ov.additional_funding)}</b></div>
        <div class="card"><span class="muted">${tx("تمت تسويته","Settled")}</span><b>${moneyV(ov.settled_amount)}</b></div>
        <div class="card"><span class="muted">${tx("تم استرداده","Refunded")}</span><b>${moneyV(ov.refunded_amount)}</b></div>
        <div class="card"><span class="muted">${tx("الرصيد القائم بالسجل","Ledger Outstanding")}</span><b>${moneyV(ov.ledger_outstanding)}</b></div>
      </div>
      <div class="note" style="margin:10px 0">${tx("سجل الحركات غير قابل للتعديل بعد التنفيذ؛ التصحيح يتم بحركة عكس مستقلة.","Posted ledger entries are immutable; corrections are made through a separate reversal entry.")}</div>
      <div class="table-wrap"><table id="imprestLedgerV2Table"><thead><tr>
        <th>${tx("التاريخ","Date")}</th><th>${tx("النوع","Type")}</th><th>${tx("الاتجاه","Direction")}</th><th>${tx("المبلغ","Amount")}</th><th>${tx("الرصيد بعد الحركة","Running Balance")}</th><th>${tx("المرجع","Reference")}</th><th>${tx("البيان","Description")}</th><th>${tx("إجراء","Action")}</th>
      </tr></thead><tbody>${rows.map(x=>{
        const ref=x.payment_id?`PAY ${x.payment_id.slice(0,8)}`:x.settlement_id?`SET ${x.settlement_id.slice(0,8)}`:x.refund_id?`REF ${x.refund_id.slice(0,8)}`:"—";
        const reversible=profile.role==="CFO"&&!reversed.has(x.ledger_entry_id)&&["TOP_UP","TEMPORARY_FUNDING","REFUND","MANUAL_ADJUSTMENT"].includes(x.entry_type);
        return `<tr><td>${typeof fmt==="function"?fmt(x.effective_at):escV(x.effective_at)}</td><td>${escV(entryTypeLabel(x.entry_type))}</td><td>${escV(x.direction)}</td><td>${moneyV(x.amount)}</td><td>${moneyV(x.running_balance)}</td><td>${escV(ref)}</td><td style="white-space:normal">${escV(x.description||"—")}</td><td>${reversible?`<button class="btn danger" type="button" onclick="reverseImprestLedgerV2('${x.ledger_entry_id}','${id}')">${tx("عكس / تصحيح الحركة","Reverse / Correct Entry")}</button>`:"—"}</td></tr>`;
      }).join("")||`<tr><td colspan="8">—</td></tr>`}</tbody></table></div>
    `);
    try{applyTableFilters?.(document.getElementById("imprestLedgerV2Table"))}catch{}
  };

  window.reverseImprestLedgerV2=async function(entryId,fundId){
    if(profile.role!=="CFO")return;
    const reason=prompt(tx("سبب التصحيح","Correction Reason"));
    if(!reason||!reason.trim())return;
    if(!confirm(tx("سيتم إنشاء حركة عكس مستقلة ولن يتم حذف الحركة الأصلية. متابعة؟","A separate reversal will be created; the original entry will remain. Continue?")))return;
    const {error}=await sb.rpc("reverse_imprest_ledger_entry",{p_entry_id:entryId,p_reason:reason.trim()});
    if(error)return alert(imprestFundingError(error.message));
    closeModal();await reloadAll();await openImprestLedgerV2(fundId);
  };

  function imprestFundingError(message=""){
    const m=String(message||"");
    if(m.includes("ACTIVE_IMPREST_DUPLICATE"))return tx("يوجد حساب عهدة نشط لنفس الجهة أو الاسم. استخدم إضافة مبلغ إلى العهدة الحالية بدلاً من إنشاء عهدة مكررة.","An active imprest already exists for the same entity or name. Add funding to the existing imprest instead.");
    if(m.includes("ONLY_CFO_CAN_OVERRIDE_IMPREST_DUPLICATE"))return tx("تجاوز التكرار متاح للمدير المالي فقط.","Only the CFO can override duplicate prevention.");
    if(m.includes("DUPLICATE_OVERRIDE_REASON_REQUIRED"))return tx("سبب الاستثناء إلزامي للمدير المالي.","An exception reason is mandatory for the CFO.");
    if(m.includes("REFUND_EXCEEDS_LEDGER_OUTSTANDING"))return tx("مبلغ الاسترداد أكبر من الرصيد القائم بالسجل.","Refund amount exceeds the ledger outstanding balance.");
    if(m.includes("FUNDING_REVERSAL_EXCEEDS_CURRENT_UNSETTLED"))return tx("لا يمكن عكس التمويل لأن جزءًا منه تمت تسويته أو لم يعد قائمًا بالكامل.","Funding cannot be reversed because part of it has already been settled or is no longer fully outstanding.");
    if(m.includes("IMPREST_FUNDING_PAYMENT_CORE_FIELDS_LOCKED"))return tx("الدفعة مرتبطة بطلب زيادة عهدة؛ لا يمكن تغيير المبلغ أو المستفيد أو الغرض من شاشة المدفوعات.","This payment is linked to an imprest funding request; amount, beneficiary and purpose cannot be changed from the payments page.");
    return m;
  }
  window.imprestFundingError=imprestFundingError;

  const originalImprestErrorMessage=window.imprestErrorMessage;
  window.imprestErrorMessage=function(message=""){
    const m=String(message||"");
    if(m.includes("IMPREST_HAS_FUNDING_HISTORY"))return tx(
      "لا يمكن حذف حساب العهدة لوجود سجل تمويل أو حركات مالية مرتبطة به. يجب الحفاظ على السجل التاريخي.",
      "This imprest account cannot be deleted because it has funding or ledger history. The audit trail must be preserved."
    );
    return typeof originalImprestErrorMessage==="function"?originalImprestErrorMessage(message):imprestFundingError(message);
  };

  const originalSaveImprest=window.saveImprest;
  if(typeof originalSaveImprest==="function"){
    window.saveImprest=async function(id=""){
      if(id)return originalSaveImprest(id);
      if(!canFund())return;
      const payload={
        p_type:val("i_type"),p_company:(val("i_company")||"").trim(),p_name:(val("i_name")||"").trim(),
        p_custodian_id:val("i_custodian")||null,p_balance:Number(val("i_balance")||0),
        p_unsettled:Number(val("i_unsettled")||0),p_aging:Number(val("i_aging")||0),
        p_status:val("i_status"),p_currency_code:"SAR"
      };
      if(!payload.p_company||!payload.p_name)return alert(tx("الشركة واسم العهدة حقول إلزامية.","Company and imprest name are required."));
      if(payload.p_balance<0||payload.p_unsettled<0||payload.p_aging<0)return alert(tx("لا يمكن أن تكون قيم الرصيد أو غير المسوى أو العمر سالبة.","Balance, unsettled amount and aging cannot be negative."));

      const chk=await sb.rpc("get_imprest_duplicate_candidate",{
        p_company:payload.p_company,p_name:payload.p_name,p_custodian_id:payload.p_custodian_id,p_currency_code:"SAR"
      });
      if(chk.error)return alert(imprestFundingError(chk.error.message));
      const duplicate=(chk.data||[])[0];
      let override=false,reason=null;
      if(duplicate){
        const info=`${duplicate.company} — ${duplicate.fund_name}${duplicate.custodian_name?` — ${duplicate.custodian_name}`:""}`;
        if(profile.role!=="CFO"){
          return alert(tx(`يوجد حساب عهدة نشط مطابق: ${info}. استخدم «إضافة مبلغ للعهدة» على الحساب الحالي.`,`Matching active imprest exists: ${info}. Use “Add Funding” on the existing imprest.`));
        }
        const proceed=confirm(tx(`يوجد حساب عهدة نشط مطابق:\n${info}\n\nالأفضل رقابيًا هو زيادة العهدة الحالية. هل تريد إنشاء عهدة منفصلة كاستثناء؟`,`Matching active imprest exists:\n${info}\n\nThe controlled approach is to top up the existing imprest. Create a separate imprest as an exception?`));
        if(!proceed)return;
        reason=prompt(tx("سبب إنشاء عهدة مكررة استثنائيًا (إلزامي):","Reason for exceptional duplicate imprest (required):"))||"";
        if(!reason.trim())return alert(tx("سبب الاستثناء إلزامي للمدير المالي.","An exception reason is mandatory for the CFO."));
        override=true;
      }

      const {error}=await sb.rpc("create_imprest_fund_v2",{...payload,p_duplicate_override:override,p_override_reason:reason});
      if(error)return alert(imprestFundingError(error.message));
      closeModal();await reloadAll();openPage("imprest",displayText("العهد"));
    };
  }

  const originalRenderImprest=window.renderImprest;
  if(typeof originalRenderImprest==="function"){
    window.renderImprest=function(...args){const r=originalRenderImprest(...args);setTimeout(renderEnhancements,0);return r};
  }

  const originalReloadAll=window.reloadAll;
  if(typeof originalReloadAll==="function"){
    window.reloadAll=async function(...args){
      const r=await originalReloadAll(...args);
      if(canRead() && !(typeof isReadonlyViewer==="function"&&isReadonlyViewer()))await loadData();
      return r;
    };
  }

  window.loadImprestFundingV2=loadData;
})();
