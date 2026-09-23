Object.assign(I18N_AR_EN,{
  "تسجيل نشاط إضافي":"Log Extra Activity",
  "الأنشطة الإضافية غير المخططة":"Unplanned Extra Activities",
  "سجل مستقل للأعمال التي تم تنفيذها خارج المهام المسندة. لا تُحتسب كمهام مكتملة، وتحتاج اعتمادًا مبسطًا من المشرف.":"Independent log for work completed outside assigned tasks. It is not counted as completed assigned tasks and requires simple supervisor approval.",
  "اعتماد الكل لليوم":"Approve All Today",
  "ماذا أنجزت؟":"What did you complete?",
  "وقت التنفيذ":"Activity Time",
  "المدة بالدقائق":"Duration (minutes)",
  "التصنيف":"Category",
  "بدون تصنيف":"No Category",
  "بنوك":"Banks",
  "مدفوعات":"Payments",
  "قيود وتسويات":"Journals & Reconciliations",
  "عملاء":"Customers",
  "موردون":"Suppliers",
  "إقفال":"Closing",
  "تقارير وتحليل":"Reporting & Analysis",
  "اجتماع / متابعة":"Meeting / Follow-up",
  "أخرى":"Other",
  "حفظ النشاط":"Save Activity",
  "بانتظار الاعتماد":"Pending Approval",
  "معتمد":"Approved",
  "رفض":"Reject",
  "دقيقة":"min",
  "عدد الأنشطة":"Activity Count",
  "المدة المسجلة":"Recorded Duration",
  "المدة المعتمدة":"Approved Duration"
});

const ADHOC_CATEGORIES=[
  {value:"",label:"بدون تصنيف"},
  {value:"BANKS",label:"بنوك"},
  {value:"PAYMENTS",label:"مدفوعات"},
  {value:"JOURNALS",label:"قيود وتسويات"},
  {value:"CUSTOMERS",label:"عملاء"},
  {value:"SUPPLIERS",label:"موردون"},
  {value:"CLOSE",label:"إقفال"},
  {value:"REPORTING",label:"تقارير وتحليل"},
  {value:"MEETING",label:"اجتماع / متابعة"},
  {value:"OTHER",label:"أخرى"}
];

function adhocCategoryLabel(v){
  const x=ADHOC_CATEGORIES.find(function(item){return item.value===String(v||"")});
  return x?x.label:"—";
}

function adhocStatusLabel(v){
  return v==="Approved"?"معتمد":v==="Rejected"?"مرفوض":"بانتظار الاعتماد";
}

function adhocNowTime(){
  return new Date().toLocaleTimeString("en-GB",{timeZone:"Asia/Riyadh",hour:"2-digit",minute:"2-digit",hour12:false});
}

async function loadAdhocActivities(render){
  if(render===undefined)render=true;
  if(isReadonlyViewer()){adhocActivities=[];return}
  const today=riyadhToday();
  const result=await sb.rpc("get_adhoc_activities",{p_date_from:today,p_date_to:today});
  if(result.error){
    console.error("Ad-hoc activity load failed",result.error);
    adhocActivities=[];
    return;
  }
  adhocActivities=result.data||[];
  if(render){
    renderAdhocActivities();
    try{
      installTableFilters();
      installUniversalColumnCustomizers();
      applyLanguage(document.getElementById("tasks"));
    }catch(e){console.error("Ad-hoc activity render utilities failed",e)}
  }
}

