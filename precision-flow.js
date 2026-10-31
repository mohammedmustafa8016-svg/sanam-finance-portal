/* Presentation only: existing action builders and server guards remain authoritative. */
(() => {
  'use strict';
  const labels = (ar,en) => currentLang==='en'?en:ar;
  const pages = ['payments','executed','pending','posted'];
  let selected = null, identity = null;
  const destinations=[['dashboard','الرئيسية','Home'],['workcenter','مركز العمل','Work Center'],['tasks','المهام','Tasks'],['payments','المدفوعات والاعتمادات','Payments & approvals'],['executed','الاعتمادات المنفذة','Executed payments'],['pending','الاعتمادات المعلقة','Pending payments'],['posted','المرحلة محاسبيًا','Posted payments'],['banks','السيولة والبنوك','Liquidity & banks'],['imprest','العهد','Imprest'],['close','الإقفال الشهري','Monthly close'],['performance','الأداء والتقارير','Performance & reports'],['audit','سجل التدقيق','Audit log']];
  function commandPalette(){
    if(!profile)return;
    showModal(labels('الانتقال السريع','Quick navigation'),'<label id="pfSearchLabel" for="pfSearchInput"></label><input id="pfSearchInput" autocomplete="off"><div id="pfSearchResults" class="pf-search-results"></div>');
    document.getElementById('pfSearchLabel').textContent=labels('ابحث باسم الصفحة','Search by page name');
    const input=document.getElementById('pfSearchInput'),results=document.getElementById('pfSearchResults');
    function search(){results.replaceChildren();for(const [id,ar,en] of destinations){if(!canPage(id)||!document.getElementById(id)||!`${ar} ${en}`.toLocaleLowerCase().includes(input.value.trim().toLocaleLowerCase()))continue;const button=document.createElement('button');button.type='button';button.className='btn';button.textContent=labels(ar,en);button.onclick=()=>{if(!canPage(id))return;closeModal();openPage(id,labels(ar,en));};results.append(button);}if(!results.children.length)results.textContent=labels('لا توجد صفحات متاحة تطابق البحث.','No available pages match your search.');}
    input.addEventListener('input',search);search();input.focus();
  }
  function resetSelection(){selected=null;document.querySelectorAll('.pf-selected').forEach(x=>x.classList.remove('pf-selected'));}
  function decorate(){
    if(identity!==profile?.id){identity=profile?.id;resetSelection();}
    const top=document.querySelector('.top');
    if(top&&!top.querySelector('#pfCommand')){const button=document.createElement('button');button.id='pfCommand';button.type='button';button.className='btn pf-command';button.onclick=commandPalette;top.insertBefore(button,top.querySelector('.lang-actions'));}
    const command=document.getElementById('pfCommand');if(command){command.textContent=labels('انتقال سريع  ·  Ctrl K','Quick navigation  ·  Ctrl K');command.hidden=!profile;}
    for(const id of pages){
      const section=document.getElementById(id);if(!section)continue;
      let panel=section.querySelector('.pf-decision');
      if(!panel){panel=document.createElement('aside');panel.className='pf-decision';panel.setAttribute('aria-label',labels('مساحة القرار','Decision space'));section.append(panel);}
      const active=section.classList.contains('active')&&canPage(id);
      panel.hidden=!active;
      if(!active)continue;
      const payment=selected&&payments.find(p=>p.id===selected);
      panel.replaceChildren();
      const heading=document.createElement('h3');heading.textContent=labels('مساحة القرار','Decision space');panel.append(heading);
      if(!payment){const hint=document.createElement('p');hint.className='muted';hint.textContent=labels('اختر معاملة من الجدول لمراجعة تفاصيلها والإجراءات المتاحة لك.','Select a transaction to review its details and your available actions.');panel.append(hint);}
      else {
        const close=document.createElement('button');close.type='button';close.className='btn pf-clear';close.textContent=labels('إلغاء التحديد','Clear selection');close.onclick=()=>{resetSelection();decorate();};panel.append(close);
        const title=document.createElement('h4');title.textContent=payment.beneficiary||'—';panel.append(title);
        const amount=document.createElement('div');amount.className='pf-amount';amount.innerHTML=moneyHtml(payment.amount);panel.append(amount);
        const details=document.createElement('dl');
        for(const [name,value] of [[labels('الشركة','Company'),payment.company],[labels('الحالة','Status'),payment.status],[labels('الغرض','Purpose'),payment.purpose]]){const dt=document.createElement('dt'),dd=document.createElement('dd');dt.textContent=name;dd.textContent=value||'—';details.append(dt,dd);}panel.append(details);
        const timeline=document.createElement('ol');timeline.className='pf-timeline';
        for(const [name,date] of [[labels('الإنشاء','Created'),payment.created_at],[labels('التنفيذ البنكي','Bank execution'),payment.executed_at],[labels('التسجيل المحاسبي','Accounting registration'),payment.accounting_registered_at],[labels('الترحيل','Posting'),payment.posted_at]]){if(!date)continue;const item=document.createElement('li');item.textContent=`${name} · ${fmt(date)}`;timeline.append(item);}panel.append(timeline);
        const actions=document.createElement('div');actions.className='pf-actions';actions.innerHTML=payment.status==='معلقة'&&typeof pendingPaymentActions==='function'?pendingPaymentActions(payment):paymentActions(payment);panel.append(actions);
        const note=document.createElement('p');note.className='muted';note.textContent=labels('تظهر الإجراءات حسب صلاحيتك وحالة المعاملة الحالية.','Actions follow your permissions and the current transaction state.');panel.append(note);
      }
      section.classList.add('pf-payments');
      for(const row of section.querySelectorAll('tbody tr')){
        const ids=[...row.querySelectorAll('[onclick]')].map(x=>x.getAttribute('onclick')).join(' ');
        const payment=payments.find(p=>ids.includes(p.id));if(!payment)continue;
        row.classList.toggle('pf-selected',payment.id===selected);
        const cell=row.lastElementChild;if(!cell||cell.querySelector('[data-pf-detail]'))continue;
        const button=document.createElement('button');button.type='button';button.className='btn pf-detail';button.dataset.pfDetail=payment.id;button.textContent=labels('التفاصيل','Details');button.setAttribute('aria-label',`${button.textContent}: ${payment.beneficiary||payment.id}`);button.onclick=()=>{selected=payment.id;decorate();};cell.append(button);
      }
    }
  }
  document.addEventListener('keydown',event=>{if((event.ctrlKey||event.metaKey)&&event.key.toLowerCase()==='k'&&profile&&!document.querySelector('.modal-bg.show')){event.preventDefault();commandPalette();}});
  for(const name of ['renderAll','renderPayments','renderExecutedPayments','renderPendingPayments','renderPostedPayments','applyAccess','applyLanguage','openPage']){
    const previous=window[name];if(typeof previous!=='function')continue;
    window[name]=function(...args){const result=previous.apply(this,args);decorate();return result;};
  }
  decorate();
})();
