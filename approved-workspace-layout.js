/* Approved composition only: keep native controls, IDs and authorization guards. */
(() => {
 'use strict';
 function arrange(){
  const root=document.getElementById('workcenter');
  if(root){
   const meta=root.querySelector('.wc-meta'),status=document.getElementById('wcWorkdayStatus');
   if(meta&&status&&status.parentElement!==meta)meta.append(status);
   const heading=root.querySelector('#wcResults .wc-panel-heading>div'),count=document.getElementById('wcResultCount');
   if(heading&&count&&count.parentElement!==heading)heading.append(count);
  }
  const title=document.getElementById('pageTitle');if(title)title.textContent=currentLang==='en'?'Financial Control Center':'مركز التحكم المالي';
 }
 for(const name of ['wcBuildShell','applyAccess','applyLanguage','openPage']){
  const original=window[name];if(typeof original!=='function')continue;
  window[name]=function(...args){const result=original.apply(this,args);arrange();return result;};
 }
 arrange();
})();
