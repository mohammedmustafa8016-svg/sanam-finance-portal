const fs=require('node:fs'),path=require('node:path'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),out=path.join(root,'gate-results');fs.mkdirSync(out,{recursive:true});
const cases=[
 ['CSV validation',['tests/operations-core.cjs']],
 ['PostgreSQL contract',['tests/governed-controls-database.cjs']],
 ...['operations-platform','workspace-navigation','workcenter-v5','portal-experience','cfo-delete-task'].map(name=>[name,['--require','./tests/offline-browser-preload.cjs',`tests/${name}-browser.cjs`]])
];
const results=[];
for(const [name,args] of cases){const run=spawnSync(process.execPath,args,{cwd:root,env:process.env,encoding:'utf8',timeout:180000});const output=(run.stdout||'')+(run.stderr||'')+(run.error?run.error.message:'');const result={name,status:run.status===0?'PASS':'FAIL',exitCode:run.status,output};results.push(result);console.log(result.status+': '+name);fs.writeFileSync(path.join(out,name.replaceAll(/[^a-zA-Z0-9]+/g,'-')+'.log'),output);if(result.status==='FAIL')console.log(output);}
const evidence={generated_at:new Date().toISOString(),scope:'Local contract and fixture browser checks only; no full Supabase rebuild or production deployment',results};
fs.writeFileSync(path.join(out,'local-release-results.json'),JSON.stringify(evidence,null,2));
fs.writeFileSync(path.join(out,'local-release-results.md'),'# Local validation — Sanam\n\n'+evidence.scope+'\n\n| Check | Result |\n|---|---|\n'+results.map(r=>`| ${r.name} | ${r.status} |`).join('\n')+'\n');
if(results.some(r=>r.status!=='PASS'))process.exitCode=1;
