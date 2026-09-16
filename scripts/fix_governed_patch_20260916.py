from pathlib import Path
p=Path('index.html')
s=p.read_text()
# renderDashboard already declares canMove before the replaced reserve block; remove the generated duplicate.
s=s.replace(" const canMove=['CFO','Supervisor','BankAccountant'].includes(profile.role);\n reserveMonitorCards.innerHTML=reserveAccounts.map", " reserveMonitorCards.innerHTML=reserveAccounts.map", 1)
# Replace UUID prompt with a proper team selector for template creation.
old="function openTaskTemplateModal(){const name=prompt(currentLang==='en'?'Template name:':'اسم القالب:');if(!name||!name.trim())return;const owner=prompt(currentLang==='en'?'Paste owner ID from the team list shown in Daily Plan.':'أدخل معرف الموظف المسؤول من بيانات الفريق.');if(!owner)return;const {error}=await sb.rpc('create_finance_task_template',{p_name:name.trim(),p_owner_id:owner,p_priority:'عادي',p_output:null});if(error)return alert(error.message);closeModal();await openDailyPlan()}"
new="function openTaskTemplateModal(){const owners=profiles.map(x=>({value:x.id,label:x.full_name}));showModal(displayText('إضافة قالب جديد'),`<div class=\"modal-grid\">${input('tpl_name','المهمة')}${select('tpl_owner','المسؤول',[{value:'',label:'—'},...owners])}${select('tpl_priority','الأولوية',['عادي','عالي','حرج'])}${input('tpl_output','المخرج')}</div><div class=\"row\" style=\"margin-top:14px\"><button class=\"btn primary\" onclick=\"saveTaskTemplate()\">${displayText('حفظ')}</button></div>`)}\nasync function saveTaskTemplate(){const name=(val('tpl_name')||'').trim(),owner=val('tpl_owner');if(!name||!owner)return alert(currentLang==='en'?'Template name and owner are required.':'اسم القالب والمسؤول مطلوبان.');const {error}=await sb.rpc('create_finance_task_template',{p_name:name,p_owner_id:owner,p_priority:val('tpl_priority')||'عادي',p_output:val('tpl_output')||null});if(error)return alert(error.message);closeModal();await openDailyPlan()}"
if old not in s: raise SystemExit('template function not found')
s=s.replace(old,new,1)
p.write_text(s)
