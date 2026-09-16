-- Protected additive release: access governance, manual daily planning, payment SLA, activity KPIs.

create table if not exists public.finance_settings (
  setting_key text primary key,
  setting_value jsonb not null,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

insert into public.finance_settings(setting_key,setting_value,updated_at)
values('daily_plan_go_live_date',to_jsonb('2026-09-17'::text),now())
on conflict(setting_key) do update set setting_value=excluded.setting_value,updated_at=now();

create table if not exists public.finance_activity_log (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.profiles(id),
  activity_type text not null,
  source_entity_type text not null,
  source_entity_id text not null,
  event_key text not null unique,
  activity_date date not null default ((now() at time zone 'Asia/Riyadh')::date),
  occurred_at timestamptz not null default now(),
  sla_status text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists finance_activity_log_employee_date_idx on public.finance_activity_log(employee_id,activity_date desc);
create index if not exists finance_activity_log_type_idx on public.finance_activity_log(activity_type,activity_date desc);

alter table public.finance_activity_log enable row level security;
drop policy if exists finance_activity_read on public.finance_activity_log;
create policy finance_activity_read on public.finance_activity_log for select to authenticated
using(employee_id=auth.uid() or private.current_role() in ('CFO','Supervisor'));
revoke all on public.finance_activity_log from anon;
revoke insert,update,delete,truncate,references,trigger on public.finance_activity_log from authenticated;
grant select on public.finance_activity_log to authenticated;

create or replace function private.log_employee_activity(
  p_employee_id uuid,
  p_activity_type text,
  p_entity_type text,
  p_entity_id text,
  p_event_key text,
  p_sla_status text default null,
  p_details jsonb default '{}'::jsonb,
  p_occurred_at timestamptz default now()
) returns void
language plpgsql security definer set search_path='public','private','pg_temp'
as $$
begin
  if p_employee_id is null or coalesce(trim(p_event_key),'')='' then return; end if;
  insert into public.finance_activity_log(employee_id,activity_type,source_entity_type,source_entity_id,event_key,activity_date,occurred_at,sla_status,details)
  values(p_employee_id,p_activity_type,p_entity_type,p_entity_id,p_event_key,(p_occurred_at at time zone 'Asia/Riyadh')::date,p_occurred_at,p_sla_status,coalesce(p_details,'{}'::jsonb))
  on conflict(event_key) do nothing;
end $$;

create or replace function private.capture_payment_activity() returns trigger
language plpgsql security definer set search_path='public','private','pg_temp'
as $$
declare v_role text;
begin
  if tg_op='INSERT' then
    select role into v_role from public.profiles where id=new.requested_by;
    if v_role='BankAccountant' then
      perform private.log_employee_activity(new.requested_by,'PAYMENT_CREATED','payment',new.id::text,'PAYMENT_CREATED:'||new.id::text,null,jsonb_build_object('amount',new.amount,'beneficiary',new.beneficiary),coalesce(new.created_at,now()));
    end if;
    return new;
  end if;
  if old.executed_at is null and new.executed_at is not null then
    select role into v_role from public.profiles where id=new.executed_by;
    if v_role='BankAccountant' then
      perform private.log_employee_activity(new.executed_by,'PAYMENT_EXECUTED','payment',new.id::text,'PAYMENT_EXECUTED:'||new.id::text,'Within SLA',jsonb_build_object('amount',new.amount,'beneficiary',new.beneficiary),new.executed_at);
    end if;
  end if;
  if old.accounting_registered_at is null and new.accounting_registered_at is not null then
    select role into v_role from public.profiles where id=new.accounting_registered_by;
    if v_role='GLAccountant' then
      perform private.log_employee_activity(new.accounting_registered_by,'PAYMENT_ACCOUNTING_REGISTERED','payment',new.id::text,'PAYMENT_ACCOUNTING_REGISTERED:'||new.id::text,
        case when new.executed_at is not null and new.accounting_registered_at>new.executed_at+interval '48 hours' then 'Overdue' else 'Within SLA' end,
        jsonb_build_object('amount',new.amount,'beneficiary',new.beneficiary,'hours_from_execution',case when new.executed_at is null then null else round((extract(epoch from(new.accounting_registered_at-new.executed_at))/3600)::numeric,2) end),new.accounting_registered_at);
    end if;
  end if;
  if old.status is distinct from new.status and new.status='مرحّل' then
    select role into v_role from public.profiles where id=new.posted_by;
    if v_role='GLAccountant' then
      perform private.log_employee_activity(new.posted_by,'PAYMENT_POSTED','payment',new.id::text,'PAYMENT_POSTED:'||new.id::text,
        case when new.executed_at is not null and coalesce(new.posted_at,now())>new.executed_at+interval '48 hours' then 'Overdue' else 'Within SLA' end,
        jsonb_build_object('amount',new.amount,'beneficiary',new.beneficiary),coalesce(new.posted_at,now()));
    end if;
  end if;
  if old.status is distinct from new.status and new.status='معلقة' then
    select role into v_role from public.profiles where id=new.pending_by;
    if v_role='GLAccountant' then
      perform private.log_employee_activity(new.pending_by,'PAYMENT_MARKED_PENDING','payment',new.id::text,'PAYMENT_MARKED_PENDING:'||new.id::text,
        case when new.executed_at is not null and coalesce(new.pending_at,now())>new.executed_at+interval '48 hours' then 'Overdue' else 'Within SLA' end,
        jsonb_build_object('reason',new.pending_reason,'required_action',new.pending_action),coalesce(new.pending_at,now()));
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_capture_payment_activity on public.payments;
create trigger trg_capture_payment_activity after insert or update on public.payments for each row execute function private.capture_payment_activity();

create or replace function private.capture_bank_activity() returns trigger
language plpgsql security definer set search_path='public','private','pg_temp'
as $$
declare v_role text:=private.current_role(); v_actor uuid:=auth.uid();
begin
  if v_actor is not null and v_role='BankAccountant' and old.balance is distinct from new.balance then
    perform private.log_employee_activity(v_actor,'BANK_BALANCE_UPDATED','bank_account',new.id::text,
      'BANK_BALANCE_UPDATED:'||new.id::text||':'||txid_current()::text,null,
      jsonb_build_object('old_balance',old.balance,'new_balance',new.balance,'bank_name',new.bank_name,'account_name',new.account_name),now());
  end if;
  return new;
end $$;

drop trigger if exists trg_capture_bank_activity on public.bank_accounts;
create trigger trg_capture_bank_activity after update of balance on public.bank_accounts for each row execute function private.capture_bank_activity();

create or replace function private.default_permission_for_role(p_role text,p_key text) returns boolean
language sql immutable as $$
select case p_key
 when 'page.dashboard' then p_role in ('CFO','Supervisor','BankAccountant')
 when 'page.banks' then p_role in ('CFO','Supervisor','BankAccountant')
 when 'page.payments' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','APAccountant')
 when 'page.posted' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','APAccountant')
 when 'page.pending' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant')
 when 'page.tasks' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
 when 'page.control' then p_role in ('CFO','Supervisor')
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

create or replace function public.get_my_permissions() returns table(permission_key text,allowed boolean)
language sql stable security definer set search_path='public','private','pg_temp' as $$
with keys(permission_key) as (values
 ('page.dashboard'),('page.banks'),('page.payments'),('page.posted'),('page.pending'),('page.tasks'),('page.control'),('page.escalations'),('page.automation'),('page.close'),('page.imprest'),('page.performance'),('page.ownership'),('page.exceptions'),('page.audit'),('page.permissions'),('data.bank_balances'))
select k.permission_key,public.has_user_permission(k.permission_key) from keys k;
$$;

grant execute on function public.get_my_permissions() to authenticated;

create or replace function public.set_user_permission(p_user_id uuid,p_permission_key text,p_allowed boolean) returns void
language plpgsql security definer set search_path='public','private','pg_temp' as $$
declare v_target_role text;
begin
 if private.current_role()<>'CFO' then raise exception 'Only CFO can manage visibility permissions'; end if;
 select role into v_target_role from public.profiles where id=p_user_id and active=true;
 if v_target_role is null then raise exception 'User not found'; end if;
 if p_permission_key='page.permissions' and p_user_id=auth.uid() and p_allowed=false then raise exception 'CFO cannot remove own permissions administration access'; end if;
 if p_allowed and p_permission_key in ('page.dashboard','page.banks','data.bank_balances') and v_target_role not in ('CFO','Supervisor','BankAccountant') then
   raise exception 'Financial dashboard, liquidity and balances are restricted to CFO, Supervisor and Bank Accountant';
 end if;
 insert into public.user_permissions(user_id,permission_key,allowed,updated_by,updated_at)
 values(p_user_id,p_permission_key,p_allowed,auth.uid(),now())
 on conflict(user_id,permission_key) do update set allowed=excluded.allowed,updated_by=auth.uid(),updated_at=now();
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'SET_USER_PERMISSION','profile',p_user_id::text,jsonb_build_object('permission_key',p_permission_key,'allowed',p_allowed));
end $$;

-- Enforce balance confidentiality at the row/view layer while preserving safe directory RPC access.
drop policy if exists bank_accounts_read on public.bank_accounts;
create policy bank_accounts_read on public.bank_accounts for select to authenticated using(public.has_user_permission('data.bank_balances'));
drop policy if exists reserve_movements_read on public.bank_reserve_movements;
create policy reserve_movements_read on public.bank_reserve_movements for select to authenticated using(public.has_user_permission('data.bank_balances'));
revoke all on public.bank_liquidity from anon;
revoke all on public.bank_liquidity from authenticated;
grant execute on function public.get_visible_bank_liquidity() to authenticated;
grant execute on function public.get_bank_account_directory() to authenticated;
grant execute on function public.get_reserve_account_monitor() to authenticated;

-- Stop automatic daily-task generation. Historical tasks/templates are preserved.
update cron.job set active=false where command like '%private.generate_daily_tasks%';

-- Preserve existing templates as reusable catalog choices without creating daily tasks.
insert into public.finance_task_catalog(name,default_owner_id,default_priority,output,active,created_by,created_at,updated_at)
select d.name,d.owner_id,d.priority,d.output,d.active,d.created_by,coalesce(d.created_at,now()),coalesce(d.updated_at,now())
from private.daily_task_templates d
where not exists(select 1 from public.finance_task_catalog c where lower(trim(c.name))=lower(trim(d.name)) and c.default_owner_id is not distinct from d.owner_id);

create or replace function public.create_finance_task_template(p_name text,p_owner_id uuid,p_priority text default 'عادي',p_output text default null) returns uuid
language plpgsql security definer set search_path='public','private','pg_temp' as $$
declare v_id uuid;
begin
 if private.current_role() not in ('CFO','Supervisor') then raise exception 'Only CFO or Supervisor can create task templates'; end if;
 if nullif(trim(coalesce(p_name,'')),'') is null then raise exception 'Template name is required'; end if;
 if not exists(select 1 from public.profiles where id=p_owner_id and active=true) then raise exception 'Valid default owner is required'; end if;
 insert into public.finance_task_catalog(name,default_owner_id,default_priority,output,created_by)
 values(trim(p_name),p_owner_id,coalesce(nullif(p_priority,''),'عادي'),nullif(trim(coalesce(p_output,'')),''),auth.uid()) returning id into v_id;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'CREATE_TASK_TEMPLATE','finance_task_catalog',v_id::text,jsonb_build_object('name',trim(p_name),'owner_id',p_owner_id));
 return v_id;
