/* The same eligible-day rule is enforced in the database workflow and reports. */
((root)=>{
 'use strict';const DAY=86400000,OFFSET=10800000;
 function seconds(start,end){let a=new Date(start).getTime(),b=new Date(end).getTime();if(!Number.isFinite(a)||!Number.isFinite(b))return null;let sign=1;if(b<a){[a,b]=[b,a];sign=-1;}a+=OFFSET;b+=OFFSET;let sum=0;for(let d=Math.floor(a/DAY)*DAY;d<=b;d+=DAY){const day=new Date(d).getUTCDay();if(day!==5&&day!==6)sum+=Math.max(0,Math.min(b,d+DAY)-Math.max(a,d));}return sign*sum/1000;}
 function deadline(start){let cursor=new Date(start).getTime()+OFFSET,left=48*3600000;if(!Number.isFinite(cursor))return null;while(left>0){const day=new Date(cursor).getUTCDay(),next=(Math.floor(cursor/DAY)+1)*DAY;if(day===5||day===6){cursor=next;continue;}const available=next-cursor;if(left<=available){let target=cursor+left;while([5,6].includes(new Date(target).getUTCDay()))target=(Math.floor(target/DAY)+1)*DAY;return new Date(target-OFFSET);}left-=available;cursor=next;}return new Date(cursor-OFFSET);}
 function info(p,now=Date.now(),lang='ar'){
  const en=lang==='en',start=p.accounting_registered_at||p.executed_at,end=p.posted_at||now;
  if(!start)return {label:'—',cls:'',remaining:'—'};
  const elapsed=seconds(start,end);if(elapsed===null)return {label:'—',cls:'',remaining:'—'};
  const hours=48-elapsed/3600,over=hours<0;
  return {label:p.posted_at?(en?'Posted':'تم الترحيل'):over?(en?'Overdue':'متجاوز المهلة'):hours<=12?(en?'Due soon':'قرب انتهاء المهلة'):(en?'Within SLA':'داخل المهلة'),cls:over?'sla-overdue':hours<=12?'sla-due':'sla-ok',remaining:p.posted_at?(en?'Completed':'مكتمل'):over?`${Math.abs(hours).toFixed(1)}h ${en?'overdue':'متأخر'}`:`${hours.toFixed(1)}h`,phase:p.accounting_registered_at?'posting':'registration',deadline:deadline(start)};
 }
 const api={seconds,deadline,info};root.SanamSla=api;if(typeof module==='object'&&module.exports)module.exports=api;
})(typeof globalThis==='object'?globalThis:this);
