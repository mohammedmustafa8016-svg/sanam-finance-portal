/* Live supervisor delegation augments the signed-in user's original role. */
(() => {
 'use strict';
 let context = null;
 let refreshing = null;
 let revision = 0;
 const readFunctions = new Set(["get_supervisor_control_center","get_workload_capacity","get_escalation_center","get_workcenter_dashboard_v5","get_workcenter_detail_v5","get_workflow_timeline","get_payment_accounting_queue","get_finance_team_performance","get_finance_team_kpi_report","get_employee_performance_report_v4","get_adhoc_activities","get_visible_bank_liquidity","get_bank_account_directory","get_reserve_account_monitor","get_reserve_account_movement_report_v2","get_imprest_fund_summary","get_imprest_settlement_register","get_imprest_funding_overview","get_imprest_funding_requests","get_imprest_ledger_entries","get_recoverable_reserve_uses","get_task_thread"]);
 const ownFunctions = new Set(['mark_payment_pending','resume_pending_payment','update_unapproved_payment']);
 const supervisoryActions = new Set([
  'APPROVE_COMPLETION','RETURN_REWORK','APPROVE_EXTENSION','REJECT_EXTENSION',
  'REQUEST_EXTENSION_INFO','APPROVE_PAYMENT_SUPERVISOR','PAYMENT_SUPERVISOR_APPROVE',
  'POST_PAYMENT','REQUEST_JUSTIFICATION','REASSIGN','CHANGE_DUE','CHANGE_PRIORITY','CHANGE_REVIEWER'
 ]);
 const originalRpc = sb.rpc.bind(sb);

 function liveDelegations() {
  if (!profile?.id || context?.user_id !== profile.id) return [];
  return (context.delegations || []).filter(item => Date.parse(item.expires_at) > Date.now());
 }
 window.hasFinanceRole = role => profile?.role === role ||
  (role === 'Supervisor' && liveDelegations().length > 0);
 window.isDelegatedFinanceUser = userId => liveDelegations().some(row => row.absent_user_id === userId);
 window.hasAnyFinanceRole = roles => roles.some(role => hasFinanceRole(role));

 function renderDelegationNotice() {
  let notice = document.getElementById('leaveDelegationNotice');
  if (!notice) {
   notice = document.createElement('div');
   notice.id = 'leaveDelegationNotice';
   notice.className = 'note';
   notice.setAttribute('role','status');
   notice.style.margin = '0 0 12px';
   document.querySelector('.main .content')?.prepend(notice);
  }
  const rows = liveDelegations();
  notice.hidden = rows.length === 0;
  notice.textContent = rows.map(row => currentLang === 'en'
   ? 'Supervisor delegation for '+row.full_name+' · '+row.date_from+' — '+row.date_to
   : 'تفويض مشرف الحسابات عن '+row.full_name+' · '+row.date_from+' — '+row.date_to
  ).join(' | ');
 }
 async function readContext() {
  const user = profile?.id;
  const token = ++revision;
  if (!user) { context = null; return; }
  const result = await originalRpc('get_my_leave_delegation_context');
  if (token !== revision || profile?.id !== user) return;
  context = !result.error && result.data?.user_id === user ? result.data : null;
  renderDelegationNotice();
 }
 const previousPermissions = loadMyPermissions;
 loadMyPermissions = async function(...args) {
  await readContext();
  return previousPermissions.apply(this,args);
 };

 sb.rpc = function(name,args = {},options) {
  const rows = liveDelegations();
  if (!rows.length || !(context.functions || []).includes(name)) {
   return originalRpc(name,args,options);
  }
  const delegated = () => originalRpc('perform_supervisor_delegated_rpc',{
   p_function:name,p_arguments:args
  },options);
  if (name === 'try_perform_work_item_action_v5') {
   if (supervisoryActions.has(args.p_action)) return delegated();
   return originalRpc(name,args,options).then(result =>
    result.error || result.data?.ok === false ? delegated() : result);
  }
  if (["start_finance_task","submit_finance_task_result","add_task_comment","request_task_extension","mark_task_blocker","submit_task_justification","clear_task_blocker"].includes(name)) {
   return originalRpc(name,args,options).then(result => result.error ? delegated() : result);
  }
  if (ownFunctions.has(name) && ['BankAccountant','GLAccountant','Supervisor'].includes(profile.role)) {
   return originalRpc(name,args,options).then(result => result.error ? delegated() : result);
  }
  return delegated();
 };

 window.refreshLeaveDelegationAccess = async function() {
  if (refreshing || !profile?.id || document.hidden) return refreshing;
  const before = JSON.stringify(context);
  refreshing = (async () => {
   await loadMyPermissions();
   if (JSON.stringify(context) !== before) {
    applyAccess();
    renderAll();
    if (document.getElementById('workcenter')?.classList.contains('active')) await loadWorkCenter();
   }
  })().catch(() => {}).finally(() => { refreshing = null; });
  return refreshing;
 };
 const previousAuth = showAuth;
 showAuth = function(...args) {
  context = null;
  revision++;
  renderDelegationNotice();
  return previousAuth.apply(this,args);
 };
 const previousLanguage = applyLanguage;
 applyLanguage = function(...args) {
  const result = previousLanguage.apply(this,args);
  renderDelegationNotice();
  return result;
 };
 window.addEventListener('focus',() => void refreshLeaveDelegationAccess());
 document.addEventListener('visibilitychange',() => {
  if (!document.hidden) void refreshLeaveDelegationAccess();
 });
 setInterval(() => {
  if (profile?.id && !document.hidden) void refreshLeaveDelegationAccess();
 },30000);
})();
