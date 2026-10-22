-- Additive/non-destructive enhancement: per-user visibility, flexible daily plan, reserve reference balances/reporting.

alter table public.bank_accounts
  add column if not exists reference_balance numeric(18,2);

create table if not exists public.user_permissions (
  user_id uuid not null references public.profiles(id) on delete cascade,
  permission_key text not null,
  allowed boolean not null default false,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now(),
  primary key(user_id, permission_key)
);

alter table public.user_permissions enable row level security;

drop policy if exists user_permissions_read on public.user_permissions;
create policy user_permissions_read on public.user_permissions
for select to authenticated
using (user_id = auth.uid() or private."current_role"() = 'CFO');

drop policy if exists user_permissions_manage on public.user_permissions;
create policy user_permissions_manage on public.user_permissions
for all to authenticated
using (private."current_role"() = 'CFO')
with check (private."current_role"() = 'CFO');

create or replace function private.default_permission_for_role(p_role text, p_key text)
returns boolean
language sql
immutable
as $$
select case p_key
  when 'page.dashboard' then p_role in ('CFO','Supervisor','BankAccountant')
  when 'page.banks' then p_role in ('CFO','Supervisor','BankAccountant')
  when 'page.payments' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','APAccountant')
  when 'page.posted' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','APAccountant')
  when 'page.tasks' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
  when 'page.control' then p_role in ('CFO','Supervisor')
  when 'page.escalations' then p_role in ('CFO','Supervisor')
  when 'page.automation' then p_role = 'CFO'
  when 'page.close' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
  when 'page.imprest' then p_role in ('CFO','Supervisor','BankAccountant','APAccountant')
  when 'page.performance' then p_role in ('CFO','Supervisor','ARAccountant','APAccountant')
  when 'page.ownership' then p_role in ('CFO','Supervisor')
  when 'page.exceptions' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
  when 'page.audit' then p_role = 'CFO'
  when 'page.permissions' then p_role = 'CFO'
  when 'data.bank_balances' then p_role in ('CFO','Supervisor','BankAccountant')
  else false end;
$$;

create or replace function public.seed_permissions_for_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare v_role text; v_key text;
begin
  select role into v_role from public.profiles where id=p_user_id;
  if v_role is null then return; end if;
  foreach v_key in array array[
    'page.dashboard','page.banks','page.payments','page.posted','page.tasks','page.control',
    'page.escalations','page.automation','page.close','page.imprest','page.performance',
    'page.ownership','page.exceptions','page.audit','page.permissions','data.bank_balances'
  ] loop
    insert into public.user_permissions(user_id,permission_key,allowed,updated_at)
    values(p_user_id,v_key,private.default_permission_for_role(v_role,v_key),now())
    on conflict(user_id,permission_key) do nothing;
  end loop;
end;
$$;

select public.seed_permissions_for_user(id) from public.profiles where active=true;

create or replace function public.has_user_permission(p_key text)
returns boolean
language sql
stable
security definer
set search_path=public,private,pg_temp
as $$
select coalesce(
  (select up.allowed from public.user_permissions up where up.user_id=auth.uid() and up.permission_key=p_key),
  private.default_permission_for_role(private."current_role"(),p_key),
  false
);
$$;

grant execute on function public.has_user_permission(text) to authenticated;

create or replace function public.get_my_permissions()
returns table(permission_key text, allowed boolean)
language sql
stable
security definer
set search_path=public,private,pg_temp
as $$
with keys(permission_key) as (values
 ('page.dashboard'),('page.banks'),('page.payments'),('page.posted'),('page.tasks'),('page.control'),
 ('page.escalations'),('page.automation'),('page.close'),('page.imprest'),('page.performance'),
 ('page.ownership'),('page.exceptions'),('page.audit'),('page.permissions'),('data.bank_balances')
)
select k.permission_key, public.has_user_permission(k.permission_key) from keys k;
$$;

