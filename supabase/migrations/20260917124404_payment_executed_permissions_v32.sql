-- Sanam Finance Portal V3.2 - executed approvals page permission
create or replace function private.default_permission_for_role(p_role text,p_key text)
returns boolean language sql immutable as $$
 select case p_key
  when 'page.dashboard' then p_role in ('CFO','Supervisor','BankAccountant')
  when 'page.banks' then p_role in ('CFO','Supervisor','BankAccountant')
  when 'page.payments' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','APAccountant')
  when 'page.executed' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant')
  when 'page.posted' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','APAccountant')
  when 'page.pending' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant')
  when 'page.tasks' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
  when 'page.workflow' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
  when 'page.workcenter' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
  when 'page.control' then p_role in ('CFO','Supervisor')
  when 'page.workload' then p_role in ('CFO','Supervisor')
  when 'page.escalations' then p_role in ('CFO','Supervisor')
  when 'page.automation' then p_role='CFO'
  when 'page.close' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
  when 'page.imprest' then p_role in ('CFO','Supervisor','BankAccountant','APAccountant')
  when 'page.performance' then p_role in ('CFO','Supervisor','ARAccountant','APAccountant')
  when 'page.ownership' then p_role in ('CFO','Supervisor')
  when 'page.exceptions' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
  when 'page.audit' then p_role='CFO'
  when 'page.permissions' then p_role='CFO'
  when 'data.bank_balances' then p_role in ('CFO','Supervisor','BankAccountant')
  else false end;
$$;

create or replace function public.get_my_permissions()
returns table(permission_key text,allowed boolean)
language sql stable security definer set search_path='public','private','pg_temp' as $$
 with keys(permission_key) as (values
  ('page.dashboard'),('page.banks'),('page.payments'),('page.executed'),('page.posted'),('page.pending'),('page.tasks'),('page.workflow'),('page.workcenter'),('page.control'),('page.workload'),('page.escalations'),('page.automation'),('page.close'),('page.imprest'),('page.performance'),('page.ownership'),('page.exceptions'),('page.audit'),('page.permissions'),('data.bank_balances')
 ) select k.permission_key,public.has_user_permission(k.permission_key) from keys k;
$$;
