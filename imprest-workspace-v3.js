(() => {
  const STORAGE_KEY="sanam_imprest_workspace_tab_v3";
  const FILTER_ALL="ALL";
  const state={
    ready:false,
    fundingOverview:[],
    fundingRequests:[],
    fundingFilter:FILTER_ALL,
    ledgerFundId:"ALL",
    ledgerRows:[],
    loading:false,
    lastError:null
  };

  if(typeof I18N_AR_EN!=="undefined"){
    Object.assign(I18N_AR_EN,{
      "إدارة العهد والتمويل والتصفية والحركات والرقابة":"Imprest management, funding, settlement, ledger and controls",
      "نظرة عامة":"Overview",
      "سجل العهد":"Imprest Register",
      "طلبات التمويل":"Funding Requests",
      "التصفيات":"Settlements",
      "الحركات":"Ledger",
      "الرقابة والاستثناءات":"Controls & Exceptions",
      "إجمالي الرصيد القائم":"Total Current Balance",
      "إجمالي غير المسوى":"Total Unsettled",
      "إجمالي تحت التصفية":"Under Settlement",
      "إجمالي متاح للتصفية":"Available to Settle",
      "تمويل قيد الاعتماد":"Pending Funding",
      "تمويل إضافي منفذ":"Executed Additional Funding",
      "عدد العهد المسجلة":"Registered Imprests",
      "تحتاج تسوية":"Needs Settlement",
      "عهد متأخرة":"Overdue Imprests",
      "تصفيات بانتظار المراجعة":"Settlements Pending Review",
      "طلبات تمويل غير منفذة":"Unexecuted Funding Requests",
      "عرض وإدارة حسابات العهد الحالية بنفس الصلاحيات والإجراءات المعتمدة.":"View and manage current imprest accounts with the existing approved permissions and actions.",
      "طلبات زيادة العهد والعهد المؤقتة تمر عبر دورة المدفوعات الحالية دون أي تغيير.":"Top-ups and temporary funding requests continue through the existing payment workflow without any change.",
      "ملفات التصفية الحالية المرتبطة بمركز العمل ومراجعة المشرف.":"Existing settlement files linked to the Work Center and supervisor review.",
      "سجل مركزي للقراءة فقط يجمع حركات العهد المسجلة دون تغيير منطق التسجيل.":"Read-only central ledger view of recorded imprest movements without changing posting logic.",
      "جميع العهد":"All Imprests",
      "بانتظار المشرف":"Awaiting Supervisor",
      "بانتظار المدير المالي":"Awaiting CFO",
      "معتمد للدفع":"Approved for Payment",
      "منفذ":"Executed",
      "مرفوض / ملغي":"Rejected / Cancelled",
      "كل الحالات":"All Statuses",
      "لا توجد طلبات مطابقة لهذا العرض.":"No requests match this view.",
      "لا توجد حركات مسجلة لهذا العرض.":"No ledger entries match this view.",
      "لا توجد استثناءات رقابية حالية ضمن القواعد المعتمدة.":"No current control exceptions under the approved rules.",
      "نوع الاستثناء":"Exception Type",
      "التفاصيل":"Details",
      "الخطورة":"Severity",
      "فرق بين السجل وغير المسوى":"Ledger / Unsettled Variance",
      "تمويل قيد الاعتماد":"Funding Pending Approval",
      "تصفية بانتظار المراجعة":"Settlement Pending Review",
      "استثناء تكرار عهدة":"Duplicate Imprest Exception",
      "فرق رقابي":"Control Variance",
      "تحذير":"Warning",
      "معلومة":"Info",
      "الرصيد بالسجل":"Ledger Balance",
      "غير المسوى التشغيلي":"Operational Unsettled",
      "الطلب لا يزال غير منفذ.":"The funding request has not been executed yet.",
      "ملف التصفية بانتظار المراجعة.":"The settlement file is awaiting review.",
      "تم إنشاء العهدة باستثناء معتمد لتجاوز منع التكرار.":"The imprest was created under an approved duplicate override.",
      "هذه الصفحة أعيد تنظيمها كطبقة واجهة فقط؛ جميع الصلاحيات ومسارات الاعتماد وقواعد الرصيد والبيانات الحالية لم تتغير.":"This page was reorganized as a UI layer only; permissions, approval flows, balance rules, and current data remain unchanged."
    });
  }

  const tx=(ar,en)=>typeof currentLang!=="undefined"&&currentLang==="en"?en:ar;
  const e=v=>typeof esc==="function"?esc(v):String(v??"");
  const m=v=>typeof moneyHtml==="function"?moneyHtml(v):Number(v||0).toFixed(2);
  const formatDate=v=>typeof fmt==="function"?fmt(v):e(v||"—");
  const canRead=()=>typeof profile!=="undefined"&&!!profile&&typeof canPage==="function"&&canPage("imprest");
  const readonly=()=>typeof isReadonlyViewer==="function"&&isReadonlyViewer();

  const tabs=[
    ["overview","نظرة عامة","Overview"],
    ["register","سجل العهد","Imprest Register"],
    ["funding","طلبات التمويل","Funding Requests"],
    ["settlements","التصفيات","Settlements"],
    ["ledger","الحركات","Ledger"],
    ["controls","الرقابة والاستثناءات","Controls & Exceptions"]
  ];

  function getFund(id){
    return (typeof imprest!=="undefined"?imprest:[]).find(x=>x.id===id);
  }
  function getSummary(id){
    return (typeof imprestFundSummary!=="undefined"?imprestFundSummary:[]).find(x=>x.imprest_fund_id===id)||{
      under_settlement:0,approved_settlements:0,available_to_settle:0
    };
  }
  function normalize(v){return String(v??"").trim().toLowerCase()}
  function requestFilterMatch(r,filter){
    if(filter===FILTER_ALL)return true;
    const ps=normalize(r.payment_status),ss=normalize(r.supervisor_status),cs=normalize(r.cfo_status),rs=normalize(r.request_status);
    if(filter==="SUPERVISOR")return !r.executed_at&&(ps.includes("مشرف")||ps.includes("supervisor")||(ss==="معلق"||ss==="pending"));
    if(filter==="CFO")return !r.executed_at&&(ps.includes("cfo")||ps.includes("المدير المالي")||ps.includes("اعتماد cfo")||(ss==="موافق"||ss==="approved")&&(cs==="معلق"||cs==="pending"));
    if(filter==="APPROVED")return !r.executed_at&&(ps.includes("معتمد للدفع")||ps.includes("approved for payment")||(cs==="موافق"||cs==="approved"));
    if(filter==="EXECUTED")return !!r.executed_at||rs==="funded";
    if(filter==="REJECTED")return rs==="cancelled"||rs==="reversed"||ps.includes("مرفوض")||ps.includes("rejected")||ps.includes("ملغي")||ps.includes("cancel");
    return true;
  }

  function ensureWorkspace(){
    const section=document.getElementById("imprest");
    if(!section||document.getElementById("imprestWorkspaceTabs"))return;
    const header=[...section.children].find(x=>x.classList?.contains("row"));
    if(header){
      header.classList.add("imprest-workspace-header");
      const muted=header.querySelector(".muted");
      if(muted)muted.textContent=tx("إدارة العهد والتمويل والتصفية والحركات والرقابة","Imprest management, funding, settlement, ledger and controls");
    }

    const nav=document.createElement("div");
    nav.id="imprestWorkspaceTabs";
    nav.className="imprest-workspace-tabs";
    nav.setAttribute("role","tablist");
    nav.innerHTML=tabs.filter(x=>['register','funding','settlements'].includes(x[0])).map(([key,ar,en])=>`<button class="imprest-workspace-tab" type="button" role="tab" data-imprest-tab="${key}" onclick="switchImprestWorkspaceTab('${key}')">${tx(ar,en)}</button>`).join("");

    const workspace=document.createElement("div");
    workspace.id="imprestWorkspace";
    workspace.innerHTML=tabs.map(([key])=>`<div id="imprestWorkspacePanel_${key}" class="imprest-workspace-panel" data-imprest-panel="${key}"></div>`).join("");

    const tools=document.createElement('details');tools.className='imprest-secondary-tools';
    const summary=document.createElement('summary');summary.textContent=tx('ملخص وحركة ورقابة','Summary, ledger & controls');tools.append(summary);
    for(const [key,ar,en] of tabs.filter(x=>!['register','funding','settlements'].includes(x[0]))){const button=document.createElement('button');button.type='button';button.className='btn';button.textContent=tx(ar,en);button.dataset.imprestSecondary=key;button.onclick=()=>{switchTab(key);tools.open=false;};tools.append(button);}
    if(header)header.after(nav,tools,workspace);else section.prepend(nav,tools,workspace);

    const registerWrap=document.getElementById("imprestTable")?.closest(".table-wrap");
    if(registerWrap)document.getElementById("imprestWorkspacePanel_register")?.appendChild(registerWrap);

    const settlementTable=document.getElementById("imprestSettlementsTable");
    const settlementWrap=settlementTable?.closest(".table-wrap");
    const settlementHeader=settlementWrap?.previousElementSibling;
    const settlementPanel=document.getElementById("imprestWorkspacePanel_settlements");
    if(settlementHeader&&settlementHeader.classList?.contains("row"))settlementPanel?.appendChild(settlementHeader);
    if(settlementWrap)settlementPanel?.appendChild(settlementWrap);

    const legacy=document.getElementById("imprestFundingV2Panel");
    legacy?.classList.add("imprest-v2-source-hidden");

    document.getElementById("imprestWorkspacePanel_overview").innerHTML='<div id="imprestWorkspaceOverview"></div>';
    document.getElementById("imprestWorkspacePanel_funding").innerHTML='<div id="imprestWorkspaceFunding"></div>';
    document.getElementById("imprestWorkspacePanel_ledger").innerHTML='<div id="imprestWorkspaceLedger"></div>';
    document.getElementById("imprestWorkspacePanel_controls").innerHTML='<div id="imprestWorkspaceControls"></div>';

    const requested=localStorage.getItem(STORAGE_KEY)||"register";
    switchTab(tabs.some(x=>x[0]===requested)?requested:"register",false);
    state.ready=true;
  }

  function switchTab(key,refresh=true){
    ensureWorkspace();
    document.querySelectorAll("#imprestWorkspaceTabs .imprest-workspace-tab").forEach(btn=>{
      const active=btn.dataset.imprestTab===key;
      btn.classList.toggle("active",active);
      btn.setAttribute("aria-selected",active?"true":"false");
    });
    document.querySelectorAll("#imprestWorkspace .imprest-workspace-panel").forEach(panel=>panel.classList.toggle("active",panel.dataset.imprestPanel===key));
    localStorage.setItem(STORAGE_KEY,key);
    if(refresh){
      if(key==="ledger")void loadLedger();
      if(key==="overview"||key==="funding"||key==="controls")void refreshWorkspaceData(false);
    }
    try{installUniversalColumnCustomizers?.();installTableFilters?.()}catch{}
  }
  window.switchImprestWorkspaceTab=switchTab;

  function renderOverview(){
    const root=document.getElementById("imprestWorkspaceOverview");if(!root)return;
    const funds=typeof imprest!=="undefined"?imprest:[];
    const summaries=typeof imprestFundSummary!=="undefined"?imprestFundSummary:[];
    const settlements=typeof imprestSettlements!=="undefined"?imprestSettlements:[];
    const totalBalance=funds.reduce((a,x)=>a+Number(x.balance||0),0);
    const totalUnsettled=funds.reduce((a,x)=>a+Number(x.unsettled||0),0);
    const under=summaries.reduce((a,x)=>a+Number(x.under_settlement||0),0);
    const available=summaries.reduce((a,x)=>a+Number(x.available_to_settle||0),0);
    const pendingFunding=state.fundingOverview.reduce((a,x)=>a+Number(x.pending_funding||0),0);
    const additional=state.fundingOverview.reduce((a,x)=>a+Number(x.additional_funding||0),0);
    const needs=funds.filter(x=>normalize(x.status).includes("تحتاج تسوية")||normalize(x.status).includes("needs settlement")).length;
    const overdue=funds.filter(x=>normalize(x.status).includes("متأخرة")||normalize(x.status).includes("overdue")).length;
    const settlementReview=settlements.filter(x=>normalize(x.settlement_status)==="pending review"||normalize(x.task_status).includes("بانتظار المراجعة")||normalize(x.task_status).includes("pending review")).length;
    const fundingUnexecuted=state.fundingRequests.filter(x=>!x.executed_at&&normalize(x.request_status)!=="cancelled"&&normalize(x.request_status)!=="reversed").length;

    root.innerHTML=`
      <div class="imprest-workspace-subtitle">${tx("ملخص تنفيذي ورقابي للعهد الحالية دون تغيير أي مسار تشغيلي.","Executive and control summary of current imprests without changing any operating workflow.")}</div>
      <div class="imprest-workspace-kpis">
        <div class="imprest-workspace-kpi"><span>${tx("إجمالي الرصيد القائم","Total Current Balance")}</span><b>${m(totalBalance)}</b></div>
        <div class="imprest-workspace-kpi"><span>${tx("إجمالي غير المسوى","Total Unsettled")}</span><b>${m(totalUnsettled)}</b></div>
        <div class="imprest-workspace-kpi"><span>${tx("إجمالي تحت التصفية","Under Settlement")}</span><b>${m(under)}</b></div>
        <div class="imprest-workspace-kpi"><span>${tx("إجمالي متاح للتصفية","Available to Settle")}</span><b>${m(available)}</b></div>
        <div class="imprest-workspace-kpi"><span>${tx("تمويل قيد الاعتماد","Pending Funding")}</span><b>${m(pendingFunding)}</b></div>
        <div class="imprest-workspace-kpi"><span>${tx("تمويل إضافي منفذ","Executed Additional Funding")}</span><b>${m(additional)}</b></div>
      </div>
      <div class="imprest-workspace-kpis secondary">
        <div class="imprest-workspace-kpi"><span>${tx("عدد العهد المسجلة","Registered Imprests")}</span><b>${funds.length}</b></div>
        <div class="imprest-workspace-kpi"><span>${tx("تحتاج تسوية","Needs Settlement")}</span><b>${needs}</b></div>
        <div class="imprest-workspace-kpi"><span>${tx("عهد متأخرة","Overdue Imprests")}</span><b>${overdue}</b></div>
        <div class="imprest-workspace-kpi"><span>${tx("تصفيات بانتظار المراجعة","Settlements Pending Review")}</span><b>${settlementReview}</b></div>
        <div class="imprest-workspace-kpi"><span>${tx("طلبات تمويل غير منفذة","Unexecuted Funding Requests")}</span><b>${fundingUnexecuted}</b></div>
      </div>
      <div class="note">${tx("هذه الصفحة أعيد تنظيمها كطبقة واجهة فقط؛ جميع الصلاحيات ومسارات الاعتماد وقواعد الرصيد والبيانات الحالية لم تتغير.","This page was reorganized as a UI layer only; permissions, approval flows, balance rules, and current data remain unchanged.")}</div>
    `;
  }

  function fundingType(v){
    return v==="TOP_UP"?tx("زيادة عهدة","Top-up"):v==="TEMPORARY_FUNDING"?tx("عهدة مؤقتة","Temporary Funding"):v||"—";
  }
  function fundingRequestStatus(v){
    return ({PAYMENT_CREATED:tx("بانتظار دورة الدفع","Payment Workflow"),FUNDED:tx("تم التمويل","Funded"),CANCELLED:tx("ملغي","Cancelled"),REVERSED:tx("معكوس","Reversed")})[v]||v||"—";
  }

  function setFundingFilter(filter){
    state.fundingFilter=filter;
    renderFunding();
  }
  window.setImprestWorkspaceFundingFilter=setFundingFilter;

  function renderFunding(){
    const root=document.getElementById("imprestWorkspaceFunding");if(!root)return;
    if(readonly()){
      root.innerHTML=`<div class="imprest-workspace-empty">${tx("تفاصيل تمويل العهد غير متاحة للمستخدم المطلع وفق الصلاحيات الحالية.","Imprest funding detail is not available to read-only viewers under the current permissions.")}</div>`;
      return;
    }
    const filters=[
      [FILTER_ALL,"الكل","All"],
      ["SUPERVISOR","بانتظار المشرف","Awaiting Supervisor"],
      ["CFO","بانتظار المدير المالي","Awaiting CFO"],
      ["APPROVED","معتمد للدفع","Approved for Payment"],
      ["EXECUTED","منفذ","Executed"],
      ["REJECTED","مرفوض / ملغي","Rejected / Cancelled"]
    ];
    const rows=state.fundingRequests.filter(r=>requestFilterMatch(r,state.fundingFilter));
    root.innerHTML=`
      <div class="imprest-workspace-subtitle">${tx("طلبات زيادة العهد والعهد المؤقتة تمر عبر دورة المدفوعات الحالية دون أي تغيير.","Top-ups and temporary funding requests continue through the existing payment workflow without any change.")}</div>
      <div class="imprest-workspace-filterbar">${filters.map(([key,ar,en])=>`<button type="button" class="view-chip ${state.fundingFilter===key?"active":""}" onclick="setImprestWorkspaceFundingFilter('${key}')">${tx(ar,en)}</button>`).join("")}</div>
      <div class="table-wrap"><table id="imprestWorkspaceFundingTable"><thead><tr>
        <th>${tx("التاريخ","Date")}</th><th>${tx("العهدة","Imprest")}</th><th>${tx("الشركة","Company")}</th><th>${tx("النوع","Type")}</th>
        <th>${tx("الغرض","Purpose")}</th><th>${tx("المبلغ","Amount")}</th><th>${tx("حالة الدفعة","Payment Status")}</th>
        <th>${tx("اعتماد المشرف","Supervisor Approval")}</th><th>${tx("اعتماد CFO","CFO Approval")}</th><th>${tx("تم التنفيذ","Executed")}</th><th>${tx("الحالة","Status")}</th>
      </tr></thead><tbody>${rows.map(r=>`<tr>
        <td>${formatDate(r.requested_at)}</td><td>${e(r.fund_name||"—")}</td><td>${e(r.company||"—")}</td><td>${e(fundingType(r.funding_type))}</td>
        <td>${e(r.purpose||"—")}</td><td data-amount="${Number(r.amount||0)}">${m(r.amount)}</td><td>${typeof badge==="function"?badge(r.payment_status||"—"):e(r.payment_status||"—")}</td>
        <td>${e(r.supervisor_status||"—")}</td><td>${e(r.cfo_status||"—")}</td><td>${r.executed_at?formatDate(r.executed_at):"—"}</td><td>${e(fundingRequestStatus(r.request_status))}</td>
      </tr>`).join("")||`<tr><td colspan="11" class="muted">${tx("لا توجد طلبات مطابقة لهذا العرض.","No requests match this view.")}</td></tr>`}</tbody></table></div>
    `;
    try{installUniversalColumnCustomizers?.();installTableFilters?.();applyLanguage?.(root)}catch{}
  }

  async function loadLedger(){
    ensureWorkspace();
    const root=document.getElementById("imprestWorkspaceLedger");if(!root)return;
    if(readonly()){
      root.innerHTML=`<div class="imprest-workspace-empty">${tx("تفاصيل سجل حركات العهد غير متاحة للمستخدم المطلع وفق الصلاحيات الحالية.","Imprest ledger detail is not available to read-only viewers under the current permissions.")}</div>`;
      return;
    }
    root.innerHTML=`<div class="imprest-workspace-empty">${tx("جارٍ تحميل سجل الحركات...","Loading ledger entries...")}</div>`;
    const funds=(typeof imprest!=="undefined"?imprest:[]).filter(f=>state.ledgerFundId==="ALL"||f.id===state.ledgerFundId);
    try{
      const results=await Promise.all(funds.map(async f=>{
        const res=await sb.rpc("get_imprest_ledger_entries",{p_fund_id:f.id});
        if(res.error)throw res.error;
        return (res.data||[]).map(x=>({...x,fund_name:f.name,company:f.company,custodian_name:f.custodian?.full_name||"—"}));
      }));
      state.ledgerRows=results.flat().sort((a,b)=>new Date(b.effective_at||0)-new Date(a.effective_at||0));
      renderLedger();
    }catch(err){
      state.lastError=err?.message||String(err);
      root.innerHTML=`<div class="warning-box">${e(state.lastError)}</div>`;
    }
  }
  window.loadImprestWorkspaceLedger=loadLedger;

  function ledgerType(v){
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
  function ledgerRef(x){
    if(x.payment_id)return `PAY ${String(x.payment_id).slice(0,8)}`;
    if(x.settlement_id)return `SET ${String(x.settlement_id).slice(0,8)}`;
    if(x.refund_id)return `REF ${String(x.refund_id).slice(0,8)}`;
    return "—";
  }
  function changeLedgerFund(id){
    state.ledgerFundId=id||"ALL";
    void loadLedger();
  }
  window.changeImprestWorkspaceLedgerFund=changeLedgerFund;

  function renderLedger(){
    const root=document.getElementById("imprestWorkspaceLedger");if(!root)return;
    const funds=typeof imprest!=="undefined"?imprest:[];
    root.innerHTML=`
      <div class="imprest-workspace-toolbar">
        <div>
          <div class="imprest-workspace-subtitle" style="margin-bottom:0">${tx("سجل مركزي للقراءة فقط يجمع حركات العهد المسجلة دون تغيير منطق التسجيل.","Read-only central ledger view of recorded imprest movements without changing posting logic.")}</div>
        </div>
        <select onchange="changeImprestWorkspaceLedgerFund(this.value)">
          <option value="ALL" ${state.ledgerFundId==="ALL"?"selected":""}>${tx("جميع العهد","All Imprests")}</option>
          ${funds.map(f=>`<option value="${e(f.id)}" ${state.ledgerFundId===f.id?"selected":""}>${e(f.company)} — ${e(f.name)}</option>`).join("")}
        </select>
      </div>
      <div class="table-wrap"><table id="imprestWorkspaceLedgerTable"><thead><tr>
        <th>${tx("التاريخ","Date")}</th><th>${tx("العهدة","Imprest")}</th><th>${tx("الشركة","Company")}</th><th>${tx("النوع","Type")}</th>
        <th>${tx("الاتجاه","Direction")}</th><th>${tx("المبلغ","Amount")}</th><th>${tx("الرصيد بعد الحركة","Running Balance")}</th>
        <th>${tx("المرجع","Reference")}</th><th>${tx("البيان","Description")}</th><th>${tx("المستخدم","User")}</th>
      </tr></thead><tbody>${state.ledgerRows.map(x=>`<tr>
        <td>${formatDate(x.effective_at)}</td><td>${e(x.fund_name||"—")}</td><td>${e(x.company||"—")}</td><td>${e(ledgerType(x.entry_type))}</td>
        <td>${e(x.direction||"—")}</td><td data-amount="${Number(x.amount||0)}">${m(x.amount)}</td><td>${m(x.running_balance)}</td>
        <td>${e(ledgerRef(x))}</td><td>${e(x.description||"—")}</td><td>${e(x.created_by_name||"—")}</td>
      </tr>`).join("")||`<tr><td colspan="10" class="muted">${tx("لا توجد حركات مسجلة لهذا العرض.","No ledger entries match this view.")}</td></tr>`}</tbody></table></div>
    `;
    try{installUniversalColumnCustomizers?.();installTableFilters?.();applyLanguage?.(root)}catch{}
  }

  function controls(){
    const rows=[];
    const funds=typeof imprest!=="undefined"?imprest:[];
    const settlements=typeof imprestSettlements!=="undefined"?imprestSettlements:[];
    const overviewByFund=new Map(state.fundingOverview.map(x=>[x.imprest_fund_id,x]));

    funds.forEach(f=>{
      const ov=overviewByFund.get(f.id);
      if(ov&&Math.abs(Number(ov.ledger_outstanding||0)-Number(f.unsettled||0))>0.01){
        rows.push({
          severity:"CRITICAL",type:tx("فرق بين السجل وغير المسوى","Ledger / Unsettled Variance"),fund:f,
          amount:Math.abs(Number(ov.ledger_outstanding||0)-Number(f.unsettled||0)),
          detail:`${tx("الرصيد بالسجل","Ledger Balance")}: ${m(ov.ledger_outstanding)} — ${tx("غير المسوى التشغيلي","Operational Unsettled")}: ${m(f.unsettled)}`
        });
      }
      const status=normalize(f.status);
      if(status.includes("متأخرة")||status.includes("overdue")){
        rows.push({severity:"WARNING",type:tx("عهد متأخرة","Overdue Imprests"),fund:f,amount:Number(f.unsettled||0),detail:`${tx("العمر","Aging")}: ${Number(f.aging||0)} ${tx("يوم","days")}`});
      }else if(status.includes("تحتاج تسوية")||status.includes("needs settlement")){
        rows.push({severity:"WARNING",type:tx("تحتاج تسوية","Needs Settlement"),fund:f,amount:Number(f.unsettled||0),detail:e(f.status)});
      }
      if(f.duplicate_override===true){
        rows.push({severity:"INFO",type:tx("استثناء تكرار عهدة","Duplicate Imprest Exception"),fund:f,amount:Number(f.balance||0),detail:tx("تم إنشاء العهدة باستثناء معتمد لتجاوز منع التكرار.","The imprest was created under an approved duplicate override.")+(f.duplicate_override_reason?` — ${e(f.duplicate_override_reason)}`:"")});
      }
    });

    state.fundingRequests.filter(r=>!r.executed_at&&normalize(r.request_status)!=="cancelled"&&normalize(r.request_status)!=="reversed").forEach(r=>{
      rows.push({severity:"WARNING",type:tx("تمويل قيد الاعتماد","Funding Pending Approval"),fund:getFund(r.imprest_fund_id)||{name:r.fund_name,company:r.company},amount:Number(r.amount||0),detail:tx("الطلب لا يزال غير منفذ.","The funding request has not been executed yet.")});
    });

    settlements.filter(s=>normalize(s.settlement_status)==="pending review"||normalize(s.task_status).includes("بانتظار المراجعة")||normalize(s.task_status).includes("pending review")).forEach(s=>{
      rows.push({severity:"WARNING",type:tx("تصفية بانتظار المراجعة","Settlement Pending Review"),fund:getFund(s.imprest_fund_id)||{name:s.imprest_name,company:"—"},amount:Number(s.amount||0),detail:tx("ملف التصفية بانتظار المراجعة.","The settlement file is awaiting review.")});
    });
    return rows;
  }

  function renderControls(){
    const root=document.getElementById("imprestWorkspaceControls");if(!root)return;
    if(readonly()){
      root.innerHTML=`<div class="imprest-workspace-empty">${tx("لوحة الرقابة التفصيلية غير متاحة للمستخدم المطلع وفق الصلاحيات الحالية.","Detailed control monitoring is not available to read-only viewers under the current permissions.")}</div>`;
      return;
    }
    const rows=controls();
    const critical=rows.filter(x=>x.severity==="CRITICAL").length;
    const warning=rows.filter(x=>x.severity==="WARNING").length;
    const info=rows.filter(x=>x.severity==="INFO").length;
    root.innerHTML=`
      <div class="imprest-workspace-subtitle">${tx("تعرض هذه الصفحة الاستثناءات الناتجة فقط عن القواعد والحالات الموجودة فعليًا في النظام، دون إضافة قواعد محاسبية أو زمنية جديدة.","This page shows only exceptions arising from rules and statuses already present in the system, without adding new accounting or timing rules.")}</div>
      <div class="imprest-control-summary">
        <div class="card"><span class="muted">${tx("إجمالي الاستثناءات","Total Exceptions")}</span><b>${rows.length}</b></div>
        <div class="card"><span class="muted">${tx("فرق رقابي","Control Variance")}</span><b>${critical}</b></div>
        <div class="card"><span class="muted">${tx("تحذير","Warning")}</span><b>${warning}</b></div>
        <div class="card"><span class="muted">${tx("معلومة","Info")}</span><b>${info}</b></div>
      </div>
      <div class="table-wrap"><table id="imprestWorkspaceControlsTable"><thead><tr>
        <th>${tx("الخطورة","Severity")}</th><th>${tx("نوع الاستثناء","Exception Type")}</th><th>${tx("العهدة","Imprest")}</th><th>${tx("التفاصيل","Details")}</th><th>${tx("المبلغ","Amount")}</th>
      </tr></thead><tbody>${rows.map(x=>`<tr class="${x.severity==="CRITICAL"?"imprest-control-row-critical":x.severity==="WARNING"?"imprest-control-row-warning":"imprest-control-row-info"}">
        <td>${x.severity==="CRITICAL"?tx("فرق رقابي","Control Variance"):x.severity==="WARNING"?tx("تحذير","Warning"):tx("معلومة","Info")}</td>
        <td>${e(x.type)}</td><td>${e(x.fund?.company||"—")} — ${e(x.fund?.name||"—")}</td><td>${x.detail}</td><td data-amount="${Number(x.amount||0)}">${m(x.amount)}</td>
      </tr>`).join("")||`<tr><td colspan="5" class="muted">${tx("لا توجد استثناءات رقابية حالية ضمن القواعد المعتمدة.","No current control exceptions under the approved rules.")}</td></tr>`}</tbody></table></div>
    `;
    try{installUniversalColumnCustomizers?.();installTableFilters?.();applyLanguage?.(root)}catch{}
  }

  async function refreshWorkspaceData(forceLedger=false){
    ensureWorkspace();
    if(!canRead())return;
    if(readonly()){
      renderOverview();
      renderFunding();
      renderControls();
      return;
    }
    if(state.loading)return;
    state.loading=true;
    try{
      const [ov,req]=await Promise.all([
        sb.rpc("get_imprest_funding_overview"),
        sb.rpc("get_imprest_funding_requests",{p_fund_id:null})
      ]);
      if(ov.error)throw ov.error;
      if(req.error)throw req.error;
      state.fundingOverview=ov.data||[];
      state.fundingRequests=req.data||[];
      state.lastError=null;
      renderOverview();
      renderFunding();
      renderControls();
      if(forceLedger||document.getElementById("imprestWorkspacePanel_ledger")?.classList.contains("active"))await loadLedger();
    }catch(err){
      state.lastError=err?.message||String(err);
      console.error("Imprest Workspace V3 refresh failed",err);
      const active=document.querySelector("#imprestWorkspace .imprest-workspace-panel.active");
      if(active&&["overview","funding","controls"].includes(active.dataset.imprestPanel)){
        active.innerHTML=`<div class="warning-box">${e(state.lastError)}</div>`;
      }
    }finally{
      state.loading=false;
    }
  }
  window.refreshImprestWorkspaceV3=refreshWorkspaceData;


  let imprestActionMenuEl=null;
  let imprestActionObserver=null;
  let imprestActionCompactScheduled=false;

  function closeImprestActionMenuV3(){
    if(imprestActionMenuEl){
      imprestActionMenuEl.remove();
      imprestActionMenuEl=null;
    }
    document.querySelectorAll("#imprestBody .imprest-action-trigger[aria-expanded='true']").forEach(btn=>btn.setAttribute("aria-expanded","false"));
  }
  window.closeImprestActionMenuV3=closeImprestActionMenuV3;

  function imprestActionRank(button){
    const h=String(button?.getAttribute("onclick")||"");
    if(h.includes("openImprestSettlementModal"))return 10;
    if(h.includes("openImprestLedgerV2"))return 20;
    if(h.includes("openImprestFundingV2"))return 30;
    if(h.includes("openImprestRefundV2"))return 40;
    if(h.includes("openImprestModal"))return 50;
    if(h.includes("deleteImprest"))return 90;
    return 60;
  }

  function openImprestActionMenuV3(trigger){
    const cell=trigger?.closest(".imprest-action-cell");
    const source=cell?.querySelector(":scope > .imprest-action-source");
    if(!cell||!source)return;
    const buttons=[...source.querySelectorAll("button")].filter(btn=>!btn.disabled&&!btn.classList.contains("hidden")).sort((a,b)=>imprestActionRank(a)-imprestActionRank(b));
    closeImprestActionMenuV3();
    if(!buttons.length)return;

    const menu=document.createElement("div");
    menu.className="imprest-action-popover";
    menu.setAttribute("role","menu");
    menu.dir=document.documentElement.dir||"rtl";
    buttons.forEach(original=>{
      const item=document.createElement("button");
      item.type="button";
      item.className="imprest-action-menu-item";
      if(original.classList.contains("danger")||String(original.getAttribute("onclick")||"").includes("deleteImprest"))item.classList.add("danger");
      if(original.classList.contains("primary"))item.classList.add("primary-action");
      item.setAttribute("role","menuitem");
      item.textContent=String(original.textContent||"").trim();
      item.onclick=()=>{
        closeImprestActionMenuV3();
        original.click();
      };
      menu.appendChild(item);
    });

    document.body.appendChild(menu);
    imprestActionMenuEl=menu;
    trigger.setAttribute("aria-expanded","true");

    const rect=trigger.getBoundingClientRect();
    const width=Math.min(250,Math.max(190,menu.getBoundingClientRect().width||210));
    menu.style.width=width+"px";
    const measured=menu.getBoundingClientRect();
    const rtl=(document.documentElement.dir||"rtl")==="rtl";
    const desiredLeft=rtl?rect.right-width:rect.left;
    const left=Math.max(8,Math.min(desiredLeft,window.innerWidth-width-8));
    const below=rect.bottom+6;
    const top=below+measured.height<=window.innerHeight-8?below:Math.max(8,rect.top-measured.height-6);
    menu.style.left=left+"px";
    menu.style.top=top+"px";
  }
  window.openImprestActionMenuV3=openImprestActionMenuV3;

  function compactImprestActions(){
    document.querySelectorAll("#imprestBody tr").forEach(tr=>{
      const cell=tr.lastElementChild;
      if(!cell)return;
      cell.classList.add("imprest-action-cell");

      let source=cell.querySelector(":scope > .imprest-action-source");
      if(!source){
        source=document.createElement("div");
        source.className="imprest-action-source";
        cell.appendChild(source);
      }

      [...cell.querySelectorAll(":scope > .task-actions-wrap, :scope > .imprest-v2-actions")].forEach(wrap=>{
        [...wrap.querySelectorAll("button")].forEach(btn=>source.appendChild(btn));
        wrap.remove();
      });

      [...cell.querySelectorAll(":scope > button:not(.imprest-action-trigger)")].forEach(btn=>source.appendChild(btn));

      const seen=new Map();
      [...source.querySelectorAll('button[onclick]')].forEach(button=>{
        const key=button.getAttribute('onclick').trim(),previous=seen.get(key);
        if(!previous){seen.set(key,button);return;}
        if(previous.disabled&&!button.disabled){previous.remove();seen.set(key,button);}else button.remove();
      });

      const count=[...source.querySelectorAll("button")].filter(btn=>!btn.disabled&&!btn.classList.contains("hidden")).length;
      let trigger=cell.querySelector(":scope > .imprest-action-trigger");
      if(!count){
        trigger?.remove();
        if(!cell.textContent.trim())cell.textContent="—";
        return;
      }

      if(cell.childNodes.length&&[...cell.childNodes].some(n=>n.nodeType===Node.TEXT_NODE&&n.textContent.trim()==="—")){
        [...cell.childNodes].filter(n=>n.nodeType===Node.TEXT_NODE&&n.textContent.trim()==="—").forEach(n=>n.remove());
      }

      if(!trigger){
        trigger=document.createElement("button");
        trigger.type="button";
        trigger.className="imprest-action-trigger";
        trigger.innerHTML="<span aria-hidden='true'>⋮</span>";
        trigger.onclick=ev=>{
          ev.stopPropagation();
          if(imprestActionMenuEl&&trigger.getAttribute("aria-expanded")==="true")closeImprestActionMenuV3();
          else openImprestActionMenuV3(trigger);
        };
        cell.appendChild(trigger);
      }
      trigger.title=tx("الإجراءات","Actions");
      trigger.setAttribute("aria-label",tx("الإجراءات","Actions"));
      trigger.setAttribute("aria-haspopup","menu");
      trigger.setAttribute("aria-expanded","false");
    });
  }
  window.compactImprestActionsV3=compactImprestActions;

  function scheduleImprestActionCompact(){
    if(imprestActionCompactScheduled)return;
    imprestActionCompactScheduled=true;
    setTimeout(()=>{
      imprestActionCompactScheduled=false;
      compactImprestActions();
    },0);
  }

  function ensureImprestActionObserver(){
    const body=document.getElementById("imprestBody");
    if(!body||imprestActionObserver)return;
    imprestActionObserver=new MutationObserver(scheduleImprestActionCompact);
    imprestActionObserver.observe(body,{childList:true,subtree:true});
  }

  document.addEventListener("pointerdown",ev=>{
    if(!imprestActionMenuEl)return;
    if(imprestActionMenuEl.contains(ev.target)||ev.target.closest?.(".imprest-action-trigger"))return;
    closeImprestActionMenuV3();
  },true);
  document.addEventListener("keydown",ev=>{if(ev.key==="Escape")closeImprestActionMenuV3()});
  document.addEventListener("scroll",()=>closeImprestActionMenuV3(),true);
  window.addEventListener("resize",()=>closeImprestActionMenuV3(),{passive:true});

  function postRender(){
    ensureWorkspace();
    const registerPanel=document.getElementById("imprestWorkspacePanel_register");
    const registerWrap=document.getElementById("imprestTable")?.closest(".table-wrap");
    if(registerPanel&&registerWrap&&registerWrap.parentNode!==registerPanel)registerPanel.appendChild(registerWrap);

    const settlementPanel=document.getElementById("imprestWorkspacePanel_settlements");
    const settlementWrap=document.getElementById("imprestSettlementsTable")?.closest(".table-wrap");
    if(settlementPanel&&settlementWrap&&settlementWrap.parentNode!==settlementPanel){
      const prev=settlementWrap.previousElementSibling;
      if(prev?.classList?.contains("row"))settlementPanel.appendChild(prev);
      settlementPanel.appendChild(settlementWrap);
    }
    document.getElementById("imprestFundingV2Panel")?.classList.add("imprest-v2-source-hidden");
    ensureImprestActionObserver();
    scheduleImprestActionCompact();
    renderOverview();
    setTimeout(()=>void refreshWorkspaceData(false),0);
  }

  ensureWorkspace();

  if(typeof window.renderImprest==="function"){
    const original=window.renderImprest;
    window.renderImprest=function(...args){
      const out=original.apply(this,args);
      setTimeout(postRender,0);
      return out;
    };
  }

  if(typeof window.toggleLanguage==="function"){
    const originalToggle=window.toggleLanguage;
    window.toggleLanguage=function(...args){
      const out=originalToggle.apply(this,args);
      setTimeout(()=>{
        const header=document.querySelector("#imprest > .imprest-workspace-header .muted");
        if(header)header.textContent=tx("إدارة العهد والتمويل والتصفية والحركات والرقابة","Imprest management, funding, settlement, ledger and controls");
        const current=localStorage.getItem(STORAGE_KEY)||"register";
        document.querySelectorAll("[data-imprest-secondary]").forEach(b=>{const tab=tabs.find(x=>x[0]===b.dataset.imprestSecondary);if(tab)b.textContent=tx(tab[1],tab[2]);});
        const summary=document.querySelector(".imprest-secondary-tools summary");if(summary)summary.textContent=tx("ملخص وحركة ورقابة","Summary, ledger & controls");
        const nav=document.getElementById("imprestWorkspaceTabs");
        if(nav)nav.innerHTML=tabs.filter(x=>['register','funding','settlements'].includes(x[0])).map(([key,ar,en])=>`<button class="imprest-workspace-tab ${current===key?"active":""}" type="button" role="tab" aria-selected="${current===key?"true":"false"}" data-imprest-tab="${key}" onclick="switchImprestWorkspaceTab('${key}')">${tx(ar,en)}</button>`).join("");
        renderOverview();renderFunding();renderControls();
        if(document.getElementById("imprestWorkspacePanel_ledger")?.classList.contains("active"))renderLedger();
      },0);
      return out;
    };
  }

  setTimeout(postRender,0);
})();
