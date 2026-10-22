create table if not exists public.workflow_engine_settings (
  setting_key text primary key,
  enabled boolean not null default false,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);
alter table public.workflow_engine_settings enable row level security;
revoke all on public.workflow_engine_settings from anon,authenticated;
insert into public.workflow_engine_settings(setting_key,enabled) values('workflow_v3',false) on conflict(setting_key) do nothing;

create or replace function private.workflow_v3_enabled()
returns boolean language sql stable security definer set search_path='public','private','pg_temp' as $$
  select coalesce((select enabled from public.workflow_engine_settings where setting_key='workflow_v3'),false);
$$;

create or replace function public.set_workflow_v3_enabled(p_enabled boolean,p_reason text default null)
returns void language plpgsql security definer set search_path='public','private','pg_temp' as $$
begin
 if private.current_role()<>'CFO' then raise exception 'Only CFO can change Workflow V3 state'; end if;
 insert into public.workflow_engine_settings(setting_key,enabled,updated_by,updated_at)
 values('workflow_v3',p_enabled,auth.uid(),now())
 on conflict(setting_key) do update set enabled=excluded.enabled,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'SET_WORKFLOW_V3_STATE','system','workflow_v3',jsonb_build_object('enabled',p_enabled,'reason',nullif(trim(coalesce(p_reason,'')),'')));
end $$;

grant execute on function public.set_workflow_v3_enabled(boolean,text) to authenticated;

create or replace function private.default_permission_for_role(p_role text, p_key text)
returns boolean language sql immutable as $$
select case p_key
 when 'page.dashboard' then p_role in ('CFO','Supervisor','BankAccountant')
 when 'page.banks' then p_role in ('CFO','Supervisor','BankAccountant')
 when 'page.payments' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','APAccountant')
 when 'page.posted' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','APAccountant')
 when 'page.pending' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant')
 when 'page.tasks' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
 when 'page.workflow' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
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
returns table(permission_key text, allowed boolean)
language sql stable security definer set search_path='public','private','pg_temp' as $$
with keys(permission_key) as (values
 ('page.dashboard'),('page.banks'),('page.payments'),('page.posted'),('page.pending'),('page.tasks'),('page.workflow'),('page.control'),('page.workload'),('page.escalations'),('page.automation'),('page.close'),('page.imprest'),('page.performance'),('page.ownership'),('page.exceptions'),('page.audit'),('page.permissions'),('data.bank_balances'))
select k.permission_key,public.has_user_permission(k.permission_key) from keys k;
$$;
