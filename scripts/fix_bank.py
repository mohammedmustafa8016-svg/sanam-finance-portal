from pathlib import Path

p = Path('index.html')
html = p.read_text(encoding='utf-8')
old = 'function renderBanks(){banksBody.innerHTML=banks.map(b=>`<tr><td>${esc(b.company)}</td><td>${esc(b.bank_name)}</td><td>${esc(b.account_name)}</td><td>${money(b.balance)}</td><td>${money(b.reserved_balance)}</td><td>${money(b.available_balance)}</td><td>${fmt(b.updated_at)}</td><td>عرض</td></tr>`).join("")}function openBankModal(){return}async function saveBank(){return}'
new = r'''function renderBanks(){banksBody.innerHTML=banks.map(b=>`<tr><td>${esc(b.company)}</td><td>${esc(b.bank_name)}</td><td>${esc(b.account_name)}</td><td>${money(b.balance)}</td><td>${money(b.reserved_balance)}</td><td>${money(b.available_balance)}</td><td>${fmt(b.updated_at)}</td><td>عرض</td></tr>`).join("")}
function openBankModal(){
  if(!profile||!["CFO","Supervisor","BankAccountant"].includes(profile.role))return;
  showModal("إضافة حساب بنكي",`
    <div class="modal-grid">
      ${input("bankCompany","الشركة")}
      ${input("bankName","اسم البنك")}
      ${input("bankAccountName","اسم الحساب")}
      ${input("bankAccountNo","رقم الحساب / IBAN")}
      ${input("bankBalance","الرصيد الحالي","0","number")}
    </div>
    <div class="note" style="margin-top:12px">الرصيد المحجوز لا يتم إدخاله يدويًا؛ يتم احتسابه تلقائيًا من المدفوعات غير المنفذة المرتبطة بهذا الحساب.</div>
    <div id="bankSaveMsg" class="muted" style="margin-top:10px"></div>
    <div class="row" style="margin-top:14px;justify-content:flex-start">
      <button id="saveBankBtn" class="btn primary" type="button">حفظ الحساب</button>
      <button class="btn" type="button" onclick="closeModal()">إلغاء</button>
    </div>`);
  document.getElementById("saveBankBtn")?.addEventListener("click",saveBank);
}
async function saveBank(){
  const company=val("bankCompany").trim(),bank_name=val("bankName").trim(),account_name=val("bankAccountName").trim(),account_no=val("bankAccountNo").trim(),balance=Number(val("bankBalance")||0);
  const msg=document.getElementById("bankSaveMsg"),btn=document.getElementById("saveBankBtn");
  if(!company||!bank_name||!account_name){if(msg)msg.textContent="يرجى إدخال الشركة واسم البنك واسم الحساب.";return}
  if(!Number.isFinite(balance)||balance<0){if(msg)msg.textContent="الرصيد يجب أن يكون رقمًا صحيحًا صفرًا أو أكبر.";return}
  if(btn)btn.disabled=true;if(msg)msg.textContent="جارٍ الحفظ...";
  const payload={company,bank_name,account_name,account_no:account_no||null,balance,created_by:session?.user?.id||null,updated_at:new Date().toISOString()};
  const {error}=await sb.from("bank_accounts").insert(payload);
  if(error){if(btn)btn.disabled=false;if(msg)msg.textContent="تعذر حفظ الحساب: "+(error.message||"خطأ غير معروف");return}
  closeModal();await reloadAll();
}'''
if old not in html:
    raise SystemExit('Expected bank stub block not found')
html = html.replace(old, new, 1)
html = html.replace('function showModal(t,b){modalTitle.textContent=t;modalBody.innerHTML=b;modalBg.classList.add("show")}function closeModal(){modalBg.classList.remove("show")}', 'function showModal(t,b){const title=document.getElementById("modalTitle"),body=document.getElementById("modalBody"),bg=document.getElementById("modalBg");if(!title||!body||!bg){alert("تعذر فتح نافذة الإدخال.");return}title.textContent=t;body.innerHTML=b;bg.classList.add("show")}function closeModal(){document.getElementById("modalBg")?.classList.remove("show")}')
p.write_text(html, encoding='utf-8')
