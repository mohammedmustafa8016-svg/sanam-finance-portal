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
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
    fs.writeFileSync(path.join(out,'local-browser-cases.json'),JSON.stringify(cases,null,2));
  }
  assert.ok(cases.every(c=>c.status==='PASS'), 'Local database UI smoke gate failed');
})().catch(error=>{console.error(error);server.close();process.exitCode=1;});
