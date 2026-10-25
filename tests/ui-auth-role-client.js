// Isolated UI auth/role fixture. Never contacts Production.
window.fixtureWorkCenterError=false;
window.fixtureCalls=[];
const fixturePassword='UiTest123!';
const fixtureUsers=[
 {id:'00000000-0000-4000-8000-000000000001',email:'cfo@local.invalid',full_name:'المدير المالي',role:'CFO',finance_team:true,active:true},
 {id:'00000000-0000-4000-8000-000000000002',email:'supervisor@local.invalid',full_name:'مشرف الحسابات',role:'Supervisor',finance_team:true,active:true},
 {id:'00000000-0000-4000-8000-000000000003',email:'bank.accountant@local.invalid',full_name:'محاسب البنوك',role:'BankAccountant',finance_team:true,active:true},
 {id:'00000000-0000-4000-8000-000000000004',email:'gl.accountant@local.invalid',full_name:'محاسب القيود',role:'GLAccountant',finance_team:true,active:true},
 {id:'00000000-0000-4000-8000-000000000005',email:'ar.accountant@local.invalid',full_name:'محاسب العملاء',role:'ARAccountant',finance_team:true,active:true},
 {id:'00000000-0000-4000-8000-000000000006',email:'ap.accountant@local.invalid',full_name:'محاسب الموردين',role:'APAccountant',finance_team:true,active:true},
 {id:'00000000-0000-4000-8000-000000000007',email:'viewer@local.invalid',full_name:'مطلع تجريبي',role:'Viewer',finance_team:false,active:true}
];
const navPages=['workcenter','dashboard','banks','reservev2','payments','executed','pending','posted','close','imprest','performance','ownership','exceptions','permissions','automation','audit'];
const rolePages={
 CFO:navPages,
 Supervisor:['workcenter','dashboard','banks','reservev2','payments','executed','pending','posted','close','imprest','performance','ownership','exceptions','automation'],
 BankAccountant:['workcenter','dashboard','banks','payments','executed','pending','posted','close','imprest','exceptions'],
 GLAccountant:['workcenter','dashboard','payments','executed','pending','posted','close','exceptions'],
 ARAccountant:['workcenter','dashboard','close','performance','exceptions'],
 APAccountant:['workcenter','dashboard','payments','executed','posted','close','imprest','performance','exceptions'],
 Viewer:['dashboard']
};
let fixtureSession=null,authListener=null;
const now=new Date().toISOString();
const workItems=[
 {work_item_id:'10000000-0000-0000-0000-000000000001',source_id:'20000000-0000-0000-0000-000000000001',source_type:'task',title:'مطابقة الحساب البنكي',status:'Ready',bucket:'execution',is_review:false,is_attention:false,is_overdue:false,item_type:'MANUAL_TASK',assignee_id:fixtureUsers[2].id,owner_id:fixtureUsers[2].id,assignee_name:fixtureUsers[2].full_name,reviewer_id:fixtureUsers[1].id,reviewer_name:fixtureUsers[1].full_name,priority:'عادي',assigned_at:now,started_at:null,completed_at:null,due_at:now,remaining_minutes:120,quality_score:null,on_time:null,requires_my_decision:false,task_description:'مطابقة كشف الحساب البنكي.',result_description:null,available_actions:[{action:'START'}]},
 {work_item_id:'10000000-0000-0000-0000-000000000002',source_id:'20000000-0000-0000-0000-000000000002',source_type:'task',title:'مراجعة تحصيلات العملاء',status:'In Progress',bucket:'execution',is_review:false,is_attention:false,is_overdue:false,item_type:'MANUAL_TASK',assignee_id:fixtureUsers[4].id,owner_id:fixtureUsers[4].id,assignee_name:fixtureUsers[4].full_name,reviewer_id:fixtureUsers[1].id,reviewer_name:fixtureUsers[1].full_name,priority:'عادي',assigned_at:now,started_at:now,completed_at:null,due_at:now,remaining_minutes:90,quality_score:null,on_time:null,requires_my_decision:false,task_description:'مراجعة التحصيلات.',result_description:null,available_actions:[{action:'COMPLETE'}]}
];
function currentUser(){return fixtureUsers.find(u=>u.id===fixtureSession?.user?.id)||null}
function permissionRows(){
 const u=currentUser();if(!u)return[];
 const allowed=new Set(rolePages[u.role]||[]);
 return navPages.map(p=>({permission_key:'page.'+p,allowed:allowed.has(p)})).concat([{permission_key:'data.bank_balances',allowed:['CFO','Supervisor','BankAccountant'].includes(u.role)}]);
}
function snapshot(scope){
 const u=currentUser();if(!u)return null;
 const manager=['CFO','Supervisor'].includes(u.role);
 let items=structuredClone(workItems);
 if(!manager||scope==='mine')items=items.filter(x=>x.owner_id===u.id);
 items.forEach(w=>{if(manager)w.available_actions=[{action:'COMMENT'}];});
 const team=fixtureUsers.filter(x=>x.finance_team).map(p=>{const r=workItems.filter(x=>x.owner_id===p.id);return {user_id:p.id,full_name:p.full_name,role:p.role,ready:r.filter(x=>x.status==='Ready').length,in_progress:r.filter(x=>x.status==='In Progress').length,reviews:0,attention:0,overdue:0,completed:0,quality_avg:null,quality_count:0,timed_count:0,on_time_rate:null}});
 return {cycle:{id:'ui-auth-cycle',started_at:now,label:'UI Auth Test'},as_of:now,items,summary:{},team};
}
function queryFor(table){
 const filters=[];
 const q={
  select(){return this},eq(k,v){filters.push([k,v]);return this},order(){return this},limit(){return this},
  maybeSingle(){let data=table==='profiles'?fixtureUsers.slice():[];for(const [k,v] of filters)data=data.filter(x=>x[k]===v);return Promise.resolve({data:data[0]||null,error:null})},
  then(resolve,reject){let data=table==='profiles'?fixtureUsers.slice():[];for(const [k,v] of filters)data=data.filter(x=>x[k]===v);return Promise.resolve({data,error:null}).then(resolve,reject)}
 };
 return q;
}
const client={
 auth:{
  async getSession(){return {data:{session:fixtureSession}}},
  onAuthStateChange(cb){authListener=cb;return {data:{subscription:{unsubscribe(){authListener=null}}}}},
  async signInWithPassword({email,password}){const u=fixtureUsers.find(x=>x.email===String(email).toLowerCase());if(!u||password!==fixturePassword)return {data:{session:null,user:null},error:{message:'Invalid login credentials'}};fixtureSession={access_token:'fixture',user:{id:u.id,email:u.email}};queueMicrotask(()=>authListener?.('SIGNED_IN',fixtureSession));return {data:{session:fixtureSession,user:fixtureSession.user},error:null}},
  async signUp(){return {data:{session:null,user:null},error:{message:'Signup disabled in UI test fixture'}}},
  async signOut(){fixtureSession=null;queueMicrotask(()=>authListener?.('SIGNED_OUT',null));return {error:null}},
  async resetPasswordForEmail(){return {data:{},error:null}},
  async updateUser(){return {data:{user:fixtureSession?.user||null},error:null}}
 },
 channel(){return {on(){return this},subscribe(){return this}}},
 removeChannel(){},
 from:queryFor,
 async rpc(name,p={}){
  fixtureCalls.push({name,p});
  const u=currentUser();
  if(name==='get_my_permissions')return {data:permissionRows(),error:null};
  if(name==='get_workcenter_dashboard_v5'){
   if(window.fixtureWorkCenterError)return {data:null,error:{message:'UI fixture Work Center unavailable'}};
   if(!u)return {data:null,error:{message:'NOT_AUTHORIZED'}};
   if(p.p_scope==='team'&&!['CFO','Supervisor'].includes(u.role))return {data:null,error:{message:'TEAM_SCOPE_NOT_ALLOWED'}};
   return {data:snapshot(p.p_scope||'mine'),error:null};
  }
  if(name==='get_workcenter_detail_v5')return {data:{comments:[],extensions:[],events:[]},error:null};
  if(name==='try_perform_work_item_action_v5')return {data:{ok:true},error:null};
  if(name==='get_task_operational_start_date')return {data:'2026-09-17',error:null};
  if(name==='get_readonly_dashboard_snapshot')return {data:{filters:{companies:[]},liquidity:{},payments:{},tasks:{},close:{},exceptions:{items:[]},team:[],automation:[],reserves:[]},error:null};
  if(name==='get_readonly_page_snapshot')return {data:{},error:null};
  if(name==='get_notification_inbox_v6')return {data:{items:[],total:0,unread:0},error:null};
  if(['get_bank_account_directory','get_finance_team_performance','get_imprest_settlement_register','get_imprest_fund_summary','get_finance_policy_register','get_supervisor_control_center','get_workload_capacity','get_escalation_center','get_automation_health','get_payment_accounting_queue','get_my_task_notifications','get_my_workday','get_adhoc_activities','get_visible_bank_liquidity','get_reserve_account_monitor'].includes(name))return {data:[],error:null};
  return {data:[],error:null};
 }
};
window.supabase={createClient:()=>client};
