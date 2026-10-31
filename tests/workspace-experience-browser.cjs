const assert=require('node:assert/strict');
const {chromium}=require(process.env.PLAYWRIGHT_PATH||'playwright');
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.CHROME_PATH||'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});
 try {
  const page=await browser.newPage({viewport:{width:1440,height:1000}}),errors=[];
  page.on('pageerror',e=>errors.push(e.message));page.on('dialog',d=>d.accept());
  await page.route('**/*',r=>new URL(r.request().url()).hostname==='127.0.0.1'?r.continue():r.abort());
  await page.goto('http://127.0.0.1:4173');await page.waitForSelector('[data-work-item]');
  await page.evaluate(()=>{
   banks=[{id:'b1',company:'Sanam',bank_name:'Alpha Bank',account_name:'Operations',account_type:'Operational',account_no:'SA1234',balance:120000,reserved_balance:10000,available_balance:110000},{id:'b2',company:'Sanam',bank_name:'Beta Bank',account_name:'Reserve',account_type:'Working Capital Reserve',balance:30000,reserved_balance:0,available_balance:30000}];bankDirectory=banks;
   payments=[{id:'p1',company:'Sanam',beneficiary:'Vendor Alpha',amount:1000,due_date:'2026-11-01',bank_account_id:'b1',status:'بانتظار مراجعة المشرف',supervisor_status:'معلق',cfo_status:'معلق',documents_status:'ناقصة'},{id:'p2',company:'Sanam',beneficiary:'Vendor Beta',amount:2000,due_date:'2026-11-02',bank_account_id:'b1',status:'منفذ',supervisor_status:'موافق',cfo_status:'موافق',executed_at:'2026-10-30T10:00:00Z'},{id:'p3',company:'Sanam',beneficiary:'Vendor Gamma',amount:3000,bank_account_id:'b1',status:'مرحّل',executed_at:'2026-10-29T10:00:00Z',posted_at:'2026-10-30T10:00:00Z'}];
   closeTasks=[{id:'c1',name:'Bank reconciliation',track:'Treasury',code:'C01',owner_id:profile.id,owner:{full_name:'Finance owner'},close_period:'2026-10',due_date:'2026-11-01',planned_start_date:'2026-10-01',status:'لم يبدأ',release_status:'Planned',progress:0},{id:'c2',name:'AP reconciliation',track:'AP',code:'C02',close_period:'2026-10',due_date:'2026-11-02',status:'مكتمل',progress:100,release_status:'Completed'}];
   imprest=[{id:'i1',name:'Site Alpha',type:'دائمة',company:'Sanam',custodian:{full_name:'Custodian'},balance:5000,unsettled:1000,aging:10,status:'نشطة'}];
   performance=[{user_id:profile.id,full_name:'Finance owner',role:'CFO',today_total:5,today_completed:3,month_completion_rate:80,tracked_on_time_rate:90}];
   ownership=[{process:'Bank control',activity:'Bank reconciliation',owner_name:'Finance owner',reviewer_name:'Supervisor'}];
   renderBanks();renderPayments();renderExecutedPayments();renderClose();renderImprest();renderPerformance();renderOwnership();applyAccess();openPage('banks','Banks');
  });
  await page.waitForSelector('[data-table-view^="banks."]');
  const tools=page.locator('[data-table-view^="banks."]'),search=tools.locator('input[type=search]');
  assert.equal(await page.locator('#banks .experience-metrics b').first().textContent(),'2');
  assert.equal(await page.locator('#banksBody tr').count(),2);
  await search.fill('Alpha');await page.waitForFunction(()=>document.querySelectorAll('#banksBody tr:not(.experience-filtered-row)').length===1);
  assert.match(await tools.locator('.experience-count').textContent(),/^1 \/ 2/);
  await tools.locator('input:not([type=search])').fill('حساب التشغيل');await tools.getByRole('button',{name:'حفظ البحث',exact:true}).click();
  assert.equal(await tools.locator('.experience-view').count(),1);
  await tools.getByRole('button',{name:'مسح البحث',exact:true}).click();assert.equal(await page.locator('#banksBody tr:not(.experience-filtered-row)').count(),2);
  await tools.getByRole('button',{name:'حساب التشغيل',exact:true}).click();assert.equal(await search.inputValue(),'Alpha');
  // A native filter remains authoritative; clearing our search must not reveal its hidden row.
  await page.evaluate(()=>document.querySelector('#banksBody tr').style.display='none');
  await tools.getByRole('button',{name:'مسح البحث',exact:true}).click();
  assert.equal(await page.locator('#banksBody tr').first().isVisible(),false);
  await page.evaluate(()=>renderBanks());await search.fill('no-such-bank');await page.waitForSelector('#banks .experience-search-empty:not([hidden])');
  await page.evaluate(()=>renderBanks());assert.equal(await search.inputValue(),'no-such-bank','Rerender preserves the current view');
  await tools.getByRole('button',{name:'مسح البحث',exact:true}).click();
  await page.evaluate(()=>{const cell=document.querySelector('#banksBody tr td');cell.dataset.original=cell.textContent;cell.textContent='HIDDEN-SENSITIVE-COLUMN';cell.classList.add('hidden');});
  await search.fill('HIDDEN-SENSITIVE-COLUMN');
  assert.equal(await page.locator('#banksBody tr:not(.experience-filtered-row)').count(),0,'Hidden columns cannot be inferred from search results');
  await page.evaluate(()=>{const cell=document.querySelector('#banksBody tr td');cell.textContent=cell.dataset.original;cell.classList.remove('hidden');});
  await tools.getByRole('button',{name:'مسح البحث',exact:true}).click();
  await page.evaluate(()=>{banks.push({id:'b3',company:'Sanam',bank_name:'<img src=x onerror=alert(1)>',account_name:'Safe text',account_type:'Operational',balance:1});renderBanks();});
  await page.waitForFunction(()=>document.querySelector('#banks .experience-metrics b').textContent==='3');
  assert.equal(await page.locator('#banksBody img').count(),0,'Business text remains escaped');
  await page.locator('#addBankBtn').click();assert.match(await page.locator('#modalTitle').textContent(),/حساب/);await page.evaluate(()=>closeModal());
  const domainPages=['payments','executed','pending','posted','close','imprest','performance','ownership','exceptions','permissions','automation','audit','reservev2'];
  for(const id of domainPages){await page.evaluate(id=>openPage(id,id),id);await page.waitForSelector('#'+id+' .experience-intro');assert.equal(await page.locator('#'+id+' .experience-intro').isVisible(),true,id+' context');}
  await page.evaluate(()=>openPage('close','Close'));await page.locator('#addCloseBtn').click();assert.match(await page.locator('#modalTitle').textContent(),/إقفال/);await page.evaluate(()=>closeModal());
  await page.evaluate(()=>openPage('imprest','Imprest'));await page.locator('#addImprestBtn').click();assert.match(await page.locator('#modalTitle').textContent(),/عهدة/);await page.evaluate(()=>closeModal());
  // Recheck controls against all seven actual page guards, not a new role map.
  for(const role of ['CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant','Viewer']){
   await page.evaluate(role=>{profile={...profile,id:'ux-'+role,role};permissionMap=role==='Viewer'?{'page.dashboard':true}:{};applyAccess();},role);
   for(const id of ['banks','payments','close','imprest','performance','permissions']){
    const allowed=await page.evaluate(id=>canPage(id),id);
    await page.evaluate(id=>openPage(id,id),id);
    if(allowed){assert.equal(await page.locator('#'+id).isVisible(),true,role+' '+id);await page.waitForFunction(id=>!document.querySelector('#'+id+' .experience-intro')?.hidden,id);}
    else assert.equal(await page.locator('#'+id).isVisible(),false,role+' cannot open '+id);
   }
   if(role==='Viewer')assert.equal(await page.locator('.experience-table-tools:visible').count(),0);
  }
  await page.evaluate(()=>{profile={...profile,id:'ux-other-CFO',role:'CFO'};permissionMap={};applyAccess();openPage('banks','Banks');});
  await page.waitForFunction(()=>document.querySelector('[data-table-view^="banks."] input[type=search]').value==='');
  assert.equal(await tools.locator('.experience-view').count(),0,'Views do not cross users');
  await page.evaluate(()=>{profile={...profile,id:fixturePeople[0].id};applyAccess();openPage('banks','Banks');});
  await page.waitForFunction(()=>document.querySelectorAll('[data-table-view^="banks."] .experience-view').length===1);
  await tools.getByRole('button',{name:'حساب التشغيل',exact:true}).click();assert.equal(await search.inputValue(),'Alpha','Explicit view retained for its owner');
  await tools.getByRole('button',{name:'مسح البحث',exact:true}).click();
  await page.evaluate(()=>toggleLanguage());assert.equal(await search.getAttribute('aria-label'),'Search this table');assert.match(await page.locator('#banks .experience-intro').textContent(),/Treasury position/);
  for(const theme of ['light','dark']){
   await page.evaluate(theme=>{document.documentElement.dataset.theme=theme;},theme);
   for(const id of ['banks','payments','close','imprest','performance','permissions']){
    await page.evaluate(id=>openPage(id,id),id);await page.setViewportSize({width:390,height:844});
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),theme+' '+id+' has no page overflow');
   }
  }
  await page.evaluate(()=>{document.documentElement.dataset.theme='light';toggleLanguage();openPage('payments','Payments');});
  await page.setViewportSize({width:1440,height:1000});await page.screenshot({path:'tests/redesign-payments-desktop.png'});
  await page.evaluate(()=>openPage('close','Close'));await page.screenshot({path:'tests/redesign-close-desktop.png'});
  await page.evaluate(()=>openPage('imprest','Imprest'));await page.screenshot({path:'tests/redesign-imprest-desktop.png'});
  await page.evaluate(()=>openPage('banks','Banks'));await page.setViewportSize({width:390,height:844});await page.screenshot({path:'tests/redesign-treasury-mobile.png'});
  await page.emulateMedia({media:'print'});assert.equal(await tools.isVisible(),false);assert.equal(await page.locator('#banks .experience-intro').isVisible(),false);
  assert.deepEqual(errors,[]);console.log('PASS: domain redesign, real renderers and forms, search/native filter coexistence, rerender, escaped values, saved view identity isolation, all seven roles, Arabic/English, dark/light mobile and print.');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
