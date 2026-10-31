/* Domain presentation and source navigation. Existing RPCs, guards and workflows remain authoritative. */
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const text = (ar,en) => currentLang === 'en' ? en : ar;
  // Domain dictionaries are loaded after the original reverse dictionary.
  for(const [ar,en] of Object.entries(I18N_AR_EN))if(!I18N_EN_AR[en])I18N_EN_AR[en]=ar;
  const definitions = {
    banks:['موقف الخزينة','Treasury position','راجع السيولة والحجوزات والمستهدف قبل اتخاذ قرار التمويل.','Review liquidity, commitments and reserve targets before funding.'],
    reservev2:['رقابة الاحتياطيات','Reserve control','تابع الفروقات والمبالغ المطلوبة للاستعادة من سجل المصدر.','Follow differences and outstanding restorations in the source register.'],
    payments:['من الطلب إلى الاعتماد','From request to approval','راجع الطلب والمستندات والمسؤول عن الخطوة التالية في مكان واحد.','Review the request, evidence and next responsible person in one place.'],
    executed:['التنفيذ والتسجيل','Execution and registration','تابع التسجيل بعد التنفيذ البنكي ومهلته وحالة الترحيل.','Follow registration after bank execution, its deadline and posting status.'],
    pending:['معالجة العمليات المعلقة','Resolve held payments','ابدأ بسبب التعليق ومسؤول المتابعة قبل استكمال الإجراء.','Start with the hold reason and follow-up owner before continuing.'],
    posted:['سجل المدفوعات المرحلة','Posted payment register','راجع المراجع النهائية دون إعادة تنفيذ الإجراء المحاسبي.','Review final references without repeating the accounting action.'],
    close:['خطة الإقفال ومسؤولياتها','Close plan and responsibilities','ابدأ بالبند المستحق، ثم افتح مهمته المرتبطة للمراجعة والإنجاز.','Start with the due item, then open its linked task for review and completion.'],
    imprest:['العهد والتمويل والتصفية','Funds, funding and settlement','راجع الرصيد وملفات التصفية ومهام المراجعة المرتبطة.','Review balances, settlement files and their linked review tasks.'],
    performance:['الأداء المبني على العمل','Performance grounded in work','راجع الإنجاز والجودة وأسباب التأخير ثم افتح تقرير الموظف للفترة المطلوبة.','Review completion, quality and delay reasons, then open the employee period report.'],
    ownership:['وضوح المسؤولية','Clear responsibility','راجع المالك والمراجع والمعتمد لكل نشاط قبل إسناده.','Review the owner, reviewer and approver before assigning work.'],
    exceptions:['الاستثناءات والسياسات','Exceptions and policies','تابع الاستثناءات والإجازات وإقرارات السياسات من سجلاتها المعتمدة.','Follow exceptions, leave and policy acknowledgements in their governed registers.'],
    permissions:['الوصول حسب المسؤولية','Access by responsibility','راجع عضوية الفريق والصلاحيات دون مشاركة كلمات المرور.','Review team membership and permissions without sharing passwords.'],
    automation:['متابعة صحة التشغيل','Operational health','راجع الأخطاء والمهام الآلية والطلبات التي تنتظر المراجعة.','Review errors, scheduled work and requests awaiting review.'],
    audit:['أثر واضح لكل إجراء','A trace for every action','ابحث في السجل لمتابعة من نفّذ الإجراء ومتى وعلى أي سجل.','Search who performed an action, when, and on which record.']
  };
  const states = new Map();
  let identity = null, pending = false;
  const storageKey = key => 'sanam.views.v1.' + encodeURIComponent(profile?.id || '') + '.' + key;
  function saved(state) {
    try { const value=JSON.parse(localStorage.getItem(storageKey(state.key))||'[]');
      return Array.isArray(value)?value.filter(x=>typeof x?.name==='string'&&typeof x?.query==='string'&&x.name.length<=40&&x.query.length<=160).slice(0,8):[];
    } catch { return []; }
  }
  function writeSaved(state,rows) {
    try { localStorage.setItem(storageKey(state.key),JSON.stringify(rows)); return true; }
    catch { state.message.textContent=text('تعذر حفظ العرض على هذا الجهاز.','Could not save the view on this device.'); return false; }
  }
  function visibleBase(row) {return !row.hidden && !row.classList.contains('hidden') && row.style.display!=='none';}
  function filter(state) {
    const query=state.search.value.trim().toLocaleLowerCase();
    const rows=[...state.table.tBodies].flatMap(body=>[...body.rows]).filter(row=>row.cells.length>1&&![...row.cells].some(c=>c.colSpan>1));
    let base=0,shown=0;
    for(const row of rows) {
      const available=visibleBase(row); if(available)base++;
      // Ignore action labels and hidden columns when searching displayed business data.
      const content=[...row.cells].filter(cell=>!cell.hidden&&getComputedStyle(cell).display!=='none').map(cell=>{
        const copy=cell.cloneNode(true);copy.querySelectorAll('button,input,select').forEach(el=>el.remove());return copy.textContent;
      }).join(' ').toLocaleLowerCase();
      const matches=!query||content.includes(query);
      row.classList.toggle('experience-filtered-row',!matches);
      if(available&&matches)shown++;
    }
    state.count.textContent=`${shown} / ${base} · ${text('من السجلات المحمّلة','loaded records')}`;
    state.empty.hidden=!query||shown>0||base===0;
    state.reset.disabled=!state.search.value;
    state.save.disabled=!query;
  }
  function renderSaved(state) {
    const rows=saved(state);state.views.replaceChildren();
    for(const view of rows) {
      const group=document.createElement('span');group.className='experience-view';
      const use=document.createElement('button');use.type='button';use.textContent=view.name;use.className='experience-view-open';
      use.setAttribute('aria-pressed',String(state.search.value===view.query));
      use.onclick=()=>{state.search.value=view.query;filter(state);renderSaved(state);};
      const remove=document.createElement('button');remove.type='button';remove.textContent='×';
      remove.setAttribute('aria-label',text('حذف عرض البحث: ','Delete search view: ')+view.name);
      remove.onclick=()=>{if(writeSaved(state,saved(state).filter(x=>x.name!==view.name)))renderSaved(state);};
      group.append(use,remove);state.views.append(group);
    }
  }
  function installTable(table,page,index) {
    if(table.closest('#opsBCRecords')||table.closest('.experience-panel'))return;
    let state=states.get(table);
    if(!state) {
      const wrap=table.closest('.table-wrap');if(!wrap||!table.tBodies.length)return;
      const key=page.id+'.'+(table.id||'table-'+index);
      const panel=document.createElement('div');panel.className='experience-table-tools';panel.dataset.tableView=key;
      const label=document.createElement('label'),search=document.createElement('input');search.type='search';search.maxLength=160;
      label.append(search);
      const reset=document.createElement('button');reset.type='button';reset.className='btn';
      const name=document.createElement('input');name.maxLength=40;
      const save=document.createElement('button');save.type='button';save.className='btn';
      const count=document.createElement('span');count.className='experience-count';count.setAttribute('role','status');
      const message=document.createElement('span');message.className='experience-view-message';message.setAttribute('role','status');
      const views=document.createElement('div');views.className='experience-views';
      const empty=document.createElement('div');empty.className='experience-search-empty';empty.hidden=true;
      const hint=document.createElement('small');hint.className='experience-search-hint';
      panel.append(label,reset,name,save,count,views,hint,message,empty);wrap.before(panel);
      state={key,table,panel,search,label,reset,name,save,count,views,message,empty,hint,page:page.id};states.set(table,state);
      search.addEventListener('input',()=>{filter(state);renderSaved(state);});
      reset.onclick=()=>{search.value='';filter(state);renderSaved(state);search.focus();};
      save.onclick=()=>{
        const title=name.value.trim(),query=search.value.trim();if(!title||!query){message.textContent=text('أدخل اسمًا للعرض وكلمة البحث.','Enter a view name and a search term.');return;}
        const existing=saved(state),rows=existing.filter(x=>x.name!==title);
        if(rows.length>=8){message.textContent=text('يمكن حفظ ثمانية عروض لكل جدول. احذف عرضًا أولًا.','Save up to eight views per table. Delete one first.');return;}
        rows.push({name:title,query});if(writeSaved(state,rows)){message.textContent=text('حُفظ عرض البحث لهذا المستخدم على هذا الجهاز.','Search view saved for this user on this device.');name.value='';renderSaved(state);}
      };
      const observer=new MutationObserver(()=>schedule());
      for(const body of table.tBodies)observer.observe(body,{childList:true,subtree:true,attributes:true,attributeFilter:['style','hidden']});
      state.observer=observer;
    }
    state.panel.hidden=!profile||!canPage(page.id);
    state.search.placeholder=text('ابحث داخل هذا الجدول…','Search this table…');state.search.setAttribute('aria-label',text('البحث داخل الجدول','Search this table'));
    state.name.placeholder=text('اسم العرض','View name');state.name.setAttribute('aria-label',text('اسم عرض البحث','Search view name'));
    state.reset.textContent=text('مسح البحث','Clear search');state.save.textContent=text('حفظ البحث','Save search');
    state.hint.textContent=text('يبحث في السجلات المحمّلة فقط. إجماليات الصفحة وتقاريرها تتبع فلاترها الأصلية.','Search covers loaded records only. Page totals and reports follow their original filters.');
    state.empty.textContent=text('لا توجد نتائج لهذا البحث. جرّب كلمة أخرى أو امسح البحث.','No matches. Try another term or clear the search.');
    filter(state);renderSaved(state);
  }
  function summaries(id) {
    if(id==='banks')return [[banks.length,'حسابات محمّلة','Loaded accounts'],[banks.filter(b=>/reserve/i.test(b.account_type||'')).length,'حسابات احتياطية','Reserve accounts']];
    if(id==='payments')return [[payments.length,'طلبات محمّلة','Loaded requests'],[payments.filter(p=>p.supervisor_status==='معلق'&&!p.executed_at&&!p.posted_at).length,'بانتظار المشرف','Awaiting supervisor'],[payments.filter(p=>p.supervisor_status==='موافق'&&p.cfo_status==='معلق'&&!p.executed_at&&!p.posted_at).length,'بانتظار المدير المالي','Awaiting CFO']];
    if(id==='close') {
      const period=closeTasks.map(x=>x.close_period).filter(Boolean).sort().at(-1),rows=closeTasks.filter(x=>!period||x.close_period===period);
      return [[rows.length,'بنود الدورة الحالية','Current cycle items'],[rows.filter(x=>x.status==='مكتمل'||Number(x.progress)>=100).length,'بنود مكتملة','Completed items'],[rows.filter(x=>x.release_status==='Planned'&&!x.task_id).length,'تنتظر إطلاق الخطة','Awaiting plan release']];
    }
    if(id==='imprest')return [[imprest.length,'عهد محمّلة','Loaded funds'],[imprestSettlements.length,'ملفات تصفية محمّلة','Loaded settlement files']];
    if(id==='performance')return [[performance.length,'سجلات أداء محمّلة','Loaded performance records']];
    if(id==='ownership')return [[ownership.length,'مسؤوليات محمّلة','Loaded responsibilities']];
    return [];
  }
  function renderIntro(page) {
    const def=definitions[page.id];if(!def)return;
    let panel=page.querySelector(':scope > .experience-intro');
    if(!panel){panel=document.createElement('div');panel.className='experience-intro';page.prepend(panel);}
    panel.hidden=!profile||!canPage(page.id);panel.replaceChildren();
    const copy=document.createElement('div'),eyebrow=document.createElement('span'),description=document.createElement('p');
    eyebrow.className='experience-eyebrow';eyebrow.textContent=text(def[0],def[1]);description.textContent=text(def[2],def[3]);copy.append(eyebrow,description);panel.append(copy);
    const metrics=document.createElement('div');metrics.className='experience-metrics';
    for(const [count,ar,en] of summaries(page.id)){const metric=document.createElement('div'),value=document.createElement('b'),label=document.createElement('span');value.textContent=String(count);label.textContent=text(ar,en);metric.append(value,label);metrics.append(metric);}
    if(metrics.children.length)panel.append(metrics);
  }
  function render() {
    pending=false;
    if(identity!==profile?.id){identity=profile?.id;for(const state of states.values()){state.search.value='';state.name.value='';state.message.textContent='';}}
    for(const [table,state] of states){if(!table.isConnected){state.observer.disconnect();state.panel.remove();states.delete(table);}}
    for(const page of document.querySelectorAll('.section')) {
      if(!profile||!canPage(page.id)){page.querySelectorAll('.experience-intro,.experience-table-tools').forEach(x=>x.hidden=true);continue;}
      renderIntro(page);
      if(definitions[page.id]&&page.classList.contains('active'))page.querySelectorAll('.table-wrap > table').forEach((table,index)=>installTable(table,page,index));
    }
  }
  function schedule(){if(pending)return;pending=true;requestAnimationFrame(render);}
  for(const name of ['openPage','applyAccess','applyLanguage','renderBanks','renderPayments','renderClose','renderImprest','renderPerformance','renderOwnership','renderExecutedPayments','renderPendingPayments','renderPosted','reloadAll','showAuth']) {
    const previous=window[name];if(typeof previous!=='function')continue;
    window[name]=function(...args){const result=previous.apply(this,args);schedule();if(result&&typeof result.then==='function')result.then(schedule,schedule);return result;};
  }
  document.documentElement.classList.add('workspace-experience-ready');
  document.addEventListener('DOMContentLoaded',schedule);
  schedule();
})();