end $$;
grant execute on function public.create_finance_task_template(text,uuid,text,text) to authenticated;

create or replace function public.save_manual_daily_plan(p_items jsonb) returns integer
language plpgsql security definer set search_path='public','private','pg_temp' as $$
declare
 v_role text:=private.current_role(); v_today date:=(now() at time zone 'Asia/Riyadh')::date; v_item jsonb; v_catalog public.finance_task_catalog%rowtype;
 v_owner uuid; v_reviewer uuid; v_owner_role text; v_due_time time; v_priority text; v_name text; v_output text; v_task_id uuid; v_count int:=0; v_save_template boolean;
begin
 if v_role not in ('CFO','Supervisor') then raise exception 'Only CFO or Supervisor can manage the daily work plan'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Daily plan must include at least one selected task'; end if;
 for v_item in select value from jsonb_array_elements(p_items) loop
   if coalesce(v_item->>'catalog_id','')<>'' then
     select * into v_catalog from public.finance_task_catalog where id=(v_item->>'catalog_id')::uuid and active=true;
     if not found then raise exception 'Task template not found'; end if;
     v_name:=v_catalog.name; v_output:=v_catalog.output; v_owner:=coalesce(nullif(v_item->>'owner_id','')::uuid,v_catalog.default_owner_id); v_priority:=coalesce(nullif(v_item->>'priority',''),v_catalog.default_priority,'عادي');
   else
     v_name:=nullif(trim(coalesce(v_item->>'name','')),''); v_output:=nullif(trim(coalesce(v_item->>'output','')),''); v_owner:=nullif(v_item->>'owner_id','')::uuid; v_priority:=coalesce(nullif(v_item->>'priority',''),'عادي');
     if v_name is null then raise exception 'Task name is required'; end if;
   end if;
   if v_owner is null or not exists(select 1 from public.profiles where id=v_owner and active=true) then raise exception 'Valid owner is required'; end if;
   if coalesce(v_item->>'due_time','')='' then raise exception 'Due time is required'; end if;
   v_due_time:=(v_item->>'due_time')::time;
   select role into v_owner_role from public.profiles where id=v_owner;
   if v_owner_role='Supervisor' then select id into v_reviewer from public.profiles where active=true and role='CFO' order by created_at limit 1;
   else select id into v_reviewer from public.profiles where active=true and role='Supervisor' order by created_at limit 1; end if;
   insert into public.tasks(name,frequency,owner_id,reviewer_id,due_date,due_time,priority,status,output,created_by,opened_at,opened_by,created_at,updated_at)
   values(v_name,'خطة اليوم',v_owner,v_reviewer,v_today,v_due_time,v_priority,'لم يبدأ',v_output,auth.uid(),now(),auth.uid(),now(),now()) returning id into v_task_id;
   v_save_template:=coalesce((v_item->>'save_as_template')::boolean,false);
   if v_save_template and coalesce(v_item->>'catalog_id','')='' then
      insert into public.finance_task_catalog(name,default_owner_id,default_priority,output,created_by)
      values(v_name,v_owner,v_priority,v_output,auth.uid());
   end if;
   insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
   values(auth.uid(),'OPEN_MANUAL_DAILY_TASK','task',v_task_id::text,jsonb_build_object('owner_id',v_owner,'due_date',v_today,'due_time',v_due_time,'priority',v_priority,'catalog_id',nullif(v_item->>'catalog_id',''),'operator_role',v_role,'saved_as_template',v_save_template));
   v_count:=v_count+1;
 end loop;
 return v_count;
