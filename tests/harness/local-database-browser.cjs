// Uses actual local Auth/PostgREST. Only the HTTP response is configured for
// local Supabase; repository application files are never edited.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const {chromium} = require(process.env.PLAYWRIGHT_PATH || 'playwright');
const root = path.resolve(__dirname, '../..');
const out = path.join(root, 'gate-results');
const api = process.env.LOCAL_SUPABASE_URL;
const anon = process.env.LOCAL_SUPABASE_ANON_KEY;
const service = process.env.LOCAL_SUPABASE_SERVICE_KEY;
const local = u => ['127.0.0.1', 'localhost', '[::1]'].includes(new URL(u).hostname);
assert.ok(local(api), 'Harness must use loopback Supabase');
const password = 'LocalHarness2026!';
const cases = [];
const lifecycle = {name:'create-start-submit-review-delete-preserve-other-task',status:'FAIL',steps:[],pageErrors:[],apiErrors:[],dialogs:[]};

async function localRows(table, query) {
  const response=await fetch(api+'/rest/v1/'+table+'?'+query,
    {headers:{apikey:service,Authorization:'Bearer '+service}});
  assert.ok(response.ok, 'Local database assertion: '+table+' '+response.status);
  return response.json();
}

async function clickRpc(page, name, action) {
  const response=page.waitForResponse(r=>r.url()===api+'/rest/v1/rpc/'+name,{timeout:30000});
  await action();
  const r=await response;
  const data=await r.json();
  assert.ok(r.ok(),name+': '+JSON.stringify(data));
  if(data && typeof data==='object' && 'ok' in data) assert.equal(data.ok,true,JSON.stringify(data));
  await page.waitForFunction(()=>typeof wcV5==='undefined'||!wcV5.busy,null,{timeout:30000});
  return data;
}

