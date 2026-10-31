const assert=require('node:assert/strict');
const {chromium}=require(process.env.PLAYWRIGHT_PATH||'playwright');
(async()=>{const browser=await chromium.launch({executablePath:process.env.CHROME_PATH||'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});try{
 const page=await browser.newPage({viewport:{width:1600,height:1000}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/*',r=>new URL(r.request().url()).hostname==='127.0.0.1'?r.continue():r.abort());
 await page.goto('http://127.0.0.1:4173');await page.waitForSelector('[data-work-item]');
 await page.evaluate(()=>{profile={...profile,role:'Supervisor'};payments=[{id:'design-selected',company:'شركة سنام العالمية',beneficiary:'مورد تجريبي',amount:18000,status:'معلقة',pending_amount:3000,registered_amount:15000,pending_type:'PARTIAL',purpose:'دفعة أعمال معتمدة',executed_at:'2026-10-29T07:00:00Z',accounting_registered_at:'2026-10-29T09:00:00Z',updated_at:'2026-10-31T08:00:00Z'}];applyAccess();renderPayments();openPage('pending','المعلقة');});
 assert.equal(await page.locator('[data-workspace-page=reservev2]').count(),0);
 await page.locator('#pfCommand').click();await page.locator('#pfSearchInput').fill('المعلقة');assert.equal(await page.locator('#pfSearchResults button').count(),1);await page.locator('#pfSearchResults button').click();
 await page.locator('[data-pf-detail=design-selected]').click();
 assert.match(await page.locator('#pending .pf-decision').textContent(),/مورد تجريبي/);
 assert.equal(await page.locator('#pending .pf-decision [data-pending-resume]').count(),1,'Uses the authoritative stage-specific action builder');
 assert.equal(await page.evaluate(()=>payments[0].pending_amount),3000,'Selection never changes financial data');
 for(const theme of ['light','dark']){await page.evaluate(theme=>document.documentElement.dataset.theme=theme,theme);await page.waitForTimeout(200);await page.screenshot({path:`tests/precision-flow-${theme}.png`});}
 await page.evaluate(()=>{profile={...profile,role:'BankAccountant'};applyAccess();});
 assert.equal(await page.locator('#pending .pf-decision [data-pending-resume]').count(),0,'Role change refreshes decision actions');
 await page.evaluate(()=>{profile={...profile,id:'another-session',role:'Supervisor'};applyAccess();});
 assert.equal(await page.locator('#pending .pf-decision [data-pending-resume]').count(),0,'User change clears selected transaction');
 await page.locator('#pfCommand').click();await page.locator('#pfSearchInput').fill('سجل التدقيق');assert.equal(await page.locator('#pfSearchResults button').count(),0,'Quick navigation excludes unauthorized pages');await page.evaluate(()=>closeModal());
 await page.evaluate(()=>toggleLanguage());assert.match(await page.locator('#pending .pf-decision').textContent(),/Decision space/);
 await page.setViewportSize({width:390,height:844});assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));await page.screenshot({path:'tests/precision-flow-mobile.png',fullPage:true});
 await page.emulateMedia({media:'print'});assert.equal(await page.locator('#pending .pf-decision').isVisible(),false);assert.deepEqual(errors,[]);
 console.log('PASS: unified identity, existing guarded actions, immutable selection, role/session refresh, light/dark, Arabic/English, mobile and print.');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
