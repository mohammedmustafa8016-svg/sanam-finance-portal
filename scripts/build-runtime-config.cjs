const fs=require('node:fs'),path=require('node:path');
const productionHost='xpomwrpgxnjxabjnwnuz.supabase.co';
function configuration(env,declaredPreview){
 if(env.VERCEL==='1'&&!env.VERCEL_ENV)throw Error('DEPLOYMENT_ENVIRONMENT_REQUIRED');
 let urlText=env.SANAM_SUPABASE_URL,key=env.SANAM_SUPABASE_PUBLISHABLE_KEY;
 if(env.VERCEL_ENV==='preview'&&!urlText&&!key&&declaredPreview?.preview_only===true){
  if(new URL(declaredPreview.supabaseUrl).hostname!==declaredPreview.projectRef+'.supabase.co')throw Error('PREVIEW_PROJECT_REFERENCE_MISMATCH');
  urlText=declaredPreview.supabaseUrl;key=declaredPreview.supabaseKey;
 }
 if(!urlText&&!key){if(env.VERCEL_ENV==='preview')throw Error('PREVIEW_REQUIRES_ISOLATED_SUPABASE_CONFIG');return {};}
 if(!urlText||!key)throw Error('INCOMPLETE_SUPABASE_CONFIG');
 const url=new URL(urlText);
 if(url.protocol!=='https:'||!url.hostname.endsWith('.supabase.co')||url.username||url.password||url.search||url.hash||url.pathname!=='/')throw Error('INVALID_SUPABASE_URL');
 if(env.VERCEL_ENV==='preview'&&url.hostname===productionHost)throw Error('PREVIEW_PRODUCTION_DATABASE_DENIED');
 if(!/^sb_publishable_[A-Za-z0-9_-]+$/.test(key)){
  const parts=key.split('.');let claims;
  try{if(parts.length!==3)throw Error();claims=JSON.parse(Buffer.from(parts[1],'base64url'));}catch{throw Error('CLIENT_KEY_MUST_BE_PUBLISHABLE_OR_ANON');}
  if(claims.role!=='anon')throw Error('SERVICE_OR_SECRET_KEY_MUST_NOT_REACH_BROWSER');
 }
 return {supabaseUrl:url.origin,supabaseKey:key};
}
if(require.main===module){(async()=>{
 const {requireProductionGates}=require('./require-production-gates.cjs');
 const gate=await requireProductionGates(process.env);
 if(gate.required)console.log('Production release gates verified for revision '+gate.sha+' (run '+gate.runId+').');
 const previewPath=path.resolve(__dirname,'../release/preview-environment.json');
 const declaredPreview=fs.existsSync(previewPath)?JSON.parse(fs.readFileSync(previewPath,'utf8')):undefined;
 const config=configuration(process.env,declaredPreview);
 fs.writeFileSync(path.resolve(__dirname,'../runtime-config.js'),'window.SANAM_CONFIG = '+JSON.stringify(config)+';\n');
 console.log('Sanam runtime configuration generated; no credentials logged.');
})().catch(error=>{console.error(error.message);process.exitCode=1;});}
module.exports={configuration};