async function runLifecycle(browser) {
  const contexts=[];
  let lastPage;
  const people=Object.fromEntries(cases.filter(c=>c.status==='PASS').map(c=>[c.role,c.profile.id]));
  try {
    assert.equal(Object.keys(people).length,3,'Three local identities required');
    const pages={};
    for(const [role,email] of [['CFO','cfo@local.invalid'],['Supervisor','supervisor@local.invalid'],['BankAccountant','bank.accountant@local.invalid']]) {
      const context=await browser.newContext({viewport:{width:1440,height:1000}});
      contexts.push(context);
      await context.route('**/*',route=>local(route.request().url())?route.continue():route.abort());
      const page=await context.newPage(); lastPage=page;
      page.on('pageerror',e=>lifecycle.pageErrors.push({role,message:e.message}));
      page.on('dialog',async d=>{lifecycle.dialogs.push({role,message:d.message()});await d.accept();});
      page.on('response',async r=>{if(r.url().startsWith(api)&&r.status()>=400)
        lifecycle.apiErrors.push({role,url:r.url().replace(api,''),status:r.status(),body:(await r.text()).slice(0,3000)});});
      await page.goto('http://127.0.0.1:4174');
      await page.locator('#loginEmail').fill(email);
      await page.locator('#loginPassword').fill(password);
      await page.locator('#loginBtn').click();
      await page.waitForFunction(()=>profile?.id&&!document.getElementById('app').classList.contains('hidden'));
      await page.waitForSelector('#wcWorkdayBtn');
      pages[role]=page;
    }
    const cfo=pages.CFO, supervisor=pages.Supervisor, employee=pages.BankAccountant;
    // Test preconditions only: use existing CFO APIs on loopback local Supabase.
    const activated=await cfo.evaluate(async()=>{
      const a=await sb.rpc('set_workflow_v3_enabled',{p_enabled:true,p_reason:'Disposable local browser lifecycle'});
      const b=await sb.rpc('set_workcenter_rule_engine_enabled',{p_enabled:true,p_reason:'Disposable local browser lifecycle'});
      return [a.error,b.error];
    });
    assert.deepEqual(activated,[null,null]);
    for(const page of Object.values(pages))
      await clickRpc(page,'start_workday',()=>page.locator('#wcWorkdayBtn').click());

    const due=new Date();due.setUTCDate(due.getUTCDate()+3);
    while([5,6].includes(due.getUTCDay()))due.setUTCDate(due.getUTCDate()+1);
    const create=async name=>{
      lastPage=cfo;
      await cfo.locator('#wcAddTaskBtn').click();
      await cfo.locator('#t_name').fill(name);
      await cfo.locator('#t_owner').selectOption(people.BankAccountant);
      await cfo.locator('#t_reviewer').selectOption(people.Supervisor);
      await cfo.locator('#t_due').fill(due.toISOString().slice(0,10));
      await cfo.locator('#t_due_time').fill('17:00');
      await cfo.locator('#t_frequency').selectOption('حسب الحاجة');
      const id=await clickRpc(cfo,'create_finance_task_v2',()=>cfo.locator('#modalBg .btn.primary').click());
      await cfo.waitForFunction(()=>!document.getElementById('modalBg').classList.contains('show'));
      return id;
    };
    const sentinelId=await create('HARNESS_KEEP_EXISTING_TASK');
    const sentinelBefore=await localRows('tasks','select=*&id=eq.'+sentinelId);
    assert.equal(sentinelBefore.length,1);
    const title='HARNESS_UI_FULL_LIFECYCLE';
    const taskId=await create(title);lifecycle.taskId=taskId;
    const task=async()=>localRows('tasks','select=*&id=eq.'+taskId);
    assert.equal((await task())[0].status,'لم يبدأ');
    lifecycle.steps.push('UI create persisted as ready task');

    const refresh=async(page,tab)=>{
      lastPage=page;
      await page.reload();
      await page.waitForFunction(()=>profile?.id&&!document.getElementById('app').classList.contains('hidden'));
      await page.waitForSelector('#wcRows');
      await page.evaluate(async()=>{openPage('workcenter','Work Center');await loadWorkCenter();});
      await page.locator('[data-wctab="'+tab+'"]').click();
    };
    await refresh(employee,'overview');
    const row=page=>page.locator('#workcenterBody tr[data-work-item]').filter({hasText:title});
    await clickRpc(employee,'try_perform_work_item_action_v5',()=>row(employee).locator('[data-wc-action="START"]').click());
    assert.equal((await task())[0].status,'قيد التنفيذ');
    lifecycle.steps.push('Employee UI start persisted');
    await row(employee).locator('[data-wc-action="COMPLETE"]').click();
    await employee.locator('#wcResultDescription').fill('Validated local browser lifecycle completion result');
    await clickRpc(employee,'try_perform_work_item_action_v5',()=>employee.locator('#modalBg .btn.primary').click());
    assert.equal((await task())[0].status,'بانتظار المراجعة');
    lifecycle.steps.push('Employee UI result submission persisted pending review');
    await employee.screenshot({path:path.join(out,'lifecycle-submitted.png'),fullPage:true});

    await refresh(supervisor,'reviews');
    await row(supervisor).locator('[data-wc-action="APPROVE_COMPLETION"]').click();
    await supervisor.locator('#wcQualityScore').fill('94');
    await supervisor.locator('#wcReviewNote').fill('Verified in disposable local browser');
    await clickRpc(supervisor,'try_perform_work_item_action_v5',()=>supervisor.locator('#modalBg .btn.primary').click());
    const completed=(await task())[0];
    assert.equal(completed.status,'مكتمل');
    assert.equal(Number(completed.quality_score),94);
    lifecycle.steps.push('Supervisor UI approval persisted with quality score 94');

    await refresh(cfo,'completed');
    await row(cfo).locator('.wc-title-link').click();
    await cfo.locator('[data-cfo-delete-task="'+taskId+'"]').click();
    await cfo.locator('#deleteTaskConfirmation').fill(title);
    await cfo.locator('#deleteTaskReason').fill('Delete disposable local regression fixture only');
    await clickRpc(cfo,'delete_finance_task_cfo_v7',()=>cfo.locator('#confirmDeleteTaskBtn').click());
    assert.deepEqual(await task(),[]);
    assert.deepEqual(await localRows('work_items','select=id&source_entity_id=eq.'+taskId),[]);
    const audit=await localRows('audit_log','select=action,details&action=eq.CFO_DELETE_TASK&entity_id=eq.'+taskId);
    assert.equal(audit.length,1);
    assert.equal(audit[0].details.task.name,title);
    assert.equal(Number(audit[0].details.task.quality_score),94);
    const sentinelAfter=await localRows('tasks','select=*&id=eq.'+sentinelId);
    assert.deepEqual(sentinelAfter,sentinelBefore,'Unrelated local task must remain byte-for-byte identical as JSON');
    lifecycle.steps.push('CFO UI deletion removed only target and retained audit snapshot');
    lifecycle.steps.push('Unrelated existing local task preserved with every task field unchanged');
    await cfo.screenshot({path:path.join(out,'lifecycle-deleted.png'),fullPage:true});
    assert.deepEqual(lifecycle.pageErrors,[]);
    assert.deepEqual(lifecycle.apiErrors,[]);
    lifecycle.status='PASS';
  } catch(error) {
    lifecycle.error=error.stack;
    if(lastPage)await lastPage.screenshot({path:path.join(out,'lifecycle-failure.png'),fullPage:true}).catch(()=>{});
  } finally {
    for(const context of contexts)await context.close();
    fs.writeFileSync(path.join(out,'local-lifecycle.json'),JSON.stringify(lifecycle,null,2));
    console.log(JSON.stringify(lifecycle,null,2));
  }
}
const server = http.createServer((req, res) => {
  const requested = new URL(req.url, 'http://127.0.0.1').pathname;
  const file = requested === '/local-supabase.js'
    ? path.join(__dirname, 'node_modules/@supabase/supabase-js/dist/umd/supabase.js')
    : path.resolve(root, '.' + (requested === '/' ? '/index.html' : requested));
  if (!file.startsWith(root + path.sep)) { res.writeHead(403); return res.end(); }
  try {
    let content = fs.readFileSync(file);
    if (requested === '/') {
      content = content.toString()
        .replace('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2', '/local-supabase.js')
        .replace(/const SUPABASE_URL="[^"]+"/, 'const SUPABASE_URL=' + JSON.stringify(api))
        .replace(/const SUPABASE_KEY="[^"]+"/, 'const SUPABASE_KEY=' + JSON.stringify(anon));
      assert.ok(!content.includes('https://xpomwrpgxnjxabjnwnuz.supabase.co'));
    }
    res.setHeader('Content-Type', requested === '/' ? 'text/html; charset=utf-8'
      : file.endsWith('.css') ? 'text/css' : 'text/javascript');
    res.end(content);
  } catch (error) { res.writeHead(500); res.end(error.message); }
});

