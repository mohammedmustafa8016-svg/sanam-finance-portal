// Run against serve-preview.cjs. Browser fixtures never contact the production API.
const assert=require('node:assert/strict');
const {chromium}=require(process.env.PLAYWRIGHT_PATH||'playwright');
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.CHROME_PATH||'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});
 const page=await browser.newPage({viewport:{width:1440,height:1000}});const errors=[];page.on('pageerror',e=>errors.push(e.message));page.on('dialog',d=>d.accept());
 await page.route('**/*',route=>{if(new URL(route.request().url()).hostname!=='127.0.0.1')return route.abort();return route.continue()});
 await page.goto('http://127.0.0.1:4173');await page.waitForSelector('[data-work-item]');
 assert.equal(await page.getAttribute('#wcTeamBtn','aria-pressed'),'true');
 const rows=()=>page.locator('#workcenterBody [data-work-item]').count();
 for(const [tab,count] of [['execution',3],['reviews',1],['attention',2],['completed',1],['overview',6]]){
   await page.locator(`[data-wctab="${tab}"]`).click();assert.equal(await rows(),count,tab);assert.equal(await page.getAttribute(`[data-wctab="${tab}"]`,'aria-selected'),'true');
 }
 await page.locator('#workcenterSummary button').nth(4).click();assert.equal(await rows(),1);assert.match(await page.textContent('#wcResultCount'),/متأخر/);
 await page.locator('#wcClearMetric').click();await page.locator('#wcBoardBtn').click();assert.equal(await page.locator('.wc-board-card').count(),6);await page.locator('#wcListBtn').click();
 await page.locator('#workcenterBody .wc-title-link').first().click();await page.waitForSelector('#wcDetailActivity .wc-timeline-item');assert.match(await page.textContent('#wcDetailActivity'),/تمت المراجعة الأولية/);await page.keyboard.press('Escape');assert.equal(await page.locator('#wcDetailShell').count(),0);
 await page.locator('#wcMineBtn').click();await page.waitForSelector('.wc-empty');assert.equal(await rows(),0);await page.locator('#wcTeamBtn').click();await page.waitForSelector('[data-work-item]');
 await page.locator('#teamOperationsMonitorBody tr').last().locator('button').nth(1).click();assert.equal(await rows(),2);assert.equal(await page.inputValue('#wcEmployeeFilter'),'00000000-0000-0000-0000-000000000003');
 await page.evaluate(()=>clearWorkCenterFilters());await page.locator('#wcSearch').fill('المورد');await page.waitForFunction(()=>document.querySelectorAll('#workcenterBody tr').length===1);assert.match(await page.textContent('#wcRows'),/المورد/);
 await page.evaluate(()=>clearWorkCenterFilters());await page.evaluate(async()=>{window.fixtureError=true;await loadWorkCenter()});assert.equal(await page.locator('#wcError').isVisible(),true);assert.match(await page.textContent('#wcError'),/تعذر تحميل/);await page.evaluate(async()=>{window.fixtureError=false;await loadWorkCenter()});assert.equal(await page.locator('#wcError').isVisible(),false);
 // Race: an old slower team response must never overwrite the newer personal scope.
 await page.evaluate(async()=>{const real=sb.rpc.bind(sb);sb.rpc=async(n,p)=>{const r=await real(n,p);if(n==='get_workcenter_dashboard_v5'&&p.p_scope==='team')await new Promise(resolve=>setTimeout(resolve,150));return r};workcenterScope='team';const slow=loadWorkCenter();workcenterScope='mine';await loadWorkCenter();await slow;sb.rpc=real;});assert.equal(await rows(),0);
 await page.evaluate(()=>fixtureSetRole('BankAccountant'));await page.waitForSelector('[data-work-item]');assert.equal(await page.locator('#wcScopeWrap').isVisible(),false);assert.equal(await page.locator('#wcAddTaskBtn').isVisible(),false);
 await page.locator('[data-wc-action="START"]').click();await page.waitForFunction(()=>!wcV5.busy);assert.equal(await page.locator('[data-wc-action="START"]').count(),0);
 await page.locator('[data-wc-action="COMPLETE"]').first().click();await page.locator('#wcResultDescription').fill('تمت مطابقة جميع الحركات');await page.locator('#modalBg .btn.primary').click();await page.waitForFunction(()=>!wcV5.busy);await page.locator('[data-wctab="reviews"]').click();assert.equal(await rows(),2);
 await page.evaluate(()=>fixtureSetRole('Supervisor'));await page.locator('[data-wctab="reviews"]').click();await page.locator('[data-wc-action="APPROVE_COMPLETION"]').first().click();
 const callsBefore=await page.evaluate(()=>fixtureCalls.filter(x=>x.name==='try_perform_work_item_action_v5').length);await page.locator('#modalBg .btn.primary').click();assert.equal(await page.evaluate(()=>fixtureCalls.filter(x=>x.name==='try_perform_work_item_action_v5').length),callsBefore,'Blank score must not become zero');
 await page.locator('#wcQualityScore').fill('94');await page.locator('#modalBg .btn.primary').click();await page.waitForFunction(()=>!wcV5.busy);await page.locator('[data-wctab="completed"]').click();assert.equal(await rows(),2);
 await page.evaluate(()=>fixtureSetRole('CFO'));await page.locator('[data-wctab="overview"]').click();await page.screenshot({path:'tests/workcenter-v5-desktop.png'});
 await page.evaluate(()=>toggleLanguage());assert.equal(await page.textContent('#wcSectionTitle'),'Overview');await page.locator('[data-wctab="reviews"]').click();assert.equal(await page.textContent('#wcSectionTitle'),'Reviews & approvals');await page.evaluate(()=>toggleLanguage());
 await page.setViewportSize({width:390,height:844});await page.screenshot({path:'tests/workcenter-v5-mobile.png'});assert.equal(await page.locator('.wc-tabs').isVisible(),true);
 // Clean new cycle must not claim a zero quality score.
 await page.evaluate(async()=>{fixtureItems=[];await loadWorkCenter()});assert.equal(await rows(),0);await page.locator('[data-wctab="overview"]').click();assert.match(await page.textContent('#teamOperationsMonitorBody'),/لا توجد بيانات كافية/);
 assert.deepEqual(errors,[]);console.log('PASS: tabs, counts, drilldowns, board, drawer, scope, search, errors, races, employee start/submit, supervisor score, bilingual, mobile, clean cycle. No page errors.');
 await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});