end $$;
grant execute on function public.save_manual_daily_plan(jsonb) to authenticated;

create or replace function public.get_escalation_center()
returns table(task_id uuid,task_name text,owner_id uuid,owner_name text,priority text,status text,due_at timestamptz,issue text,severity text,age_minutes integer,blocker_note text,justification_note text)
language sql stable security definer set search_path='public','private','pg_temp' as $$
with ctx as(
 select private.current_role() current_role,coalesce((select trim(both '"' from setting_value::text)::date from public.finance_settings where setting_key='daily_plan_go_live_date'),'2026-09-17'::date) go_live
),base as(
 select t.*,p.full_name owner_name,private.task_deadline(t.due_date,t.due_time) due_at
 from public.tasks t join public.profiles p on p.id=t.owner_id,ctx c
 where c.current_role in ('CFO','Supervisor') and t.status<>'مكتمل' and t.due_date>=c.go_live
),flagged as(
 select b.*,concat_ws('، ',case when nullif(trim(coalesce(b.blocker_note,'')),'') is not null then 'تعثر' end,case when b.status not in ('مكتمل','بانتظار المراجعة') and b.due_at<now() then 'متأخر' end,case when b.status='بانتظار المراجعة' then 'بانتظار مراجعة' end,case when b.justification_requested_at is not null and nullif(trim(coalesce(b.delay_justification,'')),'') is null then 'تبرير مطلوب' end) issue,
 case when b.priority='حرج' and (b.due_at<now() or b.blocker_since is not null) then 'حرج' when b.blocker_since is not null or (b.status not in ('مكتمل','بانتظار المراجعة') and b.due_at<now()) or b.justification_requested_at is not null then 'عالي' else 'متوسط' end severity,
 least(coalesce(b.blocker_since,now()),coalesce(b.justification_requested_at,now()),coalesce(b.review_requested_at,now()),coalesce(b.due_at,now())) issue_since
 from base b where nullif(trim(coalesce(b.blocker_note,'')),'') is not null or (b.status not in ('مكتمل','بانتظار المراجعة') and b.due_at<now()) or b.status='بانتظار المراجعة' or (b.justification_requested_at is not null and nullif(trim(coalesce(b.delay_justification,'')),'') is null)
)
select id,name,owner_id,owner_name,priority,status,due_at,issue,severity,greatest(0,floor(extract(epoch from(now()-issue_since))/60)::int),blocker_note,justification_request_note
from flagged order by case severity when 'حرج' then 1 when 'عالي' then 2 else 3 end,due_at nulls last;
$$;