(async () => {
  await new Promise(resolve => server.listen(4174, '127.0.0.1', resolve));
  const browser = await chromium.launch({executablePath: process.env.CHROME_PATH, headless: true});
  try {
    for (const [role, email] of [['CFO','cfo@local.invalid'],
      ['Supervisor','supervisor@local.invalid'], ['BankAccountant','bank.accountant@local.invalid']]) {
      const result = {role, email, status:'FAIL', apiErrors:[], pageErrors:[], blockedExternal:[]};
      let context;
      try {
        const created = await fetch(api + '/auth/v1/admin/users', {method:'POST',
          headers:{apikey:service, Authorization:'Bearer '+service, 'Content-Type':'application/json'},
          body:JSON.stringify({email, password, email_confirm:true})});
        if (!created.ok) throw new Error('LOCAL_AUTH_FIXTURE: '+created.status+' '+await created.text());
        context = await browser.newContext({viewport:{width:1440,height:1000}});
        await context.route('**/*', route => {
          if (local(route.request().url())) return route.continue();
          result.blockedExternal.push(route.request().url());
          return route.abort();
        });
        const page = await context.newPage();
        page.on('pageerror', error => result.pageErrors.push(error.message));
        page.on('dialog', dialog => dialog.dismiss());
        page.on('response', async response => {
          if (response.url().startsWith(api) && response.status() >= 400) {
            result.apiErrors.push({url:response.url().replace(api,''),status:response.status(),
              body:(await response.text().catch(()=>'' )).slice(0,3000)});
          }
        });
        await page.goto('http://127.0.0.1:4174');
        await page.locator('#loginEmail').fill(email);
        await page.locator('#loginPassword').fill(password);
        await page.locator('#loginBtn').click();
        await page.waitForFunction(() => typeof profile !== 'undefined' && profile?.role &&
          !document.getElementById('app').classList.contains('hidden'), {timeout:30000});
        result.profile = await page.evaluate(() => ({role:profile.role, id:profile.id,
          permissions:Object.keys(permissionMap).length}));
        assert.equal(result.profile.role, role);
        assert.ok(result.profile.permissions >= 16, 'Permissions must load from local database');
        const permissions = await page.evaluate(async () => {
          const r = await sb.rpc('get_my_permissions');
          return {error:r.error, count:r.data?.length};
        });
        assert.equal(permissions.error, null);
        await page.evaluate(async () => {openPage('workcenter','Work Center'); await loadWorkCenter();});
        await page.waitForSelector('#wcRows');
        const snapshot = await page.evaluate(async () => {
          const r=await sb.rpc('get_workcenter_dashboard_v5',
            {p_scope:['CFO','Supervisor'].includes(profile.role)?'team':'mine',p_filters:{}});
          return {error:r.error, items:r.data?.items?.length};
        });
        result.workcenter = snapshot;
        assert.equal(snapshot.error, null);
        assert.equal(snapshot.items, 0, 'Clean local cycle should have no work items');
        if (role === 'BankAccountant') assert.equal(await page.locator('#wcAddTaskBtn').isVisible(), false);
        await page.screenshot({path:path.join(out,'local-'+role+'.png'),fullPage:true});
        assert.deepEqual(result.pageErrors, []);
        assert.deepEqual(result.apiErrors, [], 'UI requests to local database must succeed');
        result.status = 'PASS';
      } catch (error) { result.error = error.stack; }
      finally { if(context) await context.close(); }
      cases.push(result);
      console.log(JSON.stringify(result,null,2));
    }
    await runLifecycle(browser);
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
    fs.writeFileSync(path.join(out,'local-browser-cases.json'),JSON.stringify(cases,null,2));
  }
  assert.ok(cases.every(c=>c.status==='PASS'), 'Local database UI smoke gate failed');
  assert.equal(lifecycle.status,'PASS','Actual local database task lifecycle gate failed');
})().catch(error=>{console.error(error);server.close();process.exitCode=1;});
