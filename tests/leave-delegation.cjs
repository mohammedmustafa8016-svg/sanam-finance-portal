const assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm');
(async()=>{
 let active=true,expired=false,failOwn=false,permissionLoads=0,renders=0;
 const calls=[],elements=new Map(),listeners={},timers=[];
 const user={id:'substitute',role:'ARAccountant'};
 const ctx={profile:user,currentLang:'ar',Date,Set,JSON,document:{hidden:false,
 getElementById:id=>elements.get(id)||null,
 createElement:()=>({style:{},setAttribute(){}}),
 querySelector:()=>({prepend(el){elements.set(el.id,el)}}),
 addEventListener(name,fn){listeners[name]=fn}},
 setInterval(fn){timers.push(fn)},loadMyPermissions:async()=>{permissionLoads++},
 showAuth(){},applyLanguage(){},applyAccess(){renders++},renderAll(){},loadWorkCenter:async()=>{},
 sb:{async rpc(name,args){calls.push({name,args});
 if(name==='get_my_leave_delegation_context')return {data:{user_id:user.id,roles:active?['Supervisor']:[],
 delegations:active?[{absent_user_id:'supervisor',full_name:'Absent supervisor',date_from:'2026-11-23',date_to:'2026-11-23',expires_at:new Date(Date.now()+(expired?-1000:60000)).toISOString()}]:[],
 functions:['get_workcenter_dashboard_v5','approve_payment_supervisor','mark_payment_pending','try_perform_work_item_action_v5','start_finance_task']}};
 if(name==='mark_payment_pending'&&failOwn)return {error:{message:'Supervisor required'}};
 return {data:{ok:true}};}},
 addEventListener(name,fn){listeners[name]=fn}};
 ctx.window=ctx;vm.createContext(ctx);
 vm.runInContext(fs.readFileSync('leave-delegation.js','utf8'),ctx);
 await ctx.loadMyPermissions();
 assert.equal(ctx.profile.role,'ARAccountant');
 assert.equal(ctx.hasFinanceRole('Supervisor'),true);
 assert.equal(ctx.hasFinanceRole('ARAccountant'),true);
 assert.equal(ctx.hasFinanceRole('CFO'),false);
 assert.equal(ctx.isDelegatedFinanceUser('supervisor'),true);
 assert.equal(elements.get('leaveDelegationNotice').hidden,false);
 await ctx.sb.rpc('approve_payment_supervisor',{p_payment_id:'third-party'});
 assert.equal(calls.at(-1).name,'perform_supervisor_delegated_rpc');
 assert.equal(calls.at(-1).args.p_function,'approve_payment_supervisor');
 await ctx.sb.rpc('set_user_permission',{});
 assert.equal(calls.at(-1).name,'set_user_permission','CFO-only RPC never elevated');
 user.role='BankAccountant';
 await ctx.sb.rpc('mark_payment_pending',{p_payment_id:'mine'});
 assert.equal(calls.at(-1).name,'mark_payment_pending','Original banking stage retained');
 failOwn=true;await ctx.sb.rpc('mark_payment_pending',{p_payment_id:'other'});
 assert.equal(calls.at(-1).name,'perform_supervisor_delegated_rpc');
 await ctx.sb.rpc('try_perform_work_item_action_v5',{p_action:'START'});
 assert.equal(calls.at(-1).name,'try_perform_work_item_action_v5','Own actions use original role first');
 active=false;await ctx.refreshLeaveDelegationAccess();
 assert.equal(ctx.hasFinanceRole('Supervisor'),false);
 assert.equal(elements.get('leaveDelegationNotice').hidden,true);
 assert.equal(renders,1);
 const before=renders;await ctx.refreshLeaveDelegationAccess();assert.equal(renders,before,'Unchanged access does not re-render the page');
 active=true;expired=true;await ctx.refreshLeaveDelegationAccess();
 assert.equal(ctx.hasFinanceRole('Supervisor'),false,'Expired client context cannot grant Supervisor');
 ctx.showAuth();assert.equal(ctx.hasFinanceRole('Supervisor'),false);
 assert.ok(permissionLoads>=4);assert.equal(timers.length,1);
 console.log('PASS: original role preserved; delegated routing; own banking stage retained; CFO isolation; revocation/expiry; unchanged page retained.');
})().catch(e=>{console.error(e);process.exitCode=1});