create or replace function public.get_payment_accounting_queue()
returns table(payment_id uuid,company text,beneficiary text,amount numeric,status text,executed_at timestamptz,accounting_registered_at timestamptz,deadline_at timestamptz,hours_elapsed numeric,hours_remaining numeric,sla_status text,purpose text,bank_account_id uuid)
language sql stable security definer set search_path='public','private','pg_temp' as $$
select p.id,p.company,p.beneficiary,p.amount,p.status,p.executed_at,p.accounting_registered_at,p.executed_at+interval '48 hours',
 round((extract(epoch from(now()-p.executed_at))/3600)::numeric,1),
 round((extract(epoch from((p.executed_at+interval '48 hours')-now()))/3600)::numeric,1),
 case when now()>p.executed_at+interval '48 hours' then 'Overdue' when now()>=p.executed_at+interval '36 hours' then 'Due Soon' else 'Within SLA' end,
 p.purpose,p.bank_account_id
from public.payments p
where private.current_role() in ('CFO','Supervisor','GLAccountant') and p.executed_at is not null and p.posted_at is null and p.status in ('منفذ','تم التسجيل')
order by p.executed_at;
$$;
grant execute on function public.get_payment_accounting_queue() to authenticated;

create or replace function public.supervisor_finalize_registered_payment(p_payment_id uuid,p_action text,p_reason text default null,p_pending_action text default null,p_pending_owner_id uuid default null,p_follow_up_date date default null)
returns public.payments language plpgsql security definer set search_path='public','private','pg_temp' as $$
declare v public.payments; v_role text:=private.current_role(); v_prev text;
begin
 if v_role not in ('Supervisor','CFO','GLAccountant') then raise exception 'Only GL Accountant, Supervisor or CFO can finalize registered payments'; end if;
 if p_action not in ('Posted','Pending') then raise exception 'Invalid action'; end if;
 select * into v from public.payments where id=p_payment_id for update;
 if not found then raise exception 'Payment not found'; end if;
 if v.status not in ('تم التسجيل','معلقة') or v.posted_at is not null then raise exception 'Payment must be registered and not already posted'; end if;
 v_prev:=v.status;
 if p_action='Posted' then
   update public.payments set status='مرحّل',posted_by=auth.uid(),posted_at=now(),pending_by=null,pending_at=null,pending_reason=null,pending_action=null,pending_owner_id=null,pending_follow_up_date=null,updated_at=now() where id=p_payment_id returning * into v;
   insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),case when v_role='GLAccountant' then 'PAYMENT_POSTED_BY_GL' else 'PAYMENT_POSTED_BY_SUPERVISOR' end,'payment',v.id::text,jsonb_build_object('previous_status',v_prev,'status','مرحّل','actor_role',v_role));
 else
   if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Pending justification is required'; end if;
   update public.payments set status='معلقة',pending_by=auth.uid(),pending_at=now(),pending_reason=trim(p_reason),pending_action=nullif(trim(coalesce(p_pending_action,'')),''),pending_owner_id=p_pending_owner_id,pending_follow_up_date=p_follow_up_date,updated_at=now() where id=p_payment_id returning * into v;
   insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),case when v_role='GLAccountant' then 'PAYMENT_MARKED_PENDING_BY_GL' else 'PAYMENT_MARKED_PENDING' end,'payment',v.id::text,jsonb_build_object('reason',v.pending_reason,'required_action',v.pending_action,'pending_owner_id',v.pending_owner_id,'follow_up_date',v.pending_follow_up_date,'actor_role',v_role));
 end if;
 return v;
