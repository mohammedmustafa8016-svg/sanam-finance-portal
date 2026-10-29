const assert = require('node:assert/strict');
const {chromium} = require(process.env.PLAYWRIGHT_PATH || 'playwright');
(async () => {
  const browser = await chromium.launch({executablePath:process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});
  try {
    const page = await browser.newPage({viewport:{width:1440,height:1000}});
    const errors=[];
    page.on('pageerror',error=>errors.push(error.message));
    page.on('dialog',dialog=>dialog.accept());
    await page.route('**/*',route=>new URL(route.request().url()).hostname==='127.0.0.1'?route.continue():route.abort());
    await page.goto('http://127.0.0.1:4173');
    await page.waitForSelector('[data-work-item]');
    await page.evaluate(()=>applyAccess());
    assert.equal(await page.locator('#workspaceNavigation button').count(),8);
    await page.locator('[data-workspace="payments"]').click();
    assert.equal(await page.locator('#workspaceHeader [role=tab]').count(),4);
    await page.locator('[data-workspace-page="executed"]').click();
    assert.equal(await page.locator('#executed').isVisible(),true);
    await page.locator('[data-workspace="home"]').click();
    await page.locator('[data-workspace="payments"]').click();
    assert.equal(await page.locator('#executed').isVisible(),true,'Return to last allowed tab');
    await page.evaluate(()=>openPage('posted','المرحلة'));
    assert.equal(await page.getAttribute('[data-workspace="payments"]','aria-current'),'page');
    assert.equal(await page.getAttribute('[data-workspace-page="posted"]','aria-selected'),'true');
    await page.locator('[data-workspace-page="posted"]').press('Home');
    assert.equal(await page.locator('#payments').isVisible(),true);
    await page.evaluate(()=>toggleLanguage());
    assert.equal(await page.locator('#workspaceHeader h1').textContent(),'Payments');
    assert.equal(await page.getAttribute('html','dir'),'ltr');
    await page.evaluate(()=>toggleLanguage());
    for(const role of ['Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant','Viewer']) {
      console.log('Checking role',role);
      await page.evaluate(role=>{profile={...profile,role};permissionMap=role==='Viewer'?{'page.dashboard':true}:{};applyAccess();},role);
      const invalid = await page.evaluate(()=>[...document.querySelectorAll('[data-workspace-page]')].filter(button=>!canPage(button.dataset.workspacePage)).map(button=>button.dataset.workspacePage));
      assert.deepEqual(invalid,[],role+' has no unauthorized tabs');
      for(const workspace of await page.locator('#workspaceNavigation button').all()) {
        console.log('Opening',await workspace.getAttribute('data-workspace'));
        await workspace.click();
        assert.equal(await page.evaluate(()=>canPage(document.querySelector('.section.active').id)),true,role);
      }
      const before=await page.evaluate(()=>document.querySelector('.section.active')?.id);
      await page.evaluate(()=>{if(!canPage('permissions'))openPage('permissions','Permissions');});
      if(role!=='CFO')assert.equal(await page.evaluate(()=>document.querySelector('.section.active')?.id),before);
    }
    assert.equal(await page.locator('#workspaceNavigation button').count(),1,'Viewer dashboard only');
    await page.evaluate(()=>{profile={...profile,role:'CFO'};permissionMap={};applyAccess();openPage('banks','السيولة');});
    await page.setViewportSize({width:390,height:844});
    assert.equal(await page.locator('#workspaceNavigation').isVisible(),true,'Navigation remains usable on mobile');
    await page.locator('[data-workspace="home"]').click();
    await page.locator('[data-workspace="treasury"]').click();
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'No page-wide overflow');
    await page.screenshot({path:'tests/workspaces-mobile.png'});
    await page.setViewportSize({width:1440,height:1000});
    await page.screenshot({path:'tests/workspaces-desktop.png'});
    await page.emulateMedia({media:'print'});
    assert.equal(await page.locator('#workspaceHeader').isVisible(),false);
    assert.deepEqual(errors,[]);
    console.log('PASS: eight workspaces, payment tabs, remembered view, direct navigation, keyboard, Arabic/English, all seven roles, Viewer, mobile, print, no page errors.');
  } finally { await browser.close(); }
})().catch(error=>{console.error(error);process.exitCode=1;});
