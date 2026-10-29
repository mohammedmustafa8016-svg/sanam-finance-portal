// Serve the disposable fixture site through Playwright interception when loopback is unavailable.
const fs=require('node:fs');
const path=require('node:path');
const {chromium}=require(process.env.PLAYWRIGHT_PATH||'playwright');
const launch=chromium.launch.bind(chromium);
chromium.launch=async (...args)=>{
  const browser=await launch(...args);
  const newPage=browser.newPage.bind(browser);
  browser.newPage=async (...pageArgs)=>{
    const page=await newPage(...pageArgs);
    const route=page.route.bind(page);
    page.route=(pattern,handler,...rest)=>route(pattern,async request=>{
      const url=new URL(request.request().url());
      if(url.hostname!=='127.0.0.1')return request.abort();
      const root=path.resolve(__dirname,'..');
      const file=path.resolve(root,'.'+(url.pathname==='/'?'/index.html':url.pathname));
      if(!file.startsWith(root+path.sep))return request.fulfill({status:403,body:''});
      try{
        let body=fs.readFileSync(file);
        if(file.endsWith('index.html'))body=body.toString().replace('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2','/tests/fixture-client.js');
        return request.fulfill({status:200,contentType:file.endsWith('.html')?'text/html; charset=utf-8':file.endsWith('.css')?'text/css':file.endsWith('.js')?'text/javascript':'text/plain',body});
      }catch{return request.fulfill({status:404,body:''});}
    },...rest);
    return page;
  };
  return browser;
};
