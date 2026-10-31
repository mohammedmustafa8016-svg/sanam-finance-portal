const production=require('./public-backend.cjs');const preview=require('../release/preview-environment.json');
function backend(){
 const isPreview=process.env.VERCEL_ENV==='preview',config=isPreview?{supabaseUrl:process.env.SANAM_SUPABASE_URL||preview.supabaseUrl,supabaseKey:process.env.SANAM_SUPABASE_PUBLISHABLE_KEY||process.env.SANAM_SUPABASE_ANON_KEY||preview.supabaseKey}:production;
 const url=new URL(config.supabaseUrl);if(url.protocol!=='https:'||!url.hostname.endsWith('.supabase.co')||(isPreview&&url.hostname==='xpomwrpgxnjxabjnwnuz.supabase.co'))throw new Error('MAIL_BACKEND_CONFIGURATION');return config;
}
async function rpc(name,args,authorization){const c=backend(),response=await fetch(c.supabaseUrl+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:c.supabaseKey,Authorization:authorization,'Content-Type':'application/json'},body:JSON.stringify(args),signal:AbortSignal.timeout(8000)});const data=await response.json();if(!response.ok){const e=new Error(data.message||'MAIL_DATABASE_FAILED');e.code=data.message;e.status=response.status;throw e;}return data;}
async function user(authorization){const c=backend(),response=await fetch(c.supabaseUrl+'/auth/v1/user',{headers:{apikey:c.supabaseKey,Authorization:authorization},signal:AbortSignal.timeout(8000)});if(!response.ok)throw new Error('MAIL_SESSION_REQUIRED');const data=await response.json();if(!data.id)throw new Error('MAIL_SESSION_REQUIRED');return data;}
module.exports={backend,rpc,user};