function renderAdhocActivities(){
  const body=document.getElementById("adhocActivitiesBody");
  const summary=document.getElementById("adhocSummary");
  const approveAll=document.getElementById("approveAllAdhocBtn");
  if(!body||!summary)return;

  const manager=["CFO","Supervisor"].includes(profile.role);
  const approved=adhocActivities.filter(function(x){return x.status==="Approved"});
  const pending=adhocActivities.filter(function(x){return x.status==="Pending"});
  const totalMinutes=adhocActivities.filter(function(x){return x.status!=="Rejected"}).reduce(function(s,x){return s+Number(x.duration_minutes||0)},0);
  const approvedMinutes=approved.reduce(function(s,x){return s+Number(x.duration_minutes||0)},0);

  summary.innerHTML=
    '<div class="card"><span class="muted">'+displayText("عدد الأنشطة")+'</span><b>'+latinDigits(adhocActivities.length)+'</b></div>'+
    '<div class="card"><span class="muted">'+displayText("بانتظار الاعتماد")+'</span><b>'+latinDigits(pending.length)+'</b></div>'+
    '<div class="card"><span class="muted">'+displayText("المدة المسجلة")+'</span><b>'+latinDigits(totalMinutes)+' '+displayText("دقيقة")+'</b></div>'+
    '<div class="card"><span class="muted">'+displayText("المدة المعتمدة")+'</span><b>'+latinDigits(approvedMinutes)+' '+displayText("دقيقة")+'</b></div>';

  const reviewable=pending.filter(function(x){return !(profile.role==="Supervisor"&&x.employee_id===profile.id)});
  if(approveAll)approveAll.classList.toggle("hidden",!manager||!reviewable.length);

  body.innerHTML=adhocActivities.map(function(a){
    let actions=[];
    if(manager&&a.status==="Pending"&&!(profile.role==="Supervisor"&&a.employee_id===profile.id)){
      actions.push('<button class="btn success" onclick="reviewAdhocActivity(\''+esc(a.id)+'\',true)">'+displayText("اعتماد")+'</button>');
      actions.push('<button class="btn danger" onclick="reviewAdhocActivity(\''+esc(a.id)+'\',false)">'+displayText("رفض")+'</button>');
    }
    return '<tr>'+
      '<td>'+esc(String(a.activity_time||"").slice(0,5)||"—")+'</td>'+
      '<td>'+esc(a.employee_name||"—")+'</td>'+
      '<td style="white-space:normal;min-width:220px">'+esc(a.title||"—")+'</td>'+
      '<td>'+latinDigits(a.duration_minutes||0)+' '+displayText("دقيقة")+'</td>'+
      '<td>'+esc(displayText(adhocCategoryLabel(a.category)))+'</td>'+
      '<td>'+badge(displayText(adhocStatusLabel(a.status)))+'</td>'+
      '<td>'+fmt(a.recorded_at)+'</td>'+
      '<td>'+(actions.join(" ")||"—")+'</td>'+
    '</tr>';
  }).join("")||'<tr><td colspan="8" class="muted">—</td></tr>';

  applyTableFilters(document.getElementById("adhocActivitiesTable"));
}

function openAdhocActivityModal(){
  const categories=ADHOC_CATEGORIES.map(function(x){return {value:x.value,label:displayText(x.label)}});
  const durationButtons=[15,30,45,60,90].map(function(n){
    return '<button class="btn" type="button" onclick="setAdhocDuration('+n+')">'+n+'</button>';
  }).join("");

  const html=
    '<div class="note">'+displayText("الأنشطة الإضافية غير المخططة")+'</div>'+
    '<div style="margin-top:10px">'+input("adhoc_title","ماذا أنجزت؟")+'</div>'+
    '<div class="modal-grid" style="margin-top:10px">'+
      input("adhoc_time","وقت التنفيذ",adhocNowTime(),"time")+
      select("adhoc_category","التصنيف",categories,"")+
    '</div>'+
    '<label style="margin-top:10px">'+displayText("المدة بالدقائق")+'</label>'+
    '<div class="lang-actions" style="margin:6px 0 8px">'+durationButtons+'</div>'+
    '<input id="adhoc_duration" type="number" min="5" max="720" step="5" value="30">'+
    '<div class="row" style="margin-top:14px"><button class="btn primary" onclick="saveAdhocActivity()">'+displayText("حفظ النشاط")+'</button></div>';

  showModal(displayText("تسجيل نشاط إضافي"),html);
}

function setAdhocDuration(n){
  const el=document.getElementById("adhoc_duration");
  if(el)el.value=String(n);
}

async function saveAdhocActivity(){
  const title=(val("adhoc_title")||"").trim();
  const time=val("adhoc_time");
  const duration=Number(val("adhoc_duration")||0);
  const category=val("adhoc_category")||null;

  if(!title)return alert(displayText("ماذا أنجزت؟"));
  if(!time)return alert(displayText("وقت التنفيذ"));
  if(!Number.isFinite(duration)||duration<5||duration>720){
    return alert(currentLang==="en"?"Duration must be between 5 and 720 minutes.":"المدة يجب أن تكون بين 5 و720 دقيقة.");
  }

  const result=await sb.rpc("record_adhoc_activity",{
    p_title:title,
    p_activity_time:time,
    p_duration_minutes:duration,
    p_category:category
  });
  if(result.error)return alert(result.error.message);
  closeModal();
  await loadAdhocActivities(true);
}

async function reviewAdhocActivity(id,approve){
  if(!["CFO","Supervisor"].includes(profile.role))return;
  const result=await sb.rpc("approve_adhoc_activity",{p_activity_id:id,p_approve:!!approve});
  if(result.error)return alert(result.error.message);
  await loadAdhocActivities(true);
}

async function approveAllAdhocActivities(){
  if(!["CFO","Supervisor"].includes(profile.role))return;
  const msg=currentLang==="en"?"Approve all reviewable extra activities for today?":"اعتماد جميع الأنشطة الإضافية القابلة للمراجعة لليوم؟";
  if(!confirm(msg))return;
  const result=await sb.rpc("approve_all_adhoc_activities_today");
  if(result.error)return alert(result.error.message);
  await loadAdhocActivities(true);
  alert(currentLang==="en"?String(result.data||0)+" activities approved.":"تم اعتماد "+String(result.data||0)+" نشاط.");
}
