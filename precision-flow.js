/* Presentation only: existing action builders and server guards remain authoritative. */
(() => {
  'use strict';
  const labels = (ar,en) => currentLang==='en'?en:ar;
  const destinations=[['dashboard','الرئيسية','Home'],['workcenter','مركز العمل','Work Center'],['tasks','المهام','Tasks'],['payments','المدفوعات والاعتمادات','Payments & approvals'],['executed','الاعتمادات المنفذة','Executed payments'],['pending','الاعتمادات المعلقة','Pending payments'],['posted','المرحلة محاسبيًا','Posted payments'],['banks','السيولة والبنوك','Liquidity & banks'],['imprest','العهد','Imprest'],['close','الإقفال الشهري','Monthly close'],['performance','الأداء والتقارير','Performance & reports'],['audit','سجل التدقيق','Audit log']];
  function commandPalette(){
    if(!profile)return;
    showModal(labels('الانتقال السريع','Quick navigation'),'<label id="pfSearchLabel" for="pfSearchInput"></label><input id="pfSearchInput" autocomplete="off"><div id="pfSearchResults" class="pf-search-results"></div>');
    document.getElementById('pfSearchLabel').textContent=labels('ابحث باسم الصفحة','Search by page name');
    const input=document.getElementById('pfSearchInput'),results=document.getElementById('pfSearchResults');
    function search(){results.replaceChildren();for(const [id,ar,en] of destinations){if(!canPage(id)||!document.getElementById(id)||!`${ar} ${en}`.toLocaleLowerCase().includes(input.value.trim().toLocaleLowerCase()))continue;const button=document.createElement('button');button.type='button';button.className='btn';button.textContent=labels(ar,en);button.onclick=()=>{if(!canPage(id))return;closeModal();openPage(id,labels(ar,en));};results.append(button);}if(!results.children.length)results.textContent=labels('لا توجد صفحات متاحة تطابق البحث.','No available pages match your search.');}
    input.addEventListener('input',search);search();input.focus();
  }
  function decorate(){
    const top=document.querySelector('.top');
    if(top&&!top.querySelector('#pfCommand')){const button=document.createElement('button');button.id='pfCommand';button.type='button';button.className='btn pf-command';button.onclick=commandPalette;top.insertBefore(button,top.querySelector('.lang-actions'));}
    const command=document.getElementById('pfCommand');if(command){command.textContent=labels('انتقال سريع  ·  Ctrl K','Quick navigation  ·  Ctrl K');command.hidden=!profile;}
  }
  document.addEventListener('keydown',event=>{if((event.ctrlKey||event.metaKey)&&event.key.toLowerCase()==='k'&&profile&&!document.querySelector('.modal-bg.show')){event.preventDefault();commandPalette();}});
  for(const name of ['applyAccess','applyLanguage','openPage']){
    const previous=window[name];if(typeof previous!=='function')continue;
    window[name]=function(...args){const result=previous.apply(this,args);decorate();return result;};
  }
  decorate();
})();
