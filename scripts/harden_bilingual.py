from pathlib import Path
p=Path('index.html')
s=p.read_text(encoding='utf-8')

# Add language selector to login card without duplicating the in-app control.
if 'id="authLangBtn"' not in s:
    old='<div class="auth-card">\n    <h1>Sanam Finance Portal</h1>'
    new='<div class="auth-card">\n    <div style="display:flex;justify-content:flex-end;margin-bottom:8px"><button id="authLangBtn" class="btn" type="button" onclick="toggleLanguage()">English</button></div>\n    <h1>Sanam Finance Portal</h1>'
    if old not in s: raise SystemExit('auth card anchor missing')
    s=s.replace(old,new,1)

# Extend translations by injecting Object.assign immediately after the base dictionary.
marker='const I18N_EN_AR=Object.fromEntries(Object.entries(I18N_AR_EN).map(([a,e])=>[e,a]));'
if 'BILINGUAL_EXTENSIONS_APPLIED' not in s:
    ext=r'''/* BILINGUAL_EXTENSIONS_APPLIED */
Object.assign(I18N_AR_EN,{
"نسخة سحابية تجريبية — الدخول متاح فقط لأعضاء فريق الإدارة المالية المعتمدين.":"Cloud pilot — access is limited to approved Finance team members.",
"الحد الأدنى: 8 خانات، ويجب أن تتضمن حروفًا وأرقامًا معًا.":"Minimum 8 characters and must include both letters and numbers.",
"في أول استخدام اختر كلمة مرور من 8 خانات على الأقل وتحتوي على حرف واحد ورقم واحد على الأقل، ثم اضغط «تفعيل الحساب لأول مرة». بعد ذلك استخدم «تسجيل الدخول» دائمًا.":"On first use, choose a password of at least 8 characters containing at least one letter and one number, then select “Activate account first time”. Afterwards, always use “Sign in”.",
"8 خانات على الأقل تشمل حروفًا وأرقامًا":"At least 8 characters including letters and numbers",
"أدخل بريد العمل.":"Enter your work email.","كلمة المرور يجب أن تكون 8 خانات على الأقل.":"Password must be at least 8 characters.","كلمة المرور يجب أن تحتوي على حروف وأرقام معًا، ولا يمكن أن تكون حروفًا فقط أو أرقامًا فقط.":"Password must contain both letters and numbers and cannot be letters-only or numbers-only.","جارٍ تسجيل الدخول...":"Signing in...","تعذر تسجيل الدخول. تحقق من البريد وكلمة المرور.":"Unable to sign in. Check your email and password.","جارٍ تفعيل الحساب...":"Activating account...","الحساب مفعّل مسبقًا. استخدم «تسجيل الدخول».":"Account is already activated. Use “Sign in”.","تعذر تفعيل الحساب. تأكد أن البريد ضمن الفريق المعتمد.":"Unable to activate account. Confirm that the email is on the approved team list.","تم تفعيل الحساب وتسجيل الدخول.":"Account activated and signed in.","تم تفعيل الحساب.":"Account activated.","الحساب غير مصرح أو لم يكتمل إنشاؤه.":"Account is not authorized or setup is incomplete.",
"المدير المالي":"Chief Financial Officer","مشرف الحسابات":"Accounts Supervisor","محاسب البنوك":"Bank Accountant","محاسب القيود والتسويات":"GL & Reconciliation Accountant","محاسب المبيعات والعملاء":"Sales & AR Accountant","محاسب الموردين والمشاريع":"AP & Projects Accountant",
"اسم المهمة":"Task Name","عام":"General","نسبة الإنجاز":"Progress %","عامة":"General","مشروع":"Project","اسم العهدة":"Imprest Name","العمر بالأيام":"Aging (Days)","سليمة":"Healthy","تحتاج تسوية":"Needs Settlement","متأخرة":"Overdue","النتيجة":"Score","لا توجد بيانات أداء بعد.":"No performance data yet.","إجازة":"Leave","البريد":"Email","أضف حسابًا بنكيًا أولًا.":"Add a bank account first.","تعذر فتح نافذة الإدخال. يرجى تحديث الصفحة.":"Unable to open the input window. Please refresh the page.","الكل":"All"
});
'''
    if marker not in s: raise SystemExit('i18n marker missing')
    # Rebuild reverse dictionary after extensions, so move the original reverse creation below the extension.
    s=s.replace(marker,ext+'\n'+marker,1)

# Translate placeholders and keep both language buttons synchronized.
old="const b=document.getElementById('langBtn');if(b)b.textContent=currentLang==='ar'?'English':'العربية'"
new="root.querySelectorAll?.('[placeholder]').forEach(el=>{const x=el.getAttribute('placeholder'),y=tr(x);if(y!==x)el.setAttribute('placeholder',y)});const b=document.getElementById('langBtn');if(b)b.textContent=currentLang==='ar'?'English':'العربية';const ab=document.getElementById('authLangBtn');if(ab)ab.textContent=currentLang==='ar'?'English':'العربية'"
if old in s: s=s.replace(old,new,1)

