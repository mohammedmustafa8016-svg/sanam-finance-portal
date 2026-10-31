// Production must use the exact source revision that passed the complete release workflow.
const repository='mohammedmustafa8016-svg/sanam-finance-portal';
const workflow='.github/workflows/remaining-phases-gates.yml';
async function requireProductionGates(env,fetcher=globalThis.fetch){
 if(env.VERCEL!=='1'||env.VERCEL_ENV!=='production')return {required:false};
 const sha=env.VERCEL_GIT_COMMIT_SHA;
 if(!/^[a-f0-9]{40}$/.test(sha||''))throw Error('PRODUCTION_REQUIRES_VERIFIABLE_GIT_REVISION');
 if(env.VERCEL_GIT_PROVIDER!=='github'||env.VERCEL_GIT_REPO_OWNER+'/'+env.VERCEL_GIT_REPO_SLUG!==repository)throw Error('PRODUCTION_REPOSITORY_MISMATCH');
 let payload;
 try {
  const response=await fetcher('https://api.github.com/repos/'+repository+'/actions/runs?head_sha='+sha+'&event=push&per_page=30',{
   headers:{Accept:'application/vnd.github+json','X-GitHub-Api-Version':'2026-03-10'},signal:AbortSignal.timeout(12000)
  });
  if(!response.ok)throw Error();payload=await response.json();
 } catch {throw Error('PRODUCTION_GATE_STATUS_UNAVAILABLE_KEEP_CURRENT_RELEASE');}
 if(!Array.isArray(payload?.workflow_runs))throw Error('PRODUCTION_GATE_RESPONSE_INVALID');
 const runs=payload.workflow_runs.filter(r=>r.head_sha===sha&&r.event==='push'&&r.path?.split('@')[0]===workflow)
  .sort((a,b)=>Number(b.id)-Number(a.id));
 const latest=runs[0];
 if(!latest||latest.status!=='completed'||latest.conclusion!=='success')throw Error('PRODUCTION_RELEASE_GATES_NOT_PASSED_RETRY_AFTER_CI_SUCCESS');
 return {required:true,sha,runId:latest.id};
}
module.exports={requireProductionGates};