grant execute on function public.get_my_permissions() to authenticated;

create or replace function public.set_user_permission(p_user_id uuid,p_permission_key text,p_allowed boolean)
returns void
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
begin
  if private."current_role"() <> 'CFO' then raise exception 'Only CFO can manage visibility permissions'; end if;
  if not exists(select 1 from public.profiles where id=p_user_id and active=true) then raise exception 'User not found'; end if;
  if p_permission_key='page.permissions' and p_user_id=auth.uid() and p_allowed=false then raise exception 'CFO cannot remove own permissions administration access'; end if;
  insert into public.user_permissions(user_id,permission_key,allowed,updated_by,updated_at)
  values(p_user_id,p_permission_key,p_allowed,auth.uid(),now())
  on conflict(user_id,permission_key) do update set allowed=excluded.allowed,updated_by=auth.uid(),updated_at=now();
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'SET_USER_PERMISSION','profile',p_user_id::text,jsonb_build_object('permission_key',p_permission_key,'allowed',p_allowed));
end;
$$;

grant execute on function public.set_user_permission(uuid,text,boolean) to authenticated;

create or replace function public.get_bank_account_directory()
returns table(id uuid,company text,bank_name text,account_name text,account_no_last4 text,account_type text)
language sql
stable
security definer
set search_path=public,private,pg_temp
as $$
select b.id,b.company,b.bank_name,b.account_name,
       case when coalesce(b.account_no,'')='' then null else right(regexp_replace(b.account_no,'\s+','','g'),4) end,
       b.account_type
from public.bank_accounts b
order by b.company,b.bank_name,b.account_name;
$$;

grant execute on function public.get_bank_account_directory() to authenticated;

create or replace function public.get_visible_bank_liquidity()
returns table(id uuid,company text,bank_name text,account_name text,account_no text,balance numeric,reserved_balance numeric,available_balance numeric,updated_at timestamptz,account_type text,reference_balance numeric)
language sql
stable
security definer
set search_path=public,private,pg_temp
as $$
select bl.id,bl.company,bl.bank_name,bl.account_name,bl.account_no,bl.balance,bl.reserved_balance,bl.available_balance,bl.updated_at,bl.account_type,b.reference_balance
from public.bank_liquidity bl
join public.bank_accounts b on b.id=bl.id
where public.has_user_permission('data.bank_balances')
order by bl.company,bl.bank_name,bl.account_name;
$$;

grant execute on function public.get_visible_bank_liquidity() to authenticated;

create or replace function public.audit_bank_reference_balance_change()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if old.reference_balance is distinct from new.reference_balance then
    insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
    values(auth.uid(),'BANK_REFERENCE_BALANCE_CHANGED','bank_account',new.id::text,
      jsonb_build_object('from',old.reference_balance,'to',new.reference_balance,'bank_name',new.bank_name,'account_name',new.account_name));
  end if;
  return new;
end;
$$;

drop trigger if exists trg_bank_reference_balance_audit on public.bank_accounts;
create trigger trg_bank_reference_balance_audit
after update of reference_balance on public.bank_accounts
for each row execute function public.audit_bank_reference_balance_change();

