const assert=require('node:assert/strict');const {chromium}=require(process.env.PLAYWRIGHT_PATH||'playwright');
(async()=>{const browser=await chromium.launch({executablePath:process.env.CHROME_PATH||'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});try{
 const page=await browser.newPage({viewport:{width:1440,height:1000}});const errors=[];page.on('pageerror',e=>errors.push(e.message));page.on('dialog',d=>d.accept());
 await page.route('**/*',r=>new URL(r.request().url()).hostname==='127.0.0.1'?r.continue():r.abort());
 await page.goto('http://127.0.0.1:4173');await page.waitForSelector('[data-work-item]');
 await page.evaluate(()=>{
  payments=[{id:'payment-1',company:'Sanam',beneficiary:'Vendor <script>',amount:1000,due_date:'2026-10-31',supervisor_status:'معلق',cfo_status:'معلق'}];
  bankDirectory=[{id:'bank-1',company:'Sanam',bank_name:'Test Bank',account_name:'Operations',account_type:'Operational'}];
  const base=sb.rpc.bind(sb);window.opsTestCalls=[];window.opsSaved=null;
  sb.rpc=async(name,p={})=>{
   opsTestCalls.push({name,p});
   if(name==='get_readiness_policies')return {data:[{expense_type:'rent',revision:1,required_documents:['lease','invoice','payment_proof'],conditional_documents:[{flag:'prepayment',requires:['benefit_period']}],warning_flags:['amount_variance']}]};
   if(name==='get_payment_readiness_assessment')return {data:window.opsSaved};
   if(name==='check_payment_readiness'){
    const required=['lease','invoice','payment_proof',...(p.p_context.prepayment?['benefit_period']:[])];const missing=required.filter(k=>!p.p_evidence[k]);
    if(p.p_save)window.opsSaved={expense_type:'rent',evidence:p.p_evidence,context:p.p_context,assessed_at:'2026-10-31T12:00:00+03:00'};
    return {data:{ready:missing.length===0,missing,warnings:p.p_context.amount_variance?['amount_variance']:[],policy_revision:1,checked_at:'2026-10-31T12:00:00+03:00'}};
   }
   if(name==='import_bc_control_file'){if(window.opsImportError)return {error:{message:'TEST_IMPORT_REJECTED'}};return {data:{batch_id:'batch-1',inserted:1,updated:0,unchanged:0}};}
   if(name==='get_bc_control_records')return {data:{total:1,items:[{payload:{source_id:'BC-1',amount:1234.5,currency:'SAR',posting_date:'2026-10-31',due_date:'2026-11-01',document_no:'INV-1',beneficiary:'Vendor'}}],last_batch:{file_name:'bc.csv',imported_at:'2026-10-31T12:00:00+03:00'}}};
   if(name==='request_payment_from_bc')return {data:'linked-payment-1'};
   if(name==='set_readiness_policy')return {data:null};
   if(name==='get_employee_performance_report_v5')return {data:{employee:{id:p.p_user_id,full_name:'Employee'},from:p.p_from,to:p.p_to,adjusted_summary:{completed:1,on_time_rate:null,avg_quality_score:null,pending_delay_reviews:1},items:[{work_item_id:'work-1',title:'Close report',due_at:'2026-10-31T10:00:00+03:00',completed_at:'2026-10-31T12:00:00+03:00',excluded_seconds:3600,adjusted_due_at:'2026-10-31T11:00:00+03:00',pending_delay_reviews:1,adjusted_on_time:null,quality_score:null,rework_count:2}]}};
   if(name==='get_work_delay_attributions')return {data:[]};
   if(name==='request_work_delay_attribution')return {data:'delay-1'};
   if(name==='get_operations_health')return {data:{as_of:'2026-10-31T12:00:00+03:00',client_errors_24h:[],pending_delay_decisions:1,latest_imports:[]}};
   if(name==='record_portal_client_error')return {data:null};
   return base(name,p);
  };
  applyAccess();openPage('payments','المدفوعات');
 });
 await page.locator('#opsReadiness').click();await page.waitForSelector('#opsReadyChecklist input');
 await page.locator('#opsReadyCheck').click();await page.waitForSelector('#opsReadyResult .ops-panel');assert.match(await page.locator('#opsReadyResult').textContent(),/غير جاهز/);
 for(const key of ['lease','invoice','payment_proof'])await page.locator(`[data-ready-evidence="${key}"]`).fill('BC-'+key);
 assert.equal(await page.locator('#opsReadyResult .ops-panel').count(),0,'Changing evidence invalidates old result');
 await page.locator('[data-ready-flag="prepayment"]').check();await page.locator('#opsReadyCheck').click();await page.waitForSelector('#opsReadyResult .ops-panel');assert.match(await page.locator('#opsReadyResult').textContent(),/فترة الاستفادة/);
 await page.locator('[data-ready-evidence="benefit_period"]').fill('2026-11 through 2026-12');await page.locator('#opsReadySave').click();await page.waitForFunction(()=>opsSaved!==null);assert.match(await page.locator('#opsReadyResult').textContent(),/جاهز مستنديًا/);
 await page.evaluate(()=>closeModal());await page.locator('#opsPolicy').click();await page.waitForSelector('#opsPolicySave');await page.locator('[data-policy-required="lease"]').uncheck();await page.locator('#opsPolicySave').click();await page.waitForFunction(()=>opsTestCalls.some(c=>c.name==='set_readiness_policy'));assert.equal(await page.evaluate(()=>opsTestCalls.find(c=>c.name==='set_readiness_policy').p.p_revision),1);
 await page.evaluate(()=>closeModal());await page.locator('#opsBCPayments').click();await page.locator('#opsBCCompany').fill('Sanam');
 await page.locator('#opsBCFile').setInputFiles({name:'bc.csv',mimeType:'text/csv',buffer:Buffer.from('source_id,amount,currency,posting_date,beneficiary\nBC-1,1234.50,SAR,2026-10-31,Vendor\n')});
 await page.locator('#opsBCParse').click();await page.waitForSelector('#opsBCValidate');await page.locator('#opsBCValidate').click();await page.locator('#opsBCCommit').click();assert.match(await page.locator('#opsBCStatus').textContent(),/أكد مراجعة/);
 await page.locator('#opsBCConfirm').check();await page.evaluate(()=>window.opsImportError=true);await page.locator('#opsBCCommit').click();await page.waitForFunction(()=>document.getElementById('opsBCStatus').textContent.includes('TEST_IMPORT_REJECTED'));
 await page.evaluate(()=>window.opsImportError=false);await page.locator('#opsBCCommit').click();await page.waitForSelector('#opsBCRequestPayment');assert.equal(await page.evaluate(()=>opsTestCalls.filter(c=>c.name==='import_bc_control_file').at(-1).p.p_rows[0].source_id),'BC-1');
 await page.locator('#opsBCRequestPayment').click();await page.waitForSelector('#opsBCRequestSave');assert.match(await page.locator('#modalBody').textContent(),/1234|1,234/);
 await page.locator('#opsBCRequestSave').click();await page.waitForFunction(()=>opsTestCalls.some(c=>c.name==='request_payment_from_bc'));assert.deepEqual(await page.evaluate(()=>{const p=opsTestCalls.find(c=>c.name==='request_payment_from_bc').p;return {company:p.p_company,id:p.p_source_id,bank:p.p_bank_account_id};}),{company:'Sanam',id:'BC-1',bank:'bank-1'});
 await page.evaluate(()=>openEmployeePerformanceReport(fixturePeople[2].id));await page.waitForSelector('#opsDelayOpen');assert.match(await page.locator('#employeePerformanceOutput').textContent(),/قيد المراجعة/);assert.match(await page.locator('#employeePerformanceOutput').textContent(),/60.0/);
 await page.locator('#opsDelayOpen').click();await page.locator('#opsDelayFrom').fill('2026-10-31T09:00:00+03:00');await page.locator('#opsDelayTo').fill('2026-10-31T10:00:00+03:00');await page.locator('#opsDelayExplanation').fill('Waiting for supervisor approval');await page.locator('#opsDelayEvidence').fill('Audit event 10');await page.locator('#opsDelayRequest').click();await page.waitForFunction(()=>opsTestCalls.some(c=>c.name==='request_work_delay_attribution'));
 await page.evaluate(()=>{window.open=()=>({document:{write(html){window.opsPrinted=html;},close(){}},focus(){},print(){}});printEmployeePerformanceReport();});
 const printed=await page.evaluate(()=>window.opsPrinted);assert.match(printed,/تقرير أداء الموظف/);assert.match(printed,/الوقت المستبعد/);assert.ok(!printed.includes('opsDelayArea')&&!printed.includes('<button'),'Printed report excludes interactive controls');
 await page.evaluate(()=>{closeModal();payments=[{id:'p1',beneficiary:'Vendor',amount:1000,company:'Sanam',supervisor_status:'موافق',cfo_status:'معلق'}];tasks=[{id:'t1',name:'Bank review',due_date:'2026-09-20',due_time:'09:00',status:'لم يبدأ'},{id:'t2',name:'Review',due_date:'2026-10-31',status:'بانتظار المراجعة'}];imprest=[{id:'fund-1',status:'تحتاج تسوية',balance:1000}];openPage('dashboard','الرئيسية');renderDashboard();applyAccess();});assert.equal(await page.locator('#opsHome').isVisible(),true);
 assert.ok(await page.locator('#opsHome .ops-alert b').allTextContents().then(values=>values.some(x=>Number(x)>0)));
 await page.screenshot({path:'tests/operations-home-desktop.png'});
 await page.setViewportSize({width:390,height:844});assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));await page.screenshot({path:'tests/operations-home-mobile.png'});
 await page.evaluate(()=>toggleLanguage());assert.match(await page.locator('#opsHome').textContent(),/What needs your attention/);
 await page.evaluate(()=>{openPage('automation','Automation');window.dispatchEvent(new ErrorEvent('error',{message:'sensitive-private-file-content'}));});
 await page.waitForSelector('#opsHealthResults h3');await page.waitForFunction(()=>opsTestCalls.some(c=>c.name==='record_portal_client_error'));
 const telemetry=await page.evaluate(()=>opsTestCalls.find(c=>c.name==='record_portal_client_error').p);assert.deepEqual(telemetry,{p_code:'WINDOW_ERROR',p_page:'automation'});assert.ok(!JSON.stringify(telemetry).includes('sensitive'));
 await page.evaluate(()=>{profile={...profile,role:'Viewer'};permissionMap={'page.dashboard':true};applyAccess();});assert.equal(await page.locator('#opsHome').isVisible(),false);assert.equal(await page.locator('#opsPaymentActions').isVisible(),false);
 assert.deepEqual(errors,[]);console.log('PASS: readiness preview/save/stale evidence, policy edit, CSV mapping/preview/confirmation/error recovery, BC-linked request, explainable report/delay request, Home/language/mobile/Viewer; no page errors.');
 }finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
