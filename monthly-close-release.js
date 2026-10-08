/* CFO-controlled monthly close release UI. Additive layer over the existing Close page. */
Object.assign(I18N_AR_EN,{
  "MONTHLY_CLOSE_RELEASE_DUE":"Monthly Close Release",
  "مخططة — لم تُفتح":"Planned — Not Released",
  "مفتوحة في مركز العمل":"Released to Work Center",
  "فتح المستحق حتى اليوم":"Release Due Tasks",
  "حالة الفتح":"Release Status",
  "تاريخ البدء":"Start Date",
  "مراجعة مهام الإقفال":"Review Monthly Close",
  "فتح في مركز العمل":"Release to Work Center"
});

function monthlyCloseReleaseLabel(s){
  return ({Planned:"مخططة — لم تُفتح",Released:"مفتوحة في مركز العمل",Completed:"مكتملة",Cancelled:"ملغاة"})[s]||s||"—";
}

function renderClose(){
  let rows=closeTasks||[];
  const latest=[...rows].map(function(x){return x.close_period}).filter(Boolean).sort().pop();
  if(closeQuickView&&rows.length){
    rows=rows.filter(function(x){return x.close_period===latest&&x.status!=="مكتمل"&&Number(x.progress||0)<100});
  }
  const today=riyadhToday();
  const ready=(closeTasks||[]).filter(function(x){
    return x.close_period===latest&&x.release_status==="Planned"&&!x.task_id&&x.planned_start_date&&x.planned_start_date<=today;
  });
  const releaseAll=document.getElementById("releaseReadyCloseBtn");
  if(releaseAll)releaseAll.classList.toggle("hidden",profile.role!=="CFO"||!ready.length);
  closeBody.innerHTML=rows.map(function(x){
    const canRelease=profile.role==="CFO"&&x.release_status==="Planned"&&!x.task_id&&x.planned_start_date&&x.planned_start_date<=today;
    const canOpenTask=!!x.task_id&&(profile.role==="CFO"||profile.role==="Supervisor"||x.owner_id===profile.id);
    const actions=[];
    if(canRelease)actions.push('<button class="btn primary" onclick="releaseMonthlyCloseTask(\''+esc(x.id)+'\')">'+(currentLang==="en"?"Release":displayText("فتح في مركز العمل"))+'</button>');
    if(canOpenTask)actions.push('<button class="btn" onclick="openTaskWorkspace(\''+esc(x.task_id)+'\')">'+displayText("فتح المهمة")+'</button>');
    return "<tr>"+
      "<td>"+esc(x.track)+"</td>"+
      "<td>"+esc(x.code||"—")+"</td>"+
      "<td>"+esc(x.name)+"</td>"+
      "<td>"+esc((x.owner&&x.owner.full_name)||"—")+"</td>"+
      "<td>"+esc(x.planned_start_date||x.due_date||"—")+"</td>"+
      "<td>"+esc(x.due_date||"—")+"</td>"+
      "<td>"+badge(x.priority||"عادي")+"</td>"+
      '<td style="white-space:normal">'+esc(x.output||"—")+"</td>"+
      "<td>"+Number(x.progress||0)+"%</td>"+
      "<td>"+badge(x.status)+"</td>"+
      "<td>"+badge(displayText(monthlyCloseReleaseLabel(x.release_status)))+"</td>"+
      '<td><div class="task-actions-wrap">'+(actions.join(" ")||"—")+"</div></td>"+
    "</tr>";
  }).join("")||'<tr><td colspan="12" class="muted">'+displayText("لا توجد مهام إقفال للدورة الحالية.")+"</td></tr>";
}

async function releaseMonthlyCloseTask(id){
  if(profile.role!=="CFO")return;
  const item=(closeTasks||[]).find(function(x){return x.id===id});
  if(!item)return;
  const msg=currentLang==="en" ?
    'Release "'+item.name+'" to the Work Center?' :
    "فتح المهمة «"+item.name+"» في مركز العمل وإسنادها إلى "+(((item.owner||{}).full_name)||"المسؤول")+"؟";
  if(!confirm(msg))return;
  const result=await sb.rpc("release_monthly_close_task",{p_close_task_id:id});
  if(result.error)return alert(result.error.message);
  await reloadAll();
  openPage("close",displayText("الإقفال"));
}

async function releaseReadyMonthlyCloseTasks(){
  if(profile.role!=="CFO")return;
  const latest=[...(closeTasks||[])].map(function(x){return x.close_period}).filter(Boolean).sort().pop()||null;
  const today=riyadhToday();
  const ready=(closeTasks||[]).filter(function(x){
    return (!latest||x.close_period===latest)&&x.release_status==="Planned"&&!x.task_id&&x.planned_start_date&&x.planned_start_date<=today;
  });
  if(!ready.length)return alert(currentLang==="en"?"No monthly-close tasks are ready for release.":"لا توجد مهام إقفال مستحقة وجاهزة للفتح.");
  const msg=currentLang==="en" ?
    "Release "+ready.length+" due monthly-close tasks to the Work Center?" :
    "فتح "+ready.length+" مهمة إقفال مستحقة في مركز العمل الآن؟";
  if(!confirm(msg))return;
  const result=await sb.rpc("release_monthly_close_ready_tasks",{p_close_period:latest});
  if(result.error)return alert(result.error.message);
  await reloadAll();
  openPage("close",displayText("الإقفال"));
  alert(currentLang==="en"?String(result.data||0)+" tasks released.":"تم فتح "+String(result.data||0)+" مهمة في مركز العمل.");
}

async function markNotificationAndOpenClose(id){
  await sb.rpc("mark_task_notification_read",{p_notification_id:id});
  closeModal();
  await reloadAll();
  openPage("close",displayText("الإقفال"));
}