drop function if exists public.get_reserve_account_monitor();
create function public.get_reserve_account_monitor()
returns table(
  bank_account_id uuid, company text, bank_name text, account_name text, account_no_last4 text,
  account_type text, reference_balance numeric, balance numeric, reserved_balance numeric, available_balance numeric,
  executed_outflows numeric, manual_support_draws numeric, restorations numeric, outstanding_restoration numeric,
  amount_to_restore_reference numeric, variance_to_reference numeric, last_movement_at timestamptz, last_movement_type text
)
language sql
stable
security definer
set search_path=public,private,pg_temp
as $$
with p as (
  select bank_account_id,coalesce(sum(amount) filter(where executed_at is not null),0)::numeric(18,2) executed_outflows
  from public.payments group by bank_account_id
),m as (
  select bank_account_id,
         coalesce(sum(amount) filter(where movement_type='Support Draw'),0)::numeric(18,2) manual_support_draws,
         coalesce(sum(amount) filter(where movement_type='Restoration'),0)::numeric(18,2) restorations,
         max(created_at) last_movement_at
  from public.bank_reserve_movements group by bank_account_id
),lm as (
  select distinct on(bank_account_id) bank_account_id,movement_type
  from public.bank_reserve_movements order by bank_account_id,created_at desc
)
select bl.id,bl.company,bl.bank_name,bl.account_name,
       case when coalesce(bl.account_no,'')='' then null else right(regexp_replace(bl.account_no,'\s+','','g'),4) end,
       bl.account_type,b.reference_balance,bl.balance,bl.reserved_balance,bl.available_balance,
       coalesce(p.executed_outflows,0)::numeric,coalesce(m.manual_support_draws,0)::numeric,coalesce(m.restorations,0)::numeric,
       greatest(coalesce(p.executed_outflows,0)+coalesce(m.manual_support_draws,0)-coalesce(m.restorations,0),0)::numeric,
       greatest(coalesce(b.reference_balance,bl.balance)-bl.balance,0)::numeric,
       case when b.reference_balance is null then null else (b.reference_balance-bl.balance)::numeric end,
       m.last_movement_at,lm.movement_type
from public.bank_liquidity bl
join public.bank_accounts b on b.id=bl.id
left join p on p.bank_account_id=bl.id left join m on m.bank_account_id=bl.id left join lm on lm.bank_account_id=bl.id
where bl.account_type<>'Operational' and public.has_user_permission('data.bank_balances')
order by case bl.account_type when 'Working Capital Reserve' then 1 when 'VAT Reserve' then 2 else 3 end,bl.company,bl.bank_name;
$$;

grant execute on function public.get_reserve_account_monitor() to authenticated;

create or replace function public.get_reserve_account_report(p_from date default null,p_to date default null)
returns table(
  bank_account_id uuid,company text,bank_name text,account_name text,account_no_last4 text,account_type text,
  reference_balance numeric,current_balance numeric,period_support_draws numeric,period_restorations numeric,
  tracked_outstanding_restoration numeric,amount_to_restore_reference numeric,variance_to_reference numeric
)
language sql
stable
security definer
set search_path=public,private,pg_temp
as $$
with period_m as (
  select m.bank_account_id,
    coalesce(sum(m.amount) filter(where m.movement_type='Support Draw' and (p_from is null or m.movement_date>=p_from) and (p_to is null or m.movement_date<=p_to)),0)::numeric period_support_draws,
    coalesce(sum(m.amount) filter(where m.movement_type='Restoration' and (p_from is null or m.movement_date>=p_from) and (p_to is null or m.movement_date<=p_to)),0)::numeric period_restorations
  from public.bank_reserve_movements m group by m.bank_account_id
),all_m as (
  select m.bank_account_id,
    coalesce(sum(m.amount) filter(where m.movement_type='Support Draw'),0)::numeric all_draws,
    coalesce(sum(m.amount) filter(where m.movement_type='Restoration'),0)::numeric all_restores
  from public.bank_reserve_movements m group by m.bank_account_id
),exec_p as (
  select bank_account_id,coalesce(sum(amount) filter(where executed_at is not null),0)::numeric executed_outflows
  from public.payments group by bank_account_id
)
select b.id,b.company,b.bank_name,b.account_name,
       case when coalesce(b.account_no,'')='' then null else right(regexp_replace(b.account_no,'\s+','','g'),4) end,
       b.account_type,b.reference_balance,b.balance,
       coalesce(pm.period_support_draws,0),coalesce(pm.period_restorations,0),
       greatest(coalesce(ep.executed_outflows,0)+coalesce(am.all_draws,0)-coalesce(am.all_restores,0),0),
       greatest(coalesce(b.reference_balance,b.balance)-b.balance,0),
       case when b.reference_balance is null then null else b.reference_balance-b.balance end
