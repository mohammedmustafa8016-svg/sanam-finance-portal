from pathlib import Path

p=Path('index.html')
s=p.read_text(encoding='utf-8')
start=s.find('async function saveDailyPlan(){')
end=s.find('\n\nfunction renderTaskUtilityState',start)
if start<0 or end<0:
    raise SystemExit('saveDailyPlan generated block not found')
fn=r'''async function saveDailyPlan(){
 const items=[];
 document.querySelectorAll('.plan-template-check:checked').forEach(c=>{const id=c.dataset.id;items.push({catalog_id:id,owner_id:document.querySelector(`.plan-template-owner[data-id="${id}"]`)?.value||'',priority:document.querySelector(`.plan-template-priority[data-id="${id}"]`)?.value||'عادي',due_time:document.querySelector(`.plan-template-time[data-id="${id}"]`)?.value||''})});
 const name=(val('plan_new_name')||'').trim();
 if(name)items.push({name,owner_id:val('plan_new_owner'),priority:val('plan_new_priority')||'عادي',due_time:val('plan_new_time'),output:val('plan_new_output')||null,save_as_template:!!document.getElementById('plan_save_template')?.checked});
 if(!items.length)return alert(currentLang==='en'?'Select a template or add a new task.':'اختر قالبًا أو أضف مهمة جديدة.');
 if(items.some(x=>!x.owner_id||!x.due_time))return alert(currentLang==='en'?'Owner and due time are required.':'يجب تحديد المسؤول ووقت التسليم.');
 const {data,error}=await sb.rpc('save_manual_daily_plan',{p_items:items});
 if(error)return alert(error.message);
 closeModal();
 await reloadAll();
 await loadWorkCenter();
 alert(currentLang==='en'?`${data||0} tasks opened and published to the team.`:`تم فتح ${data||0} مهمة وظهورها في مركز العمل.`)
}'''
s=s[:start]+fn+s[end:]
p.write_text(s,encoding='utf-8')