end $$;

grant execute on function public.supervisor_finalize_registered_payment(uuid,text,text,text,uuid,date) to authenticated;

create or replace function public.cfo_override_payment_status(p_payment_id uuid,p_status text,p_reason text)
returns public.payments language plpgsql security definer set search_path='public','private','pg_temp' as $$
declare v public.payments; v_old text;
begin
 if private.current_role()<>'CFO' then raise exception 'Only CFO can override payment status'; end if;
 if p_status not in ('بانتظار مراجعة المشرف','بانتظار اعتماد CFO','معتمد للدفع','منفذ','تم التسجيل','معلقة','مرحّل','مرفوض','موقوف') then raise exception 'Invalid payment status'; end if;
 if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Override reason is required'; end if;
 select * into v from public.payments where id=p_payment_id for update;
 if not found then raise exception 'Payment not found'; end if;
 v_old:=v.status;
 update public.payments set
   status=p_status,
   executed_at=case when p_status in ('منفذ','تم التسجيل','معلقة','مرحّل') then coalesce(executed_at,now()) else executed_at end,
   executed_by=case when p_status in ('منفذ','تم التسجيل','معلقة','مرحّل') then coalesce(executed_by,auth.uid()) else executed_by end,
   accounting_registered_at=case when p_status in ('تم التسجيل','معلقة','مرحّل') then coalesce(accounting_registered_at,now()) else accounting_registered_at end,
   accounting_registered_by=case when p_status in ('تم التسجيل','معلقة','مرحّل') then coalesce(accounting_registered_by,auth.uid()) else accounting_registered_by end,
   pending_at=case when p_status='معلقة' then now() else pending_at end,
   pending_by=case when p_status='معلقة' then auth.uid() else pending_by end,
   pending_reason=case when p_status='معلقة' then trim(p_reason) else pending_reason end,
   posted_at=case when p_status='مرحّل' then coalesce(posted_at,now()) else posted_at end,
   posted_by=case when p_status='مرحّل' then coalesce(posted_by,auth.uid()) else posted_by end,
   updated_at=now()
 where id=p_payment_id returning * into v;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'CFO_PAYMENT_STATUS_OVERRIDE','payment',p_payment_id::text,jsonb_build_object('old_status',v_old,'new_status',p_status,'reason',trim(p_reason)));
 return v;
