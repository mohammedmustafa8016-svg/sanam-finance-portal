(() => {
 'use strict';const parameters=new URLSearchParams(location.search),state=parameters.get('state');
 history.replaceState(null,'',location.pathname);
 if(!state||!/^[a-zA-Z0-9_-]{32,128}$/.test(state)){document.getElementById('status').textContent='تعذر التحقق من طلب الربط. أعد المحاولة من مركز التحكم المالي.';return;}
 const result={type:'sanam-outlook-code',state,code:parameters.get('code'),error:parameters.get('error')};
 if(window.opener)window.opener.postMessage(result,location.origin);
 const channel=new BroadcastChannel('sanam-outlook-'+state);channel.postMessage(result);channel.close();
 document.getElementById('status').textContent='اكتمل الرجوع إلى النظام. يمكنك إغلاق هذه النافذة.';setTimeout(()=>window.close(),300);
})();
