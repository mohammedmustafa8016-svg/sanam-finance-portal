const assert=require('node:assert/strict');
const {chromium}=require(process.env.PLAYWRIGHT_PATH||'playwright');
const expected={
 CFO:['audit','automation','banks','close','dashboard','exceptions','executed','imprest','ownership','payments','pending','performance','permissions','posted','reservev2','workcenter'],
 Supervisor:['automation','banks','close','dashboard','exceptions','executed','imprest','ownership','payments','pending','performance','posted','reservev2','workcenter'],
 BankAccountant:['banks','close','dashboard','exceptions','executed','imprest','payments','pending','posted','workcenter'],
 GLAccountant:['close','dashboard','exceptions','executed','payments','pending','posted','workcenter'],
 ARAccountant:['close','dashboard','exceptions','performance','workcenter'],
 APAccountant:['close','dashboard','exceptions','executed','imprest','payments','performance','posted','workcenter'],
 Viewer:['dashboard']
};
const emails={CFO:'cfo@local.invalid',Supervisor:'supervisor@local.invalid',BankAccountant:'bank.accountant@local.invalid',GLAccountant:'gl.accountant@local.invalid',ARAccountant:'ar.accountant@local.invalid',APAccountant:'ap.accountant@local.invalid',Viewer:'viewer@local.invalid'};
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.CHROME_PATH||undefined,headless:true});
 const page=await browser.newPage({viewport:{width:1440,height:1000}});
 const pageErrors=[];page.on('pageerror',e=>pageErrors.push(e.message));page.on('dialog',d=>d.accept());
 await page.route('**/*',r=>new URL(r.request().url()).hostname==='127.0.0.1'?r.continue():r.abort());
 await page.goto('http://127.0.0.1:4174');
 await page.waitForSelector('#authScreen:not(.hidden)');
 // Client-side validation.
 await page.locator('#loginPassword').fill('UiTest123!');
 await page.locator('#loginBtn').click();assert.match(await page.textContent('#loginMsg'),/أدخل بريد العمل/);
 await page.locator('#loginEmail').fill('cfo@local.invalid');await page.locator('#loginPassword').fill('short1');await page.locator('#loginBtn').click();assert.match(await page.textContent('#loginMsg'),/8 خانات/);
 await page.locator('#loginPassword').fill('12345678');await page.locator('#loginBtn').click();assert.match(await page.textContent('#loginMsg'),/حروف وأرقام/);
 await page.locator('#loginEmail').fill('unknown@local.invalid');await page.locator('#loginPassword').fill('UiTest123!');await page.locator('#loginBtn').click();await page.waitForFunction(()=>document.getElementById('loginMsg').textContent.includes('تعذر تسجيل الدخول'));assert.match(await page.textContent('#loginMsg'),/تحقق من البريد وكلمة المرور/);

 const visibleNav=()=>page.locator('.nav:not(.hidden)').evaluateAll(xs=>xs.filter(x=>getComputedStyle(x).display!=='none').map(x=>x.dataset.page).sort());
 async function login(role){
  await page.locator('#loginEmail').fill(emails[role]);await page.locator('#loginPassword').fill('UiTest123!');await page.locator('#loginBtn').click();
  await page.waitForSelector('#app:not(.hidden)');
  await page.waitForFunction(r=>typeof profile!=='undefined'&&profile?.role===r,role);
  assert.equal(await page.evaluate(()=>profile.role),role,role+' profile role');
  assert.deepEqual(await visibleNav(),expected[role],role+' navigation');
  assert.match(await page.textContent('#userRole'),role==='Viewer'?/مطلع تجريبي/:/.+/);
 }
 async function logout(){await page.locator('#logoutBtn').click();await page.waitForSelector('#authScreen:not(.hidden)');}

 await login('CFO');
 await page.waitForSelector('#wcRows');assert.equal(await page.locator('#wcScopeWrap').isVisible(),true);assert.equal(await page.locator('#wcAddTaskBtn').isVisible(),true);assert.equal(await page.locator('#addExceptionBtn').isVisible(),true);
 // Work Center service failure and recovery.
 await page.evaluate(async()=>{window.fixtureWorkCenterError=true;await loadWorkCenter()});assert.equal(await page.locator('#wcError').isVisible(),true);assert.match(await page.textContent('#wcError'),/تعذر تحميل مركز العمل/);
 await page.evaluate(async()=>{window.fixtureWorkCenterError=false;await loadWorkCenter()});assert.equal(await page.locator('#wcError').isVisible(),false);
 await logout();

 await login('Supervisor');await page.waitForSelector('#wcRows');assert.equal(await page.locator('#wcScopeWrap').isVisible(),true);assert.equal(await page.locator('#wcAddTaskBtn').isVisible(),true);assert.equal(await page.locator('#addExceptionBtn').isVisible(),false);await logout();

 await login('BankAccountant');await page.waitForSelector('#wcRows');assert.equal(await page.locator('#wcScopeWrap').isVisible(),false);assert.equal(await page.locator('#wcAddTaskBtn').isVisible(),false);assert.equal(await page.locator('#addBankBtn').isVisible(),true);assert.equal(await page.locator('#addPaymentBtn').isVisible(),true);
 const activeBefore=await page.locator('.section.active').getAttribute('id');await page.evaluate(()=>openPage('audit','Audit'));assert.equal(await page.locator('.section.active').getAttribute('id'),activeBefore,'Unauthorized direct page open must be blocked');await logout();

 await login('GLAccountant');await page.waitForSelector('#wcRows');assert.equal(await page.locator('#addPaymentBtn').isVisible(),false);assert.equal(await page.locator('#addBankBtn').isVisible(),false);await logout();
 await login('ARAccountant');await page.waitForSelector('#wcRows');assert.equal(await page.locator('#addPaymentBtn').isVisible(),false);assert.equal(await page.locator('#addImprestBtn').isVisible(),false);await logout();
 await login('APAccountant');await page.waitForSelector('#wcRows');assert.equal(await page.locator('#addPaymentBtn').isVisible(),true);assert.equal(await page.locator('#addImprestBtn').isVisible(),true);assert.equal(await page.locator('#addBankBtn').isVisible(),false);await logout();

 await login('Viewer');assert.equal(await page.locator('#headerNotificationsBtn').isVisible(),false);assert.equal(await page.locator('#readonlyDashboardFilters').isVisible(),true);assert.equal(await page.locator('#workcenter').isVisible(),false);await logout();

 assert.deepEqual(pageErrors,[]);
 console.log('PASS: login validation, invalid credentials, CFO/Supervisor/Bank/GL/AR/AP/Viewer navigation, action visibility, unauthorized page guard, Work Center error/recovery, logout. No page errors.');
 await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