end $$;
grant execute on function public.cfo_override_payment_status(uuid,text,text) to authenticated;

-- Recreate team performance with operational activity metrics. Historical tasks remain untouched but task KPIs start at go-live.
drop function if exists public.get_finance_team_performance();
create function public.get_finance_team_performance()
returns table(user_id uuid,full_name text,role text,today_total integer,today_completed integer,today_overdue integer,pending_justifications integer,pending_review integer,month_total integer,month_completed integer,month_completion_rate numeric,tracked_on_time_rate numeric,close_total integer,close_completed integer,close_completion_rate numeric,today_operational_activities integer,month_operational_activities integer,payment_sla_overdue integer)
language sql stable security definer set search_path='public','private','pg_temp' as $$
with ctx as(
 select (now() at time zone 'Asia/Riyadh')::date today,date_trunc('month',now() at time zone 'Asia/Riyadh')::date month_start,private.current_role() current_role,auth.uid() current_uid,
 coalesce((select trim(both '"' from setting_value::text)::date from public.finance_settings where setting_key='daily_plan_go_live_date'),'2026-09-17'::date) go_live
),people as(
 select p.id,p.full_name,p.role from public.profiles p,ctx c where p.active=true and p.role in ('Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant') and (c.current_role in ('CFO','Supervisor') or p.id=c.current_uid)
),task_stats as(
 select pe.id,count(t.id) filter(where t.due_date=c.today and t.due_date>=c.go_live)::int today_total,count(t.id) filter(where t.due_date=c.today and t.due_date>=c.go_live and t.status='مكتمل')::int today_completed,
 count(t.id) filter(where t.due_date>=c.go_live and t.status not in ('مكتمل','بانتظار المراجعة') and private.task_deadline(t.due_date,t.due_time)<now())::int today_overdue,
 count(t.id) filter(where t.due_date>=c.go_live and t.status not in ('مكتمل','بانتظار المراجعة') and ((private.task_deadline(t.due_date,t.due_time)<now()) or t.justification_requested_at is not null) and nullif(trim(coalesce(t.delay_justification,'')),'') is null)::int pending_justifications,
 count(t.id) filter(where t.due_date>=c.go_live and t.status='بانتظار المراجعة')::int pending_review,
 count(t.id) filter(where t.due_date between greatest(c.month_start,c.go_live) and c.today)::int month_total,
 count(t.id) filter(where t.due_date between greatest(c.month_start,c.go_live) and c.today and t.status='مكتمل')::int month_completed,
 count(t.id) filter(where t.due_date between greatest(c.month_start,c.go_live) and c.today and t.status='مكتمل' and t.review_requested_at is not null)::int tracked_completed,
 count(t.id) filter(where t.due_date between greatest(c.month_start,c.go_live) and c.today and t.status='مكتمل' and t.review_requested_at is not null and t.review_requested_at<=private.task_deadline(t.due_date,t.due_time))::int tracked_on_time
 from people pe cross join ctx c left join public.tasks t on t.owner_id=pe.id group by pe.id
),close_stats as(
 select pe.id,count(m.id)::int close_total,count(m.id) filter(where m.status='مكتمل' or coalesce(m.progress,0)>=100)::int close_completed from people pe cross join ctx c left join public.monthly_close_tasks m on m.owner_id=pe.id and m.close_period=c.month_start group by pe.id
),activity_stats as(
 select pe.id,count(a.id) filter(where a.activity_date=c.today)::int today_ops,count(a.id) filter(where a.activity_date between c.month_start and c.today)::int month_ops
 from people pe cross join ctx c left join public.finance_activity_log a on a.employee_id=pe.id group by pe.id
),sla as(
 select pe.id,case when pe.role='GLAccountant' then count(p.id) filter(where p.executed_at is not null and p.posted_at is null and p.status in ('منفذ','تم التسجيل') and now()>p.executed_at+interval '48 hours')::int else 0 end overdue
 from people pe left join public.payments p on pe.role='GLAccountant' group by pe.id,pe.role
)
select pe.id,pe.full_name,pe.role,coalesce(ts.today_total,0),coalesce(ts.today_completed,0),coalesce(ts.today_overdue,0),coalesce(ts.pending_justifications,0),coalesce(ts.pending_review,0),coalesce(ts.month_total,0),coalesce(ts.month_completed,0),
case when coalesce(ts.month_total,0)=0 then 0 else round(ts.month_completed*100.0/ts.month_total,1) end,
case when coalesce(ts.tracked_completed,0)=0 then 0 else round(ts.tracked_on_time*100.0/ts.tracked_completed,1) end,
coalesce(cs.close_total,0),coalesce(cs.close_completed,0),case when coalesce(cs.close_total,0)=0 then 0 else round(cs.close_completed*100.0/cs.close_total,1) end,
coalesce(ac.today_ops,0),coalesce(ac.month_ops,0),coalesce(sl.overdue,0)
from people pe left join task_stats ts on ts.id=pe.id left join close_stats cs on cs.id=pe.id left join activity_stats ac on ac.id=pe.id left join sla sl on sl.id=pe.id
order by case pe.role when 'Supervisor' then 1 when 'BankAccountant' then 2 when 'GLAccountant' then 3 when 'ARAccountant' then 4 when 'APAccountant' then 5 else 9 end,pe.full_name;
$$;
grant execute on function public.get_finance_team_performance() to authenticated;