# Keep role heading synchronized after language switch.
old="function toggleLanguage(){currentLang=currentLang==='ar'?'en':'ar';localStorage.setItem('sanam_lang',currentLang);renderAll();applyLanguage()}"
new="function toggleLanguage(){currentLang=currentLang==='ar'?'en':'ar';localStorage.setItem('sanam_lang',currentLang);if(profile)userRole.textContent=`${profile.full_name} — ${displayText(ROLE_LABEL[profile.role]||profile.role)}`;renderAll();applyLanguage()}"
if old in s: s=s.replace(old,new,1)

# Dynamic auth messages should respect current language.
repls={
'loginMsg.textContent="أدخل بريد العمل."':'loginMsg.textContent=displayText("أدخل بريد العمل.")',
'loginMsg.textContent="كلمة المرور يجب أن تكون 8 خانات على الأقل."':'loginMsg.textContent=displayText("كلمة المرور يجب أن تكون 8 خانات على الأقل.")',
'loginMsg.textContent="كلمة المرور يجب أن تحتوي على حروف وأرقام معًا، ولا يمكن أن تكون حروفًا فقط أو أرقامًا فقط."':'loginMsg.textContent=displayText("كلمة المرور يجب أن تحتوي على حروف وأرقام معًا، ولا يمكن أن تكون حروفًا فقط أو أرقامًا فقط.")',
'loginMsg.textContent="جارٍ تسجيل الدخول..."':'loginMsg.textContent=displayText("جارٍ تسجيل الدخول...")',
'if(error)loginMsg.textContent="تعذر تسجيل الدخول. تحقق من البريد وكلمة المرور."':'if(error)loginMsg.textContent=displayText("تعذر تسجيل الدخول. تحقق من البريد وكلمة المرور.")',
'loginMsg.textContent="جارٍ تفعيل الحساب..."':'loginMsg.textContent=displayText("جارٍ تفعيل الحساب...")',
'loginMsg.textContent="تم تفعيل الحساب وتسجيل الدخول."':'loginMsg.textContent=displayText("تم تفعيل الحساب وتسجيل الدخول.")',
'else loginMsg.textContent="تم تفعيل الحساب."':'else loginMsg.textContent=displayText("تم تفعيل الحساب.")',
'loginMsg.textContent="الحساب غير مصرح أو لم يكتمل إنشاؤه."':'loginMsg.textContent=displayText("الحساب غير مصرح أو لم يكتمل إنشاؤه.")'
}
for a,b in repls.items(): s=s.replace(a,b)
# First-use ternary.
s=s.replace('loginMsg.textContent=m.includes("already")||m.includes("registered")?"الحساب مفعّل مسبقًا. استخدم «تسجيل الدخول».":"تعذر تفعيل الحساب. تأكد أن البريد ضمن الفريق المعتمد.";','loginMsg.textContent=displayText(m.includes("already")||m.includes("registered")?"الحساب مفعّل مسبقًا. استخدم «تسجيل الدخول».":"تعذر تفعيل الحساب. تأكد أن البريد ضمن الفريق المعتمد.");')

# Translate simple dynamic role/performance labels.
s=s.replace('${esc(ROLE_LABEL[x.user?.role]||x.user?.role||"")}','${esc(displayText(ROLE_LABEL[x.user?.role]||x.user?.role||""))}')
s=s.replace('>النتيجة: <b>','>${displayText("النتيجة")}: <b>')
s=s.replace("||'<div class=\"muted\">لا توجد بيانات أداء بعد.</div>'","||`<div class=\"muted\">${displayText('لا توجد بيانات أداء بعد.')}</div>`")

# Harden CSV export against spreadsheet formula injection while preserving numeric amount export.
old="function csvCell(v){return `\"${String(v??'').replace(/\"/g,'\"\"')}\"`}"
new="function csvCell(v){let x=String(v??'');if(/^[=+@-]/.test(x)&&!/^-[0-9.,]+$/.test(x))x=\"'\"+x;return `\"${x.replace(/\"/g,'\"\"')}\"`}"
if old in s: s=s.replace(old,new,1)

# Final invariants.
required=['id="authLangBtn"','id="langBtn"','BILINGUAL_EXTENSIONS_APPLIED','function openPaymentReport()','function exportPaymentReportCsv()','function printPaymentReport()','function copyPaymentReportEmailSummary()','paymentReportBtn.classList.toggle','audit_log_actor_id_fkey','negative-amount']
missing=[x for x in required if x not in s]
if missing: raise SystemExit(f'missing bilingual/report invariant: {missing}')
if '${moneyHtml(n)}' in s: raise SystemExit('recursive formatter regression')
if 'addEventListener("click",openBankModal)' in s: raise SystemExit('duplicate bank listener regression')
p.write_text(s,encoding='utf-8')
