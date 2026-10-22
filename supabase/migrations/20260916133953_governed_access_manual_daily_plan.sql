create table if not exists public.finance_settings (
  setting_key text primary key,
  setting_value jsonb not null,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);
insert into public.finance_settings(setting_key,setting_value,updated_at)
values
 ('daily_plan_go_live_date',to_jsonb('2026-09-17'::text),now()),
 ('auto_daily_generation_enabled','false'::jsonb,now())
on conflict(setting_key) do update set setting_value=excluded.setting_value,updated_at=now();

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
 if p_allowed and p_permission_key in ('page.dashboard','page.banks','data.bank_balances') and v_target_role not in ('CFO','Supervisor','BankAccountant') then raise exception 'Financial dashboard, liquidity and balances are restricted to CFO, Supervisor and Bank Accountant'; end if;
 insert into public.user_permissions(user_id,permission_key,allowed,updated_by,updated_at)
 values(p_user_id,p_permission_key,p_allowed,auth.uid(),now())
 on conflict(user_id,permission_key) do update set allowed=excluded.allowed,updated_by=auth.uid(),updated_at=now();
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'SET_USER_PERMISSION','profile',p_user_id::text,jsonb_build_object('permission_key',p_permission_key,'allowed',p_allowed));
end $$;

drop policy if exists bank_accounts_read on public.bank_accounts;
create policy bank_accounts_read on public.bank_accounts for select to authenticated using(public.has_user_permission('data.bank_balances'));
drop policy if exists reserve_movements_read on public.bank_reserve_movements;
create policy reserve_movements_read on public.bank_reserve_movements for select to authenticated using(public.has_user_permission('data.bank_balances'));
revoke all on public.bank_liquidity from anon;
revoke all on public.bank_liquidity from authenticated;
grant execute on function public.get_visible_bank_liquidity() to authenticated;
grant execute on function public.get_bank_account_directory() to authenticated;
grant execute on function public.get_reserve_account_monitor() to authenticated;

create or replace function private.generate_daily_tasks(p_target_date date default null::date) returns integer
language plpgsql security definer set search_path='public','private','pg_temp' as $$
declare
  v_target_date date := coalesce(p_target_date,(now() at time zone 'Asia/Riyadh')::date);
  v_inserted integer := 0;
  v_enabled boolean := coalesce((select (setting_value::text)::boolean from public.finance_settings where setting_key='auto_daily_generation_enabled'),false);
begin
  if not v_enabled then return 0; end if;
  insert into public.tasks(name,frequency,owner_id,reviewer_id,due_date,priority,status,output,created_by)
  select d.name,'يومي',d.owner_id,d.reviewer_id,v_target_date,d.priority,d.default_status,d.output,d.created_by
  from private.daily_task_templates d join public.profiles p on p.id=d.owner_id and p.active=true
  where d.active=true and not exists(select 1 from public.tasks t where t.frequency='يومي' and t.owner_id=d.owner_id and t.name=d.name and t.due_date=v_target_date);
  get diagnostics v_inserted=row_count;
  return v_inserted;
end $$;

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
   if v_save_template and coalesce(v_item->>'catalog_id','')='' then insert into public.finance_task_catalog(name,default_owner_id,default_priority,output,created_by) values(v_name,v_owner,v_priority,v_output,auth.uid()); end if;
   insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'OPEN_MANUAL_DAILY_TASK','task',v_task_id::text,jsonb_build_object('owner_id',v_owner,'due_date',v_today,'due_time',v_due_time,'priority',v_priority,'catalog_id',nullif(v_item->>'catalog_id',''),'operator_role',v_role,'saved_as_template',v_save_template));
   v_count:=v_count+1;
 end loop;
 return v_count;
end $$;
grant execute on function public.save_manual_daily_plan(jsonb) to authenticated;

create or replace function public.get_escalation_center()
returns table(task_id uuid,task_name text,owner_id uuid,owner_name text,priority text,status text,due_at timestamptz,issue text,severity text,age_minutes integer,blocker_note text,justification_note text)
language sql stable security definer set search_path='public','private','pg_temp' as $$
with ctx as(select private.current_role() current_role,coalesce((select trim(both '"' from setting_value::text)::date from public.finance_settings where setting_key='daily_plan_go_live_date'),'2026-09-17'::date) go_live),
base as(select t.*,p.full_name owner_name,private.task_deadline(t.due_date,t.due_time) due_at from public.tasks t join public.profiles p on p.id=t.owner_id,ctx c where c.current_role in ('CFO','Supervisor') and t.status<>'مكتمل' and t.due_date>=c.go_live),
flagged as(select b.*,concat_ws('، ',case when nullif(trim(coalesce(b.blocker_note,'')),'') is not null then 'تعثر' end,case when b.status not in ('مكتمل','بانتظار المراجعة') and b.due_at<now() then 'متأخر' end,case when b.status='بانتظار المراجعة' then 'بانتظار مراجعة' end,case when b.justification_requested_at is not null and nullif(trim(coalesce(b.delay_justification,'')),'') is null then 'تبرير مطلوب' end) issue,case when b.priority='حرج' and (b.due_at<now() or b.blocker_since is not null) then 'حرج' when b.blocker_since is not null or (b.status not in ('مكتمل','بانتظار المراجعة') and b.due_at<now()) or b.justification_requested_at is not null then 'عالي' else 'متوسط' end severity,least(coalesce(b.blocker_since,now()),coalesce(b.justification_requested_at,now()),coalesce(b.review_requested_at,now()),coalesce(b.due_at,now())) issue_since from base b where nullif(trim(coalesce(b.blocker_note,'')),'') is not null or (b.status not in ('مكتمل','بانتظار المراجعة') and b.due_at<now()) or b.status='بانتظار المراجعة' or (b.justification_requested_at is not null and nullif(trim(coalesce(b.delay_justification,'')),'') is null))
select id,name,owner_id,owner_name,priority,status,due_at,issue,severity,greatest(0,floor(extract(epoch from(now()-issue_since))/60)::int),blocker_note,justification_request_note from flagged order by case severity when 'حرج' then 1 when 'عالي' then 2 else 3 end,due_at nulls last;
$$;