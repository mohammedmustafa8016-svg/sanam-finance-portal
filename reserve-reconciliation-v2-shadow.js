(() => {
  if(typeof I18N_AR_EN!=="undefined") I18N_AR_EN["مطابقة الاحتياطي V2"]="Reserve Reconciliation V2";
  const state = {
    loaded:false,
    loading:false,
    tab:"overview",
    bankAccountId:"",
    from:"",
    to:"",
    summary:[],
    comparison:[],
    movements:[],
    draws:[],
    exceptions:[],
    monitorLatest:[],
    monitorHistory:[]
  };

  const allowed = () => ["CFO","Supervisor"].includes(typeof profile!=="undefined" ? profile?.role : undefined);
  const section = () => document.getElementById("reservev2");
  const tx = (ar,en) => (typeof currentLang!=="undefined" && currentLang === "en") ? en : ar;
  const n = v => Number(v || 0);
  const m = v => typeof window.moneyHtml === "function" ? window.moneyHtml(v) : new Intl.NumberFormat("en-SA",{style:"currency",currency:"SAR"}).format(n(v));
  const e = v => typeof window.esc === "function" ? window.esc(v) : String(v ?? "");
  const date = v => v ? (typeof window.fmt === "function" ? window.fmt(v) : String(v)) : "—";

  function statusBadge(v){
    const s=String(v||"—");
    const good=["RECONCILED","RECONCILED_WITH_TOLERANCE","MATCH","BASELINE_MATCH_WITH_HISTORICAL_VARIANCE","Approved","Active"];
    const bad=["CONTROL_EXCEPTION","REVIEW_REQUIRED"];
    const cls=good.includes(s)?"green":bad.includes(s)?"red":"amber";
    return `<span class="badge ${cls}">${e(s)}</span>`;
  }

  function shell(){
    const root=section();
    if(!root || !allowed()) return;
    if(root.dataset.shadowReady==="1") return;
    root.dataset.shadowReady="1";
    root.innerHTML=`
      <div class="reserve-v2-shell">
        <div class="reserve-v2-header">
          <div>
            <h3 class="reserve-v2-title">${tx("مطابقة الاحتياطي V2 — وضع الظل","Reserve Reconciliation V2 — Shadow Mode")}</h3>
            <div class="muted">${tx("طبقة قراءة ومقارنة مستقلة. النسخة التشغيلية الحالية V1 لا تزال المصدر التشغيلي ولم يتم استبدالها.","Independent read-and-compare layer. The current V1 remains the operational source and has not been replaced.")}</div>
          </div>
          <div class="reserve-v2-badges">
            <span class="badge green">READ ONLY</span>
            <span class="badge amber">SHADOW MODE</span>
            <span class="badge green">AUTO MONITORING · 15 MIN</span>
            <button class="btn" type="button" onclick="loadReserveReconciliationV2Shadow(true)">${tx("تحديث","Refresh")}</button>
          </div>
        </div>

        <div class="note">
          <b>${tx("ضابط الحماية:","Protection guard:")}</b>
          ${tx("هذه الشاشة لا تسجل أو تعدل أو تعتمد أي حركة. جميع البيانات من RPCs القراءة فقط الخاصة بـ V2، ولا تغيّر الحسابات المحمية الحالية أو المدفوعات أو منطق V1.","This screen cannot record, edit, approve, or post any movement. All data comes from V2 read-only RPCs and does not change current protected accounts, payments, or V1 logic.")}
        </div>

        <div id="reserveV2Error" class="reserve-v2-error hidden"></div>
        <div id="reserveV2MonitorStrip" class="reserve-v2-monitor-strip"></div>
        <div id="reserveV2Kpis" class="reserve-v2-kpis"></div>

        <div class="card">
          <div class="reserve-v2-filterbar">
            <div>
              <label>${tx("الحساب المحمي","Protected account")}</label>
              <select id="reserveV2AccountFilter" onchange="reserveV2FilterChanged()"><option value="">${tx("كل الحسابات","All accounts")}</option></select>
            </div>
            <div>
              <label>${tx("الحركات من","Movements from")}</label>
              <input id="reserveV2From" type="date" onchange="reserveV2FilterChanged()">
            </div>
            <div>
              <label>${tx("الحركات إلى","Movements to")}</label>
              <input id="reserveV2To" type="date" onchange="reserveV2FilterChanged()">
            </div>
            <button class="btn" type="button" onclick="clearReserveV2Filters()">${tx("مسح الفلاتر","Clear filters")}</button>
          </div>
        </div>

        <div class="reserve-v2-tabs" role="tablist">
          <button class="btn active" data-reserve-v2-tab="overview" onclick="setReserveV2Tab('overview')">${tx("الملخص","Overview")}</button>
          <button class="btn" data-reserve-v2-tab="comparison" onclick="setReserveV2Tab('comparison')">${tx("مقارنة V1 ↔ V2","V1 ↔ V2 Comparison")}</button>
          <button class="btn" data-reserve-v2-tab="movements" onclick="setReserveV2Tab('movements')">${tx("الحركات","Movements")}</button>
          <button class="btn" data-reserve-v2-tab="draws" onclick="setReserveV2Tab('draws')">${tx("المبالغ المطلوب استعادتها","Open Recovery")}</button>
          <button class="btn" data-reserve-v2-tab="exceptions" onclick="setReserveV2Tab('exceptions')">${tx("الاستثناءات","Exceptions")}</button>
          <button class="btn" data-reserve-v2-tab="monitoring" onclick="setReserveV2Tab('monitoring')">${tx("المراقبة التلقائية","Automatic Monitoring")}</button>
        </div>

        <div id="reserveV2Panel"></div>
      </div>`;
  }

  function accountLabel(x){
    return `${e(x.account_type||"—")} — ${e(x.bank_name||"—")} — ${e(x.account_name||"—")}`;
  }

  function filteredSummary(){
    return state.bankAccountId ? state.summary.filter(x=>x.bank_account_id===state.bankAccountId) : state.summary;
  }

  function renderKpis(){
    const rows=filteredSummary();
    const totals=rows.reduce((a,x)=>{
      a.target+=n(x.effective_target);a.balance+=n(x.current_bank_balance);a.recovery+=n(x.outstanding_recovery);
      a.gap+=n(x.target_gap);a.exceptions+=n(x.open_exception_count)+n(x.integrity_issue_count);return a;
    },{target:0,balance:0,recovery:0,gap:0,exceptions:0});
    const box=document.getElementById("reserveV2Kpis"); if(!box)return;
    const items=[
      [tx("الحسابات المحمية","Protected accounts"),rows.length],
      [tx("الهدف الفعلي","Effective target"),m(totals.target)],
      [tx("الرصيد البنكي","Bank balance"),m(totals.balance)],
      [tx("مطلوب الاستعادة","Outstanding recovery"),m(totals.recovery)],
      [tx("الفجوة عن الهدف","Target gap"),m(totals.gap)],
      [tx("الاستثناءات المفتوحة","Open exceptions"),totals.exceptions]
    ];
    box.innerHTML=items.map(([k,v])=>`<div class="reserve-v2-kpi"><span>${k}</span><b>${v}</b></div>`).join("");
  }

  function filteredMonitorLatest(){
    return state.bankAccountId ? state.monitorLatest.filter(x=>x.bank_account_id===state.bankAccountId) : state.monitorLatest;
  }

  function renderMonitorStrip(){
    const box=document.getElementById("reserveV2MonitorStrip");if(!box)return;
    const rows=filteredMonitorLatest();
    const last=rows.reduce((mx,x)=>!mx||new Date(x.observed_at)>new Date(mx)?x.observed_at:mx,null);
    const variances=rows.filter(x=>x.observation_status==="VARIANCE").length;
    const controls=rows.filter(x=>x.observation_status==="CONTROL_EXCEPTION").length;
    const ok=rows.length>0&&variances===0&&controls===0;
    box.innerHTML=`
      <div><span>${tx("حالة المراقبة","Monitoring status")}</span><b>${statusBadge(rows.length?(ok?"ACTIVE / NO CURRENT VARIANCE":"ACTIVE / REVIEW REQUIRED"):"WAITING FOR FIRST RUN")}</b></div>
      <div><span>${tx("آخر فحص تلقائي","Last automatic check")}</span><b>${last?date(last):"—"}</b></div>
      <div><span>${tx("الحسابات المراقبة","Accounts monitored")}</span><b>${rows.length}</b></div>
      <div><span>${tx("فروقات حالية","Current variances")}</span><b class="${variances?'reserve-v2-nonzero':'reserve-v2-zero'}">${variances}</b></div>
      <div><span>${tx("استثناءات رقابية","Control exceptions")}</span><b class="${controls?'reserve-v2-nonzero':'reserve-v2-zero'}">${controls}</b></div>
      <div><span>${tx("دورية الفحص","Observation cadence")}</span><b>15 min</b></div>`;
  }

  function renderOverview(){
    const rows=filteredSummary();
    if(!rows.length)return `<div class="note">${tx("لا توجد بيانات V2 لهذا الاختيار.","No V2 data for this selection.")}</div>`;
    return `<div class="reserve-v2-account-grid">${rows.map(x=>`
      <article class="reserve-v2-account-card">
        <div class="row">
          <div><h4>${e(x.account_type||"—")}</h4><div class="muted">${e(x.company||"—")} · ${e(x.bank_name||"—")} · ${e(x.account_name||"—")}</div></div>
          ${statusBadge(x.reconciliation_status)}
        </div>
        <div class="reserve-v2-metrics">
          <div class="reserve-v2-metric"><span>${tx("الهدف الفعلي","Effective Target")}</span><b>${m(x.effective_target)}</b></div>
          <div class="reserve-v2-metric"><span>${tx("الرصيد الحالي","Current Balance")}</span><b>${m(x.current_bank_balance)}</b></div>
          <div class="reserve-v2-metric"><span>${tx("المتاح التشغيلي","Operational Available")}</span><b>${m(x.operational_available)}</b></div>
          <div class="reserve-v2-metric"><span>${tx("مطلوب الاستعادة","Outstanding Recovery")}</span><b>${m(x.outstanding_recovery)}</b></div>
          <div class="reserve-v2-metric"><span>${tx("الفجوة عن الهدف","Target Gap")}</span><b>${m(x.target_gap)}</b></div>
          <div class="reserve-v2-metric"><span>${tx("فرق المصالحة","Unreconciled Difference")}</span><b class="${Math.abs(n(x.unreconciled_difference))<=.01?'reserve-v2-zero':'reserve-v2-nonzero'}">${m(x.unreconciled_difference)}</b></div>
        </div>
      </article>`).join("")}</div>`;
  }

  function renderComparison(){
    const rows=state.bankAccountId?state.comparison.filter(x=>x.bank_account_id===state.bankAccountId):state.comparison;
    return `<div class="table-wrap"><table id="reserveV2ComparisonTable"><thead><tr>
      <th>${tx("الحساب","Account")}</th><th>V1 Target</th><th>V2 Target</th><th>Δ Target</th>
      <th>V1 Balance</th><th>V2 Balance</th><th>Δ Balance</th>
      <th>V1 Recovery</th><th>V2 Recovery</th><th>Δ Recovery</th>
      <th>V1 Gap</th><th>V2 Gap</th><th>Δ Gap</th>
      <th>${tx("الفرق التاريخي","Historical Variance")}</th><th>${tx("الحالة","Status")}</th>
      </tr></thead><tbody>${rows.map(x=>`<tr>
      <td>${accountLabel(x)}</td><td>${m(x.v1_reference_balance)}</td><td>${m(x.v2_effective_target)}</td><td>${m(x.target_delta_v2_minus_v1)}</td>
      <td>${m(x.v1_current_bank_balance)}</td><td>${m(x.v2_current_bank_balance)}</td><td>${m(x.bank_balance_delta_v2_minus_v1)}</td>
      <td>${m(x.v1_outstanding_restoration)}</td><td>${m(x.v2_outstanding_recovery)}</td><td>${m(x.outstanding_recovery_delta_v2_minus_v1)}</td>
      <td>${m(x.v1_target_gap)}</td><td>${m(x.v2_target_gap)}</td><td>${m(x.target_gap_delta_v2_minus_v1)}</td>
      <td>${m(x.opening_historical_variance)}</td><td>${statusBadge(x.shadow_comparison_status)}</td>
      </tr>`).join("")||`<tr><td colspan="15">—</td></tr>`}</tbody></table></div>
      <div class="reserve-v2-table-note">${tx("الفروق التاريخية معروضة كمرجع مستقل ولا تُستخدم لتعديل V1 أو إعادة كتابة التاريخ.","Historical variances are shown independently and do not modify V1 or rewrite history.")}</div>`;
  }

  function nameForRecon(id){
    const s=state.summary.find(x=>x.reconciliation_account_id===id);
    return s?accountLabel(s):e(id||"—");
  }

  function renderMovements(){
    return `<div class="table-wrap"><table id="reserveV2MovementTable"><thead><tr>
      <th>${tx("التاريخ","Date")}</th><th>${tx("الحساب","Account")}</th><th>${tx("النوع","Type")}</th><th>${tx("الاتجاه","Direction")}</th>
      <th>${tx("المبلغ","Amount")}</th><th>${tx("المصدر","Source")}</th><th>${tx("الحالة","Status")}</th><th>${tx("المتبقي","Outstanding")}</th>
      </tr></thead><tbody>${state.movements.map(x=>`<tr>
      <td>${date(x.movement_time||x.movement_date)}</td><td>${nameForRecon(x.reconciliation_account_id)}</td><td>${e(x.movement_type)}</td><td>${e(x.direction)}</td>
      <td data-amount="${n(x.amount)}">${m(x.amount)}</td><td>${e(x.source_type||"—")}</td><td>${statusBadge(x.status)}</td><td>${x.outstanding_draw_amount==null?"—":m(x.outstanding_draw_amount)}</td>
      </tr>`).join("")||`<tr><td colspan="8">—</td></tr>`}</tbody></table></div>`;
  }

  function renderDraws(){
    return `<div class="table-wrap"><table id="reserveV2DrawsTable"><thead><tr>
      <th>${tx("التاريخ","Date")}</th><th>${tx("الحساب","Account")}</th><th>${tx("السحب","Draw")}</th><th>${tx("المستعاد","Restored")}</th>
      <th>${tx("المتبقي","Outstanding")}</th><th>${tx("حالة الاسترداد","Recovery Status")}</th><th>${tx("المصدر","Source")}</th>
      </tr></thead><tbody>${state.draws.map(x=>`<tr>
      <td>${date(x.movement_time||x.movement_date)}</td><td>${nameForRecon(x.reconciliation_account_id)}</td><td>${m(x.draw_amount)}</td><td>${m(x.restored_amount)}</td>
      <td>${m(x.outstanding_amount)}</td><td>${statusBadge(x.restoration_status)}</td><td>${e(x.source_type||"—")}</td>
      </tr>`).join("")||`<tr><td colspan="7">—</td></tr>`}</tbody></table></div>`;
  }

  function renderMonitoring(){
    const latest=filteredMonitorLatest();
    const history=state.bankAccountId?state.monitorHistory.filter(x=>x.bank_account_id===state.bankAccountId):state.monitorHistory;
    const latestTable=`<div class="card"><div class="row"><div><h4 style="margin:0">${tx("الحالة الحالية للمراقبة","Current monitoring state")}</h4><div class="muted">${tx("الفروق التاريخية الافتتاحية محفوظة كمرجع ولا تُصنف وحدها كاستثناء نشط.","Opening historical variance is preserved as reference and does not by itself create an active exception.")}</div></div><span class="badge green">15 MIN</span></div><div class="table-wrap" style="margin-top:10px"><table id="reserveV2MonitorLatestTable"><thead><tr>
      <th>${tx("آخر فحص","Last Check")}</th><th>${tx("الحساب","Account")}</th><th>${tx("الحالة","Status")}</th><th>Δ Target</th><th>Δ Balance</th><th>Δ Reserved</th><th>Δ Recovery</th><th>Δ Gap</th><th>${tx("فرق المصالحة","Unreconciled")}</th><th>${tx("رمز الاستثناء","Exception Code")}</th>
      </tr></thead><tbody>${latest.map(x=>`<tr><td>${date(x.observed_at)}</td><td>${accountLabel(x)}</td><td>${statusBadge(x.observation_status)}</td><td>${m(x.target_delta)}</td><td>${m(x.bank_balance_delta)}</td><td>${m(x.reserved_payments_delta)}</td><td>${m(x.outstanding_recovery_delta)}</td><td>${m(x.target_gap_delta)}</td><td>${m(x.v2_unreconciled_difference)}</td><td>${e(x.exception_code||"—")}</td></tr>`).join("")||`<tr><td colspan="10">—</td></tr>`}</tbody></table></div></div>`;
    const historyTable=`<div class="card"><h4 style="margin-top:0">${tx("سجل المراقبة الأخير","Recent observation history")}</h4><div class="table-wrap"><table id="reserveV2MonitorHistoryTable"><thead><tr><th>${tx("وقت الفحص","Observed At")}</th><th>${tx("الحساب","Account")}</th><th>${tx("الحالة","Status")}</th><th>Δ Target</th><th>Δ Balance</th><th>Δ Recovery</th><th>Δ Gap</th><th>${tx("التفاصيل","Details")}</th></tr></thead><tbody>${history.map(x=>`<tr><td>${date(x.observed_at)}</td><td>${accountLabel(x)}</td><td>${statusBadge(x.observation_status)}</td><td>${m(x.target_delta)}</td><td>${m(x.bank_balance_delta)}</td><td>${m(x.outstanding_recovery_delta)}</td><td>${m(x.target_gap_delta)}</td><td>${e(x.exception_detail||tx("لا توجد فروقات تشغيلية.","No operational variance."))}</td></tr>`).join("")||`<tr><td colspan="8">—</td></tr>`}</tbody></table></div></div>`;
    return `<div class="reserve-v2-monitoring-grid">${latestTable}${historyTable}</div>`;
  }

  function renderExceptions(){
    return `<div class="table-wrap"><table id="reserveV2ExceptionsTable"><thead><tr>
      <th>${tx("وقت الاكتشاف","Detected")}</th><th>${tx("الحساب","Account")}</th><th>${tx("نوع الاستثناء","Exception Type")}</th><th>${tx("المبلغ","Amount")}</th>
      <th>${tx("الحالة","Status")}</th><th>${tx("التصنيف المقترح","Suggested Classification")}</th><th>${tx("ملاحظة الحل","Resolution Note")}</th>
      </tr></thead><tbody>${state.exceptions.map(x=>`<tr>
      <td>${date(x.detected_at)}</td><td>${nameForRecon(x.reconciliation_account_id)}</td><td>${e(x.exception_type)}</td><td>${m(x.amount)}</td>
      <td>${statusBadge(x.status)}</td><td>${e(x.suggested_classification||"—")}</td><td>${e(x.resolution_note||"—")}</td>
      </tr>`).join("")||`<tr><td colspan="7">${tx("لا توجد استثناءات V2 مفتوحة.","No V2 exceptions are currently recorded.")}</td></tr>`}</tbody></table></div>`;
  }

  function render(){
    shell();
    if(!allowed())return;
    renderMonitorStrip();
    renderKpis();
    document.querySelectorAll("[data-reserve-v2-tab]").forEach(b=>b.classList.toggle("active",b.dataset.reserveV2Tab===state.tab));
    const panel=document.getElementById("reserveV2Panel"); if(!panel)return;
    panel.innerHTML=state.tab==="comparison"?renderComparison():state.tab==="movements"?renderMovements():state.tab==="draws"?renderDraws():state.tab==="exceptions"?renderExceptions():state.tab==="monitoring"?renderMonitoring():renderOverview();
    try{window.installTableFilters?.();window.installUniversalColumnCustomizers?.();}catch(err){console.error("Reserve V2 table utilities failed",err)}
  }

  async function load(force=false){
    if(!allowed() || state.loading)return;
    shell();
    state.loading=true;
    section()?.classList.add("reserve-v2-loading");
    const errorBox=document.getElementById("reserveV2Error"); if(errorBox)errorBox.classList.add("hidden");
    try{
      const bank=state.bankAccountId||null, from=state.from||null, to=state.to||null;
      const [summary,comparison,movements,draws,exceptions,monitorLatest,monitorHistory]=await Promise.all([
        sb.rpc("get_reserve_reconciliation_summary_v2"),
        sb.rpc("compare_reserve_v1_v2",{p_bank_account_id:bank}),
        sb.rpc("get_reserve_movement_ledger_v2",{p_bank_account_id:bank,p_from:from,p_to:to}),
        sb.rpc("get_reserve_open_draws_v2",{p_bank_account_id:bank}),
        sb.rpc("get_reserve_reconciliation_exceptions_v2",{p_bank_account_id:bank}),
        sb.rpc("get_reserve_shadow_monitor_status_v2"),
        sb.rpc("get_reserve_shadow_observation_history_v2",{p_bank_account_id:bank,p_limit:100})
      ]);
      const failed=[summary,comparison,movements,draws,exceptions,monitorLatest,monitorHistory].find(x=>x.error);
      if(failed)throw failed.error;
      state.summary=summary.data||[];
      state.comparison=comparison.data||[];
      state.movements=movements.data||[];
      state.draws=draws.data||[];
      state.exceptions=exceptions.data||[];
      state.monitorLatest=monitorLatest.data||[];
      state.monitorHistory=monitorHistory.data||[];
      state.loaded=true;

      const select=document.getElementById("reserveV2AccountFilter");
      if(select){
        const current=state.bankAccountId;
        select.innerHTML=`<option value="">${tx("كل الحسابات","All accounts")}</option>`+state.summary.map(x=>`<option value="${e(x.bank_account_id)}">${accountLabel(x)}</option>`).join("");
        select.value=current;
      }
      const fromEl=document.getElementById("reserveV2From"),toEl=document.getElementById("reserveV2To");
      if(fromEl)fromEl.value=state.from;if(toEl)toEl.value=state.to;
      render();
    }catch(err){
      console.error("Reserve Reconciliation V2 Shadow UI load failed",err);
      if(errorBox){errorBox.textContent=tx("تعذر تحميل بيانات المطابقة V2: ","Unable to load V2 reconciliation data: ")+(err.message||String(err));errorBox.classList.remove("hidden")}
    }finally{
      state.loading=false;section()?.classList.remove("reserve-v2-loading");
    }
  }

  window.loadReserveReconciliationV2Shadow=load;
  window.setReserveV2Tab=function(tab){state.tab=tab;render()};
  window.reserveV2FilterChanged=function(){
    state.bankAccountId=document.getElementById("reserveV2AccountFilter")?.value||"";
    state.from=document.getElementById("reserveV2From")?.value||"";
    state.to=document.getElementById("reserveV2To")?.value||"";
    load(true);
  };
  window.clearReserveV2Filters=function(){
    state.bankAccountId="";state.from="";state.to="";load(true);
  };
  window.renderReserveReconciliationV2Shadow=render;

  setInterval(()=>{
    if(allowed()&&section()?.classList.contains("active"))load(true);
  },300000);

  const originalToggle=window.toggleLanguage;
  if(typeof originalToggle==="function"){
    window.toggleLanguage=function(){
      originalToggle();
      if(section()?.classList.contains("active")){
        section().dataset.shadowReady="";
        shell();
        render();
      }
    };
  }
})();
