(() => {
  if(typeof I18N_AR_EN!=="undefined"){
    Object.assign(I18N_AR_EN,{
      "نسيت كلمة المرور؟":"Forgot password?",
      "إعادة تعيين كلمة المرور":"Reset Password",
      "كلمة المرور الجديدة":"New Password",
      "تأكيد كلمة المرور الجديدة":"Confirm New Password",
      "حفظ كلمة المرور الجديدة":"Save New Password",
      "العودة إلى تسجيل الدخول":"Back to Sign In",
      "أدخل بريد العمل أولًا ثم اضغط «نسيت كلمة المرور؟».":"Enter your work email first, then select “Forgot password?”.",
      "إذا كان البريد مسجلاً فسيتم إرسال رابط آمن لإعادة تعيين كلمة المرور.":"If the email is registered, a secure password-reset link will be sent.",
      "جارٍ إرسال رابط إعادة التعيين...":"Sending password-reset link...",
      "تم طلب رابط إعادة التعيين. تحقق من بريدك الإلكتروني واتبع الرابط الآمن.":"Password reset requested. Check your email and follow the secure link.",
      "تعذر إرسال رابط إعادة التعيين. حاول لاحقًا أو تواصل مع المدير المالي.":"Unable to send the reset link. Try again later or contact the CFO.",
      "أنشئ كلمة مرور جديدة للحساب.":"Create a new password for the account.",
      "كلمتا المرور غير متطابقتين.":"The passwords do not match.",
      "جارٍ حفظ كلمة المرور الجديدة...":"Saving the new password...",
      "تم تغيير كلمة المرور بنجاح. يمكنك الآن تسجيل الدخول بكلمة المرور الجديدة.":"Password changed successfully. You can now sign in with the new password.",
      "تعذر تغيير كلمة المرور. قد يكون رابط الاسترداد منتهي الصلاحية؛ اطلب رابطًا جديدًا.":"Unable to change the password. The recovery link may have expired; request a new one.",
      "إرسال رابط إعادة تعيين":"Send Reset Link",
      "سيتم إرسال رابط آمن إلى بريد المستخدم. المدير المالي لا يرى كلمة المرور ولا يحددها نيابةً عن المستخدم.":"A secure link will be sent to the user. The CFO cannot view the password or set it on the user's behalf.",
      "هل تريد إرسال رابط إعادة تعيين كلمة المرور إلى هذا المستخدم؟":"Send a password-reset link to this user?",
      "تم إرسال طلب إعادة تعيين كلمة المرور إلى بريد المستخدم.":"The password-reset request was sent to the user's email."
    });
  }

  window.passwordRecoveryMode=false;

  function recoveryRedirectUrl(){
    return window.location.origin + window.location.pathname;
  }

  window.isPasswordRecoveryUrl=function(){
    if(typeof PASSWORD_RECOVERY_LINK_DETECTED!=="undefined" && PASSWORD_RECOVERY_LINK_DETECTED)return true;
    try{
      const hash=new URLSearchParams(String(window.location.hash||"").replace(/^#/,""));
      const query=new URLSearchParams(window.location.search||"");
      return hash.get("type")==="recovery" || query.get("type")==="recovery";
    }catch{
      return String(window.location.hash||"").includes("type=recovery");
    }
  };

  function validWorkEmail(email){
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(email||"").trim());
  }

  window.requestPasswordResetFromLogin=async function(){
    const email=String(document.getElementById("loginEmail")?.value||"").trim().toLowerCase();
    const msg=document.getElementById("loginMsg");
    const btn=document.getElementById("forgotPasswordBtn");
    if(!validWorkEmail(email)){
      if(msg)msg.textContent=displayText("أدخل بريد العمل أولًا ثم اضغط «نسيت كلمة المرور؟».");
      return;
    }
    if(btn)btn.disabled=true;
    if(msg)msg.textContent=displayText("جارٍ إرسال رابط إعادة التعيين...");
    try{
      const {error}=await sb.auth.resetPasswordForEmail(email,{redirectTo:recoveryRedirectUrl()});
      if(error)throw error;
      if(msg)msg.textContent=displayText("تم طلب رابط إعادة التعيين. تحقق من بريدك الإلكتروني واتبع الرابط الآمن.");
    }catch(err){
      console.error("Password reset request failed",err);
      if(msg)msg.textContent=displayText("تعذر إرسال رابط إعادة التعيين. حاول لاحقًا أو تواصل مع المدير المالي.");
    }finally{
      if(btn)btn.disabled=false;
    }
  };

  window.showPasswordRecoveryForm=function(){
    window.passwordRecoveryMode=true;
    document.getElementById("authScreen")?.classList.remove("hidden");
    document.getElementById("app")?.classList.add("hidden");
    document.getElementById("loginAuthCard")?.classList.add("hidden");
    document.getElementById("passwordRecoveryCard")?.classList.remove("hidden");
    const p1=document.getElementById("recoveryPassword");
    const p2=document.getElementById("recoveryPasswordConfirm");
    const msg=document.getElementById("recoveryMsg");
    if(p1)p1.value="";
    if(p2)p2.value="";
    if(msg)msg.textContent=displayText("أنشئ كلمة مرور جديدة للحساب.");
    setTimeout(()=>p1?.focus(),0);
    try{applyLanguage(document.getElementById("passwordRecoveryCard"));}catch{}
  };

  function validateNewPassword(password){
    return password.length>=8 && /\p{L}/u.test(password) && /\d/.test(password);
  }

  window.submitRecoveredPassword=async function(){
    const password=document.getElementById("recoveryPassword")?.value||"";
    const confirmPassword=document.getElementById("recoveryPasswordConfirm")?.value||"";
    const msg=document.getElementById("recoveryMsg");
    const btn=document.getElementById("recoverySaveBtn");

    if(!validateNewPassword(password)){
      if(msg)msg.textContent=displayText("كلمة المرور يجب أن تكون 8 خانات على الأقل.");
      return;
    }
    if(password!==confirmPassword){
      if(msg)msg.textContent=displayText("كلمتا المرور غير متطابقتين.");
      return;
    }

    if(btn)btn.disabled=true;
    if(msg)msg.textContent=displayText("جارٍ حفظ كلمة المرور الجديدة...");
    try{
      const {error}=await sb.auth.updateUser({password});
      if(error)throw error;
      window.passwordRecoveryMode=false;
      try{history.replaceState({},document.title,window.location.pathname)}catch{}
      await sb.auth.signOut();
      document.getElementById("passwordRecoveryCard")?.classList.add("hidden");
      document.getElementById("loginAuthCard")?.classList.remove("hidden");
      showAuth();
      const loginMsg=document.getElementById("loginMsg");
      if(loginMsg)loginMsg.textContent=displayText("تم تغيير كلمة المرور بنجاح. يمكنك الآن تسجيل الدخول بكلمة المرور الجديدة.");
    }catch(err){
      console.error("Recovered password update failed",err);
      if(msg)msg.textContent=displayText("تعذر تغيير كلمة المرور. قد يكون رابط الاسترداد منتهي الصلاحية؛ اطلب رابطًا جديدًا.");
    }finally{
      if(btn)btn.disabled=false;
    }
  };

  window.cancelPasswordRecovery=async function(){
    window.passwordRecoveryMode=false;
    try{history.replaceState({},document.title,window.location.pathname)}catch{}
    try{await sb.auth.signOut()}catch{}
    document.getElementById("passwordRecoveryCard")?.classList.add("hidden");
    document.getElementById("loginAuthCard")?.classList.remove("hidden");
    showAuth();
  };

  window.requestPasswordResetForPortalUser=async function(email){
    if(typeof profile==="undefined" || profile?.role!=="CFO")return;
    const normalized=String(email||"").trim().toLowerCase();
    const user=(portalUsers||[]).find(x=>String(x.email||"").toLowerCase()===normalized);
    if(!user || !user.activated)return;
    const promptText=`${displayText("هل تريد إرسال رابط إعادة تعيين كلمة المرور إلى هذا المستخدم؟")}\n\n${user.full_name} — ${user.email}\n\n${displayText("سيتم إرسال رابط آمن إلى بريد المستخدم. المدير المالي لا يرى كلمة المرور ولا يحددها نيابةً عن المستخدم.")}`;
    if(!confirm(promptText))return;

    try{
      const audit=await sb.rpc("cfo_log_password_reset_request",{p_email:normalized});
      if(audit.error)throw audit.error;
      const {error}=await sb.auth.resetPasswordForEmail(normalized,{redirectTo:recoveryRedirectUrl()});
      if(error)throw error;
      alert(displayText("تم إرسال طلب إعادة تعيين كلمة المرور إلى بريد المستخدم."));
    }catch(err){
      console.error("CFO password reset request failed",err);
      alert(displayText("تعذر إرسال رابط إعادة التعيين. حاول لاحقًا أو تواصل مع المدير المالي."));
    }
  };
})();
