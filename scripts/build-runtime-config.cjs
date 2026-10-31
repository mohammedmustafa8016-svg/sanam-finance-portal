const fs=require('node:fs'),path=require('node:path');
const productionHost='xpomwrpgxnjxabjnwnuz.supabase.co';
function configuration(env){
 const urlText=env.SANAM_SUPABASE_URL,key=env.SANAM_SUPABASE_PUBLISHABLE_KEY;
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
if(require.main===module){const config=configuration(process.env);fs.writeFileSync(path.resolve(__dirname,'../runtime-config.js'),'window.SANAM_CONFIG = '+JSON.stringify(config)+';\n');console.log('Sanam runtime configuration generated; no credentials logged.');}
module.exports={configuration};