from public.bank_accounts b
left join period_m pm on pm.bank_account_id=b.id left join all_m am on am.bank_account_id=b.id left join exec_p ep on ep.bank_account_id=b.id
where b.account_type<>'Operational' and public.has_user_permission('data.bank_balances')
order by case b.account_type when 'Working Capital Reserve' then 1 when 'VAT Reserve' then 2 else 3 end,b.company,b.bank_name;
$$;

grant execute on function public.get_reserve_account_report(date,date) to authenticated;

create or replace function public.save_flexible_daily_plan(p_items jsonb)
returns integer
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare
  v_role text:=private."current_role"(); v_today date:=(now() at time zone 'Asia/Riyadh')::date;
  v_item jsonb; v_id uuid; v_owner uuid; v_reviewer uuid; v_due_time time; v_priority text; v_name text; v_output text;
  v_owner_role text; v_count integer:=0;
begin
  if v_role not in ('CFO','Supervisor') then raise exception 'Only CFO or Supervisor can manage the daily work plan'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Daily plan must include at least one task'; end if;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_owner := nullif(v_item->>'owner_id','')::uuid;
    if v_owner is null or not exists(select 1 from public.profiles where id=v_owner and active=true) then raise exception 'Valid owner is required'; end if;
    if coalesce(v_item->>'due_time','')='' then raise exception 'Due time is required'; end if;
    v_due_time := (v_item->>'due_time')::time;
    v_priority := coalesce(nullif(v_item->>'priority',''),'عادي');
    select role into v_owner_role from public.profiles where id=v_owner;
    if v_owner_role='Supervisor' then select id into v_reviewer from public.profiles where active=true and role='CFO' order by created_at limit 1;
    else select id into v_reviewer from public.profiles where active=true and role='Supervisor' order by created_at limit 1; end if;
    if coalesce(v_item->>'id','')<>'' then
      v_id := (v_item->>'id')::uuid;
      if not exists(select 1 from public.tasks where id=v_id) then raise exception 'Task not found'; end if;
      if exists(select 1 from public.tasks where id=v_id and status='مكتمل') then continue; end if;
      update public.tasks set owner_id=v_owner,reviewer_id=v_reviewer,due_date=v_today,due_time=v_due_time,
        priority=v_priority,opened_at=coalesce(opened_at,now()),opened_by=auth.uid(),updated_at=now()
      where id=v_id;
      insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
      values(auth.uid(),'PLAN_EXISTING_TASK_FOR_TODAY','task',v_id::text,jsonb_build_object('owner_id',v_owner,'due_date',v_today,'due_time',v_due_time,'priority',v_priority));
    else
      v_name := nullif(trim(coalesce(v_item->>'name','')),'');
      if v_name is null then raise exception 'Task name is required for new plan items'; end if;
      v_output := nullif(trim(coalesce(v_item->>'output','')),'');
      insert into public.tasks(name,frequency,owner_id,reviewer_id,due_date,due_time,priority,status,output,created_by,opened_at,opened_by,created_at,updated_at)
      values(v_name,'خطة اليوم',v_owner,v_reviewer,v_today,v_due_time,v_priority,'لم يبدأ',v_output,auth.uid(),now(),auth.uid(),now(),now()) returning id into v_id;
      insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
      values(auth.uid(),'CREATE_DAILY_PLAN_TASK','task',v_id::text,jsonb_build_object('owner_id',v_owner,'due_date',v_today,'due_time',v_due_time,'priority',v_priority));
    end if;
    v_count:=v_count+1;
  end loop;
  return v_count;
end;
$$;

grant execute on function public.save_flexible_daily_plan(jsonb) to authenticated;
