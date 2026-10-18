(() => {
  const RIYADH_OFFSET_MS=3*60*60*1000;
  const DAY_MS=24*60*60*1000;

  function normalizeDateString(value){
    const s=String(value||"").slice(0,10);
    return /^\d{4}-\d{2}-\d{2}$/.test(s)?s:"";
  }

  function weekdayFromDateString(value){
    const s=normalizeDateString(value);
    if(!s)return null;
    return new Date(s+"T00:00:00Z").getUTCDay();
  }

  window.sanamTaskIsWorkingDate=function(value){
    const day=weekdayFromDateString(value);
    return day!==null && day!==5 && day!==6;
  };

  window.sanamTaskEffectiveDueDate=function(value){
    const s=normalizeDateString(value);
    if(!s)return s;
    const day=weekdayFromDateString(s);
    const d=new Date(s+"T00:00:00Z");
    if(day===5)d.setUTCDate(d.getUTCDate()+2);
    else if(day===6)d.setUTCDate(d.getUTCDate()+1);
    return d.toISOString().slice(0,10);
  };

  window.sanamTaskDeadlineFromParts=function(dueDate,dueTime){
    const effective=sanamTaskEffectiveDueDate(dueDate);
    if(!effective)return null;
    const time=String(dueTime||"23:59:59").slice(0,8);
    const d=new Date(`${effective}T${time}+03:00`);
    return Number.isNaN(d.getTime())?null:d;
  };

  window.sanamTaskBusinessMinutesBetween=function(start,end){
    const a=start instanceof Date?start:new Date(start);
    const b=end instanceof Date?end:new Date(end);
    if(Number.isNaN(a.getTime())||Number.isNaN(b.getTime()))return null;
    if(a.getTime()===b.getTime())return 0;

    let lo=a.getTime(),hi=b.getTime(),sign=1;
    if(hi<lo){[lo,hi]=[hi,lo];sign=-1}

    const loLocal=lo+RIYADH_OFFSET_MS;
    const hiLocal=hi+RIYADH_OFFSET_MS;
    let dayStart=Math.floor(loLocal/DAY_MS)*DAY_MS;
    const lastDay=Math.floor(hiLocal/DAY_MS)*DAY_MS;
    let totalMs=0;

    while(dayStart<=lastDay){
      const day=new Date(dayStart).getUTCDay();
      if(day!==5&&day!==6){
        const segStart=Math.max(loLocal,dayStart);
        const segEnd=Math.min(hiLocal,dayStart+DAY_MS);
        if(segEnd>segStart)totalMs+=segEnd-segStart;
      }
      dayStart+=DAY_MS;
    }

    return sign*Math.floor(totalMs/60000);
  };
})();
