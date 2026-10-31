/* Snapshot selection: new arrivals are never silently included in a bulk read. */
(() => {
 'use strict';let selected=new Set(),selectionUser=null,saving=false;
 const text=(ar,en)=>currentLang==='en'?en:ar;
 function decorate(){
  const shell=document.getElementById('notificationInbox');if(!shell)return;
  selected.clear();selectionUser=profile?.id;
  shell.querySelector('.inbox-bulk')?.remove();
  const toolbar=document.createElement('div');toolbar.className='inbox-toolbar inbox-bulk';
  const select=document.createElement('input');select.type='checkbox';select.id='inboxSelectVisible';
  const label=document.createElement('label');label.className='inbox-check';label.append(select,document.createTextNode(text('تحديد غير المقروء الظاهر','Select visible unread')));
  const submit=document.createElement('button');submit.type='button';submit.className='btn primary';submit.disabled=true;
  const update=()=>{submit.textContent=`${text('تحديد المحدد كمقروء','Mark selection read')} (${selected.size})`;submit.disabled=saving||!selected.size;const boxes=[...shell.querySelectorAll('[data-inbox-select]')];select.checked=boxes.length>0&&boxes.every(b=>b.checked);select.indeterminate=selected.size>0&&!select.checked;};
  const rows=inboxState.data?.items||[];
  shell.querySelectorAll('.inbox-item').forEach((article,index)=>{const n=rows[index];if(!n||n.read_at)return;const box=document.createElement('input');box.type='checkbox';box.dataset.inboxSelect=n.id;box.setAttribute('aria-label',`${text('تحديد','Select')} ${n.title}`);box.onchange=()=>{if(box.checked)selected.add(n.id);else selected.delete(n.id);update();};const holder=document.createElement('label');holder.className='inbox-check';holder.append(box,document.createTextNode(text('تحديد التنبيه','Select notification')));article.prepend(holder);});
  select.onchange=()=>{const checked=select.checked;for(const box of shell.querySelectorAll('[data-inbox-select]')){box.checked=checked;if(checked)selected.add(box.dataset.inboxSelect);else selected.delete(box.dataset.inboxSelect);}update();};
  submit.onclick=async()=>{if(saving||selectionUser!==profile?.id||!selected.size)return;const ids=[...selected],user=selectionUser;saving=true;update();select.disabled=true;shell.querySelectorAll('[data-inbox-select]').forEach(b=>b.disabled=true);try{const {error}=await sb.rpc('mark_task_notifications_read',{p_notification_ids:ids});if(user!==profile?.id)return;if(error)throw error;await refreshNotificationBadge();await loadNotificationInbox();}catch(e){if(user===profile?.id)inboxShowError(e);}finally{saving=false;if(user===profile?.id){select.disabled=false;shell.querySelectorAll('[data-inbox-select]').forEach(b=>b.disabled=false);update();}}};
  toolbar.append(label,submit);document.getElementById('inboxItems').before(toolbar);update();
 }
 let generation=0;const previous=loadNotificationInbox;
 loadNotificationInbox=async function(...args){const token=++generation,user=profile?.id;selected.clear();document.querySelector('.inbox-bulk')?.remove();const result=await previous.apply(this,args);if(token!==generation||user!==profile?.id||!document.getElementById('inboxError')?.classList.contains('hidden'))return result;decorate();return result;};
})();
