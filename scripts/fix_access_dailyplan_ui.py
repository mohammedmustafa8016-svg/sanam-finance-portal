from pathlib import Path
p=Path('index.html')
s=p.read_text()
old='function applyAccess(){document.querySelectorAll(".nav").forEach(b=>b.classList.toggle("hidden",!canPage(b.dataset.page)));addBankBtn?.classList.toggle("hidden",!["CFO","Supervisor","BankAccountant"].includes(profile.role));'
new='function applyAccess(){document.querySelectorAll(".nav").forEach(b=>b.classList.toggle("hidden",!canPage(b.dataset.page)));const active=document.querySelector(".section.active");if(active&&!canPage(active.id)){const first=[...document.querySelectorAll(".nav")].find(b=>canPage(b.dataset.page));if(first)openPage(first.dataset.page,first.textContent)}addBankBtn?.classList.toggle("hidden",!["CFO","Supervisor","BankAccountant"].includes(profile.role));'
if old in s:
    s=s.replace(old,new,1)
if '<th>المدفوعات</th><th>المهام</th>' in s:
    s=s.replace('<th>المدفوعات</th><th>المهام</th>', '<th>المدفوعات</th><th>المدفوعات المرحلة</th><th>المهام</th>',1)
old_cols="const PERMISSION_COLUMNS=[['page.dashboard','Dashboard'],['page.banks','البنوك'],['page.payments','المدفوعات'],['page.tasks','المهام']"
new_cols="const PERMISSION_COLUMNS=[['page.dashboard','Dashboard'],['page.banks','البنوك'],['page.payments','المدفوعات'],['page.posted','المدفوعات المرحلة'],['page.tasks','المهام']"
if old_cols in s:
    s=s.replace(old_cols,new_cols,1)
p.write_text(s)
print('fixed/idempotent')
