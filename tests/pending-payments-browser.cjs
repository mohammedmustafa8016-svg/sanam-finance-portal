const assert=require('node:assert/strict');const {chromium}=require(process.env.PLAYWRIGHT_PATH||'playwright');
(async()=>{const browser=await chromium.launch({executablePath:process.env.CHROME_PATH||'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});try{
 const page=await browser.newPage({viewport:{width:1440,height:1000}}),errors=[];page.on('pageerror',e=>errors.push(e.message));page.on('dialog',d=>d.accept());
 await page.route('**/*',r=>new URL(r.request().url()).hostname==='127.0.0.1'?r.continue():r.abort());await page.goto('http://127.0.0.1:4173');await page.waitForSelector('[data-work-item]');
 await page.evaluate(()=>{
  const base=sb.rpc.bind(sb);window.pendingCalls=[];window.pendingError=false;
  payments=[{id:'held-pre',company:'Sanam',beneficiary:'Pre registration',amount:1000,pending_amount:1000,registered_amount:0,pending_type:'FULL',status:'معلقة',executed_at:'2026-10-30T10:00:00Z',updated_at:'2026-10-31T11:00:00.123456Z',pending_reason:'Missing invoice',pending_details:'Source document required'},
   {id:'held-post',company:'Sanam',beneficiary:'Post registration',amount:1000,pending_amount:300,registered_amount:700,pending_type:'PARTIAL',status:'معلقة',executed_at:'2026-10-30T10:00:00Z',accounting_registered_at:'2026-10-30T12:00:00Z',accounting_registered_by:'original-gl',updated_at:'2026-10-31T11:00:00.654321Z',pending_reason:'Invoice mismatch',pending_details:'Correct the supplier reference',pending_owner_id:fixturePeople[2].id}];
  reloadAll=async()=>{renderPayments();renderExecutedPayments();};
  sb.rpc=async(name,p={})=>{
   if(['resume_pending_payment','get_pending_payment_history','update_pending_payment_followup'].includes(name))pendingCalls.push({name,p});else return base(name,p);
   if(name==='resume_pending_payment'){
    if(pendingError)return {error:{message:'PENDING_STALE_RECORD_REFRESH'}};
    if(window.deferPending)await new Promise(resolve=>window.releasePending=resolve);
    const row=payments.find(x=>x.id===p.p_payment_id);row.status='تم التسجيل';row.pending_amount=0;row.registered_amount=row.amount;row.pending_resolution_note=p.p_resolution_note;return {data:{...row}};
   }
   if(name==='update_pending_payment_followup')return {data:{}};
   return {data:[{id:'event-1',action:'PAYMENT_PENDING_RESOLVED',actor_name:'Supervisor',created_at:'2026-10-31T12:00:00Z',details:{previous_pending_amount:300,resolution_note:'<img src=x onerror=alert(1)> Source verified'}}]};
  };
  profile={...profile,role:'Supervisor'};applyAccess();renderPayments();openPage('pending','العمليات المعلقة');
 });
 assert.equal(await page.locator('[data-pending-resume="held-pre"]').count(),0,'Supervisor cannot perform initial GL registration');
 assert.equal(await page.locator('[data-pending-resume="held-post"]').count(),1,'Supervisor can release registered hold');
 const actionBox=await page.locator('[data-pending-resume="held-post"]').boundingBox();assert.ok(actionBox.x>=0&&actionBox.x+actionBox.width<=1441,'Action remains visible without horizontal scrolling');
 assert.equal(await page.locator('[data-pending-followup]').count(),2);
 await page.locator('[data-pending-resume="held-post"]').click();assert.match(await page.locator('#modalTitle').textContent(),/بعد التسجيل/);
 await page.locator('#pendingFlowSave').click();assert.equal(await page.evaluate(()=>pendingCalls.filter(c=>c.name==='resume_pending_payment').length),0);assert.match(await page.locator('#pendingFlowError').textContent(),/10/);
 await page.locator('#pend_resolution_note').fill('Corrected invoice received and verified');await page.evaluate(()=>pendingError=true);await page.locator('#pendingFlowSave').click();await page.waitForSelector('#pendingFlowError:not([hidden])');assert.match(await page.locator('#pendingFlowError').textContent(),/تغيّرت العملية/);assert.equal(await page.locator('#pendingFlowSave').isEnabled(),true);
 await page.evaluate(()=>{pendingError=false;deferPending=true;});
 const before=await page.evaluate(()=>pendingCalls.filter(c=>c.name==='resume_pending_payment').length);
 await page.evaluate(()=>{resolvePendingPayment('held-post');resolvePendingPayment('held-post');});
 await page.waitForFunction(()=>typeof window.releasePending==='function');assert.equal(await page.evaluate(()=>pendingCalls.filter(c=>c.name==='resume_pending_payment').length),before+1,'Double submission is blocked');
 const sent=await page.evaluate(()=>pendingCalls.filter(c=>c.name==='resume_pending_payment').at(-1).p);assert.equal(sent.p_expected_updated_at,'2026-10-31T11:00:00.654321Z','Version precision is preserved');
 await page.evaluate(()=>releasePending());await page.waitForSelector('#pendingResumeFeedback');assert.equal(await page.locator('#executed').isVisible(),true);
 assert.equal(await page.evaluate(()=>payments.find(x=>x.id==='held-post').accounting_registered_by),'original-gl');
 assert.equal(await page.evaluate(()=>payments.find(x=>x.id==='held-post').posted_at),undefined,'Resume does not auto-post');
 assert.equal(await page.evaluate(()=>fixtureCalls.some(c=>c.name==='execute_payment'||c.name==='supervisor_finalize_registered_payment')),false);
 await page.evaluate(()=>{const row=payments.find(x=>x.id==='held-post');row.status='معلقة';row.pending_amount=300;row.registered_amount=700;renderPayments();openPage('pending','العمليات المعلقة');});
 await page.locator('[data-pending-followup="held-post"]').click();await page.locator('#pendingFollowAction').fill('Obtain corrected supplier invoice');await page.locator('#pendingFollowOwner').selectOption(await page.evaluate(()=>fixturePeople[2].id));await page.locator('#pendingFollowDate').fill('2026-12-01');await page.locator('#pendingFollowNote').fill('Assigned to follow source correction');await page.locator('#pendingFlowSave').click();await page.waitForFunction(()=>pendingCalls.some(c=>c.name==='update_pending_payment_followup'));
 assert.equal(await page.evaluate(()=>payments.find(x=>x.id==='held-post').pending_amount),300,'Follow-up does not release money');
 await page.locator('[data-pending-history="held-post"]').click();await page.waitForSelector('#pendingHistory article');assert.equal(await page.locator('#pendingHistory img').count(),0);assert.match(await page.locator('#pendingHistory').textContent(),/300/);await page.evaluate(()=>closeModal());
 for(const role of ['CFO','Supervisor','GLAccountant','BankAccountant','APAccountant','ARAccountant','Viewer']){
  await page.evaluate(role=>{profile={...profile,role};permissionMap=role==='Viewer'?{'page.dashboard':true}:{};applyAccess();renderPayments();if(canPage('pending'))openPage('pending','Pending');},role);
  const pre=await page.locator('[data-pending-resume="held-pre"]').count(),post=await page.locator('[data-pending-resume="held-post"]').count();
  assert.equal(pre,role==='GLAccountant'?1:0,role+' pre-stage action');assert.equal(post,['CFO','Supervisor'].includes(role)?1:0,role+' post-stage action');
  if(role==='Viewer'||role==='ARAccountant')assert.equal(await page.locator('[data-pending-history]').count(),0);
 }
 await page.evaluate(()=>{profile={...profile,role:'Supervisor'};permissionMap={};applyAccess();renderPayments();openPage('pending','Pending');toggleLanguage();});
 assert.match(await page.locator('[data-pending-resume="held-post"]').textContent(),/Release hold/);
 await page.screenshot({path:'tests/pending-supervisor-desktop.png'});
 await page.setViewportSize({width:390,height:844});const mobileAction=await page.locator('[data-pending-resume="held-post"]').boundingBox();assert.ok(mobileAction.x>=0&&mobileAction.x+mobileAction.width<=391,'Sticky action remains in the mobile viewport');
 await page.locator('[data-pending-resume="held-post"]').click();assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));await page.screenshot({path:'tests/pending-resolution-mobile.png'});
 assert.deepEqual(errors,[]);console.log('PASS: supervisor post-hold vs GL pre-hold, all seven roles, exact version/stale recovery, duplicate submission, no auto-post/bank action, follow-up/history, escaped audit notes, English and mobile.');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
