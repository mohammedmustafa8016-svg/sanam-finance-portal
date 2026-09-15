from pathlib import Path
p=Path('index.html')
s=p.read_text()
# Redirect users away from dashboard when dashboard is not permitted.
old='function applyAccess(){document.querySelectorAll(".nav").forEach(b=>b.classList.toggle("hidden",!canPage(b.dataset.page)));addBankBtn?.classList.toggle("hidden",!["CFO","Supervisor","BankAccountant"].includes(profile.role));'
new='function applyAccess(){document.querySelectorAll(".nav").forEach(b=>b.classList.toggle("hidden",!canPage(b.dataset.page)));const active=document.querySelector(".section.active");if(active&&!canPage(active.id)){const first=[...document.querySelectorAll(".nav")].find(b=>canPage(b.dataset.page));if(first)openPage(first.dataset.page,first.textContent)}addBankBtn?.classList.toggle("hidden",!["CFO","Supervisor","BankAccountant"].includes(profile.role));'
if old not in s: raise SystemExit('applyAccess anchor missing')
s=s.replace(old,new,1)
# Add posted page to CFO permission matrix.
s=s.replace('<th>المدفوعات</th><th>المهام</th>', '<th>المدفوعات</th><th>المدفوعات المرحلة</th><th>المهام</th>',1)
s=s.replace("const PERMISSION_COLUMNS=[['page.dashboard','Dashboard'],['page.banks','البنوك'],['page.payments','المدفوعات'],['page.tasks','المهام']", "const PERMISSION_COLUMNS=[['page.dashboard','Dashboard'],['page.banks','البنوك'],['page.payments','المدفوعات'],['page.posted','المدفوعات المرحلة'],['page.tasks','المهام']",1)
p.write_text(s)
print('fixed')
