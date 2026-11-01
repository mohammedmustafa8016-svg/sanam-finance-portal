const assert=require('node:assert/strict');const {chromium}=require(process.env.PLAYWRIGHT_PATH||'playwright');
(async()=>{const b=await chromium.launch({executablePath:process.env.CHROME_PATH||'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});try{const p=await b.newPage({viewport:{width:1680,height:1120}}),errors=[];p.on('pageerror',e=>errors.push(e.message));await p.route('**/*',r=>new URL(r.request().url()).hostname==='127.0.0.1'?r.continue():r.abort());await p.goto('http://127.0.0.1:4173');await p.waitForSelector('[data-work-item]');await p.evaluate(()=>{applyAccess();openPage('workcenter','مركز العمل');});
 assert.equal(await p.locator('[onclick="openTaskNotifications()"]').count(),1,'Only the header notification control remains');assert.equal(await p.locator('#wcNotificationsBtn,#taskNotificationsBtn').count(),0);
 assert.equal(await p.locator('#workspaceHeader h1').isVisible(),false,'No duplicate large page title');
 assert.equal(await p.locator('.wc-meta #wcWorkdayStatus').count(),1);assert.equal(await p.locator('#wcResults .wc-panel-heading #wcResultCount').count(),1);
 const metrics=await p.locator('#workcenterSummary').boundingBox(),filters=await p.locator('#wcSearch').boundingBox();assert.ok(metrics.y<filters.y,'Approved compact indicators precede work filters');

 for(const theme of ['light','dark']){
  await p.evaluate(theme=>{document.documentElement.dataset.theme=theme;renderThemeControls();},theme);await p.waitForTimeout(200);
  for(const selector of ['#workspaceHeader [aria-selected=true]','#workcenter .wc-tab[aria-selected=true]']){
   const style=await p.locator(selector).evaluate(el=>({color:getComputedStyle(el).color,shadow:getComputedStyle(el).boxShadow,weight:getComputedStyle(el).fontWeight}));
   assert.equal(style.color,theme==='light'?'rgb(136, 20, 63)':'rgb(243, 169, 198)');assert.notEqual(style.shadow,'none');assert.ok(Number(style.weight)>=600);
  }
 }
 for(const mode of [{width:1680,theme:'light',lang:'ar'},{width:1680,theme:'dark',lang:'en'},{width:390,theme:'light',lang:'ar'},{width:390,theme:'dark',lang:'en'}]){
  await p.setViewportSize({width:mode.width,height:1120});
  await p.evaluate(mode=>{if(currentLang!==mode.lang)toggleLanguage();document.documentElement.dataset.theme=mode.theme;renderThemeControls();},mode);
  for(const role of ['CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant','Viewer']){
   await p.evaluate(role=>{profile={...profile,role};permissionMap=role==='Viewer'?{'page.dashboard':true}:{};applyAccess();},role);
   const pages=await p.evaluate(()=>[...document.querySelectorAll('.section')].filter(x=>canPage(x.id)).map(x=>x.id));
   for(const id of pages){
    await p.evaluate(id=>openPage(id,id),id);
    const visible=await p.evaluate(()=>[...document.querySelectorAll('.section')].filter(x=>getComputedStyle(x).display!=='none').map(x=>x.id));
    assert.deepEqual(visible,[id],JSON.stringify(mode)+' '+role+': only the requested page is visible: '+id);
    if(role==='CFO'&&id==='imprest'&&mode.width===1680&&mode.theme==='light')await p.screenshot({path:'tests/imprest-page-isolation.png'});
   }
  }
 }
 await p.setViewportSize({width:1680,height:1120});
 await p.evaluate(()=>{if(currentLang!=='ar')toggleLanguage();});
 await p.evaluate(()=>{profile={...profile,role:'CFO'};permissionMap={};applyAccess();openPage('workcenter','مركز العمل');});
 for(const id of ['payments','executed','pending','posted']){await p.evaluate(id=>openPage(id,id),id);assert.equal(await p.locator('.pf-decision,[data-pf-detail]').count(),0);const section=await p.locator('#'+id).boundingBox(),table=await p.locator('#'+id+' .table-wrap').first().boundingBox();assert.ok(table.width>section.width-45,'Payment table takes the available width: '+id);}
 await p.evaluate(()=>{openPage('workcenter','مركز العمل');document.documentElement.dataset.theme='light';renderThemeControls();document.querySelector('.content').scrollTop=0;});await p.waitForTimeout(200);await p.screenshot({path:'tests/approved-workcenter-light.png'});
 await p.locator('.top [data-theme-toggle]').click();await p.waitForTimeout(200);await p.screenshot({path:'tests/approved-workcenter-dark.png'});
 await p.evaluate(()=>toggleLanguage());assert.equal(await p.locator('[onclick="openTaskNotifications()"]').count(),1);assert.equal(await p.locator('.wc-meta #wcWorkdayStatus').count(),1);assert.equal(await p.locator('#wcResults .wc-panel-heading #wcResultCount').count(),1);await p.evaluate(()=>toggleLanguage());
 await p.locator('#workcenterBody .wc-title-link').first().click();await p.waitForSelector('#wcDetailActivity');await p.keyboard.press('Escape');
 await p.setViewportSize({width:390,height:844});assert.ok(await p.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));await p.screenshot({path:'tests/approved-workcenter-mobile.png',fullPage:true});
 await p.emulateMedia({media:'print'});assert.equal(await p.locator('.top').isVisible(),false);assert.deepEqual(errors,[]);console.log('PASS: every allowed page isolated across seven roles, four desktop/mobile/theme/language modes; approved composition, single notification control, removed decision DOM, full-width payment tables, native controls/drawer, rebuild/language, themes/mobile/print.');
}finally{await b.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
