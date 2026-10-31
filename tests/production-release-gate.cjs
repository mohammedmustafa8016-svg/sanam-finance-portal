const assert=require('node:assert/strict');
const {requireProductionGates}=require('../scripts/require-production-gates.cjs');
const sha='a'.repeat(40),other='b'.repeat(40);
const env={VERCEL:'1',VERCEL_ENV:'production',VERCEL_GIT_PROVIDER:'github',VERCEL_GIT_REPO_OWNER:'mohammedmustafa8016-svg',VERCEL_GIT_REPO_SLUG:'sanam-finance-portal',VERCEL_GIT_COMMIT_SHA:sha};
const run={id:20,head_sha:sha,event:'push',path:'.github/workflows/remaining-phases-gates.yml',status:'completed',conclusion:'success'};
const response=rows=>async(url,options)=>{assert.match(url,/head_sha=a{40}/);assert.equal(options.headers.Authorization,undefined);return {ok:true,json:async()=>({workflow_runs:rows})};};
(async()=>{
 let requests=0;await requireProductionGates({...env,VERCEL_ENV:'preview'},async()=>{requests++;});assert.equal(requests,0,'Isolated preview never requires production gates');
 await assert.rejects(requireProductionGates({...env,VERCEL_GIT_COMMIT_SHA:''},response([run])),/VERIFIABLE_GIT/);
 await assert.rejects(requireProductionGates({...env,VERCEL_GIT_REPO_OWNER:'other'},response([run])),/REPOSITORY_MISMATCH/);
 for(const rows of [[],[{...run,head_sha:other}],[{...run,status:'queued',conclusion:null}],[{...run,conclusion:'failure'}],[{...run,conclusion:'cancelled'}],[{...run,conclusion:'skipped'}],[{...run,event:'pull_request'}],[{...run,path:'.github/workflows/unrelated.yml'}],[run,{...run,id:21,status:'in_progress',conclusion:null}]])await assert.rejects(requireProductionGates(env,response(rows)),/GATES_NOT_PASSED/);
 await assert.rejects(requireProductionGates(env,async()=>({ok:false})),/STATUS_UNAVAILABLE/);
 await assert.rejects(requireProductionGates(env,async()=>{throw Error('network failed');}),/STATUS_UNAVAILABLE/);
 await assert.rejects(requireProductionGates(env,async()=>({ok:true,json:async()=>({})})),/RESPONSE_INVALID/);
 assert.deepEqual(await requireProductionGates(env,response([run])),{required:true,sha,runId:20});
 assert.equal((await requireProductionGates(env,response([{...run,path:run.path+'@main'}]))).runId,20);
 // Exercise the actual build entry point: failure must occur before publishing browser configuration.
 const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),{spawnSync}=require('node:child_process');
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'sanam-production-gate-'));
 try {
  fs.mkdirSync(path.join(root,'scripts'));fs.mkdirSync(path.join(root,'release'));
  for(const file of ['build-runtime-config.cjs','require-production-gates.cjs'])fs.copyFileSync(path.join(__dirname,'../scripts',file),path.join(root,'scripts',file));
  fs.writeFileSync(path.join(root,'release/preview-environment.json'),JSON.stringify({preview_only:true,projectRef:'isolated-example',supabaseUrl:'https://isolated-example.supabase.co',supabaseKey:'sb_publishable_test'}));
  const hook=path.join(root,'mock-fetch.cjs'),output=path.join(root,'runtime-config.js');
  const build=(runs,extra={})=>{
   fs.writeFileSync(hook,'globalThis.fetch=async()=>({ok:true,json:async()=>('+JSON.stringify({workflow_runs:runs})+')});');
   return spawnSync(process.execPath,['--require',hook,path.join(root,'scripts/build-runtime-config.cjs')],{env:{...process.env,...env,SANAM_SUPABASE_URL:'',SANAM_SUPABASE_PUBLISHABLE_KEY:'',...extra},encoding:'utf8'});
  };
  const blocked=build([{...run,status:'queued',conclusion:null}]);assert.notEqual(blocked.status,0);assert.equal(fs.existsSync(output),false);assert.match(blocked.stderr,/GATES_NOT_PASSED/);
  assert.equal(build([run]).status,0);assert.equal(fs.readFileSync(output,'utf8'),'window.SANAM_CONFIG = {};\n');
  assert.equal(build([],{VERCEL_ENV:'preview'}).status,0);assert.match(fs.readFileSync(output,'utf8'),/isolated-example/);
 } finally {fs.rmSync(root,{recursive:true,force:true});}
 console.log('PASS: production build requires exact-revision successful release workflow; queued/failed/stale/wrong workflow/network errors fail closed; isolated preview remains available.');
})().catch(error=>{console.error(error);process.exitCode=1;});