create or replace function public.get_finance_team_kpi_report(p_from date,p_to date)
returns table(user_id uuid,full_name text,role text,assigned_tasks integer,completed_tasks integer,on_time_tasks integer,completion_rate numeric,on_time_rate numeric,operational_activities integer,sla_overdue_activities integer,activity_breakdown jsonb)
language sql stable security definer set search_path='public','private','pg_temp' as $$
with ctx as(select coalesce(p_from,(now() at time zone 'Asia/Riyadh')::date) d1,coalesce(p_to,(now() at time zone 'Asia/Riyadh')::date) d2,private.current_role() role),people as(
 select p.id,p.full_name,p.role from public.profiles p,ctx c where p.active=true and p.role in ('Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant') and c.role in ('CFO','Supervisor')
),ts as(
 select pe.id,count(t.id)::int assigned,count(t.id) filter(where t.status='مكتمل')::int completed,count(t.id) filter(where t.status='مكتمل' and t.review_requested_at is not null and t.review_requested_at<=private.task_deadline(t.due_date,t.due_time))::int ontime from people pe cross join ctx c left join public.tasks t on t.owner_id=pe.id and t.due_date between c.d1 and c.d2 group by pe.id
),acts as(
 select pe.id,count(a.id)::int ops,count(a.id) filter(where a.sla_status='Overdue')::int overdue,coalesce(jsonb_object_agg(a.activity_type,a.cnt) filter(where a.activity_type is not null),'{}'::jsonb) breakdown
 from people pe left join (select employee_id,activity_type,count(*) cnt,max(sla_status) filter(where sla_status='Overdue') sla_status from public.finance_activity_log,ctx where activity_date between ctx.d1 and ctx.d2 group by employee_id,activity_type) a on a.employee_id=pe.id group by pe.id
)
select pe.id,pe.full_name,pe.role,coalesce(ts.assigned,0),coalesce(ts.completed,0),coalesce(ts.ontime,0),case when coalesce(ts.assigned,0)=0 then 0 else round(ts.completed*100.0/ts.assigned,1) end,case when coalesce(ts.completed,0)=0 then 0 else round(ts.ontime*100.0/ts.completed,1) end,coalesce(acts.ops,0),coalesce(acts.overdue,0),coalesce(acts.breakdown,'{}'::jsonb)
from people pe left join ts on ts.id=pe.id left join acts on acts.id=pe.id order by pe.full_name;
$$;
grant execute on function public.get_finance_team_kpi_report(date,date) to authenticated;
