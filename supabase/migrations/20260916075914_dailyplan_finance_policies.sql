-- Daily plan catalog + Finance policies register

create table if not exists public.finance_task_catalog (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  default_owner_id uuid references public.profiles(id),
  default_priority text not null default 'عادي',
  output text,
  active boolean not null default true,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.finance_task_catalog enable row level security;
drop policy if exists finance_task_catalog_read on public.finance_task_catalog;
create policy finance_task_catalog_read on public.finance_task_catalog
for select to authenticated
using (exists(select 1 from public.profiles p where p.id=auth.uid() and p.active=true));

revoke insert, update, delete on public.finance_task_catalog from authenticated;
grant select on public.finance_task_catalog to authenticated;

create table if not exists public.finance_policies (
  id uuid primary key default gen_random_uuid(),
  policy_code text not null unique,
  title text not null,
  category text not null,
  purpose text,
  scope text,
  policy_text text not null,
  procedures text,
  responsibilities text,
  exceptions_text text,
  effective_date date,
  status text not null default 'Draft' check (status in ('Draft','Active','Suspended','Archived')),
  current_version integer not null default 1 check (current_version > 0),
  created_by uuid references public.profiles(id),
  updated_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.finance_policy_versions (
  id uuid primary key default gen_random_uuid(),
  policy_id uuid not null references public.finance_policies(id) on delete cascade,
  version_no integer not null,
  snapshot jsonb not null,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique(policy_id,version_no)
);

create table if not exists public.finance_policy_acknowledgements (
  policy_id uuid not null references public.finance_policies(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  version_no integer not null,
  acknowledged_at timestamptz not null default now(),
  primary key(policy_id,user_id,version_no)
);

alter table public.finance_policies enable row level security;
alter table public.finance_policy_versions enable row level security;
alter table public.finance_policy_acknowledgements enable row level security;

drop policy if exists finance_policies_read on public.finance_policies;
create policy finance_policies_read on public.finance_policies
for select to authenticated
using (
  exists(select 1 from public.profiles p where p.id=auth.uid() and p.active=true)
  and (status <> 'Draft' or private.current_role()='CFO')
);

drop policy if exists finance_policy_versions_read on public.finance_policy_versions;
create policy finance_policy_versions_read on public.finance_policy_versions
for select to authenticated
using (exists(select 1 from public.profiles p where p.id=auth.uid() and p.active=true));

drop policy if exists finance_policy_ack_read on public.finance_policy_acknowledgements;
create policy finance_policy_ack_read on public.finance_policy_acknowledgements
for select to authenticated
using (user_id=auth.uid() or private.current_role()='CFO');

revoke insert, update, delete on public.finance_policies from authenticated;
revoke insert, update, delete on public.finance_policy_versions from authenticated;
revoke insert, update, delete on public.finance_policy_acknowledgements from authenticated;
grant select on public.finance_policies, public.finance_policy_versions, public.finance_policy_acknowledgements to authenticated;

create or replace function private.policy_snapshot(p public.finance_policies)
returns jsonb
language sql
immutable
as $$
select jsonb_build_object(
  'policy_code',p.policy_code,'title',p.title,'category',p.category,
  'purpose',p.purpose,'scope',p.scope,'policy_text',p.policy_text,
  'procedures',p.procedures,'responsibilities',p.responsibilities,
  'exceptions_text',p.exceptions_text,'effective_date',p.effective_date,
  'status',p.status,'version_no',p.current_version
)
$$;

create or replace function public.create_finance_policy(
  p_policy_code text,
  p_title text,
  p_category text,
  p_purpose text default null,
  p_scope text default null,
  p_policy_text text default null,
  p_procedures text default null,
  p_responsibilities text default null,
  p_exceptions_text text default null,
  p_effective_date date default null,
  p_status text default 'Draft'
) returns uuid
language plpgsql security definer
set search_path='public','private','pg_temp'
as $$
declare v_id uuid; v_row public.finance_policies%rowtype;
begin
  if private.current_role()<>'CFO' then raise exception 'Only CFO can create finance policies'; end if;
  if nullif(trim(coalesce(p_policy_code,'')),'') is null or nullif(trim(coalesce(p_title,'')),'') is null or nullif(trim(coalesce(p_category,'')),'') is null or nullif(trim(coalesce(p_policy_text,'')),'') is null then
    raise exception 'Policy code, title, category and policy text are required';
  end if;
  if p_status not in ('Draft','Active','Suspended','Archived') then raise exception 'Invalid policy status'; end if;
  insert into public.finance_policies(policy_code,title,category,purpose,scope,policy_text,procedures,responsibilities,exceptions_text,effective_date,status,current_version,created_by,updated_by)
  values(trim(p_policy_code),trim(p_title),trim(p_category),nullif(trim(coalesce(p_purpose,'')),''),nullif(trim(coalesce(p_scope,'')),''),trim(p_policy_text),nullif(trim(coalesce(p_procedures,'')),''),nullif(trim(coalesce(p_responsibilities,'')),''),nullif(trim(coalesce(p_exceptions_text,'')),''),p_effective_date,p_status,1,auth.uid(),auth.uid())
  returning * into v_row;
  v_id:=v_row.id;
  insert into public.finance_policy_versions(policy_id,version_no,snapshot,created_by) values(v_id,1,private.policy_snapshot(v_row),auth.uid());
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'POLICY_CREATED','finance_policy',v_id::text,jsonb_build_object('policy_code',v_row.policy_code,'title',v_row.title,'status',v_row.status,'version',1));
  return v_id;
end $$;

create or replace function public.update_finance_policy(
  p_policy_id uuid,
  p_policy_code text,
  p_title text,
  p_category text,
  p_purpose text default null,
  p_scope text default null,
  p_policy_text text default null,
  p_procedures text default null,
  p_responsibilities text default null,
  p_exceptions_text text default null,
  p_effective_date date default null
) returns integer
language plpgsql security definer
set search_path='public','private','pg_temp'
as $$
declare v_old public.finance_policies%rowtype; v_new public.finance_policies%rowtype; v_version integer;
begin
  if private.current_role()<>'CFO' then raise exception 'Only CFO can edit finance policies'; end if;
  select * into v_old from public.finance_policies where id=p_policy_id for update;
  if not found then raise exception 'Policy not found'; end if;
  if nullif(trim(coalesce(p_policy_code,'')),'') is null or nullif(trim(coalesce(p_title,'')),'') is null or nullif(trim(coalesce(p_category,'')),'') is null or nullif(trim(coalesce(p_policy_text,'')),'') is null then
    raise exception 'Policy code, title, category and policy text are required';
  end if;
  v_version:=v_old.current_version+1;
  update public.finance_policies set
    policy_code=trim(p_policy_code), title=trim(p_title), category=trim(p_category),
    purpose=nullif(trim(coalesce(p_purpose,'')),''), scope=nullif(trim(coalesce(p_scope,'')),''),
    policy_text=trim(p_policy_text), procedures=nullif(trim(coalesce(p_procedures,'')),''),
    responsibilities=nullif(trim(coalesce(p_responsibilities,'')),''), exceptions_text=nullif(trim(coalesce(p_exceptions_text,'')),''),
    effective_date=p_effective_date, current_version=v_version, updated_by=auth.uid(), updated_at=now()
  where id=p_policy_id returning * into v_new;
  insert into public.finance_policy_versions(policy_id,version_no,snapshot,created_by) values(p_policy_id,v_version,private.policy_snapshot(v_new),auth.uid());
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'POLICY_UPDATED','finance_policy',p_policy_id::text,jsonb_build_object('old_version',v_old.current_version,'new_version',v_version,'policy_code',v_new.policy_code));
  return v_version;
end $$;

create or replace function public.set_finance_policy_status(p_policy_id uuid,p_status text)
returns void
language plpgsql security definer
set search_path='public','private','pg_temp'
as $$
declare v_old text;
begin
  if private.current_role()<>'CFO' then raise exception 'Only CFO can change policy status'; end if;
  if p_status not in ('Draft','Active','Suspended','Archived') then raise exception 'Invalid policy status'; end if;
  select status into v_old from public.finance_policies where id=p_policy_id for update;
  if not found then raise exception 'Policy not found'; end if;
  update public.finance_policies set status=p_status,updated_by=auth.uid(),updated_at=now() where id=p_policy_id;
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),case p_status when 'Active' then 'POLICY_ACTIVATED' when 'Suspended' then 'POLICY_SUSPENDED' when 'Archived' then 'POLICY_ARCHIVED' else 'POLICY_STATUS_CHANGED' end,'finance_policy',p_policy_id::text,jsonb_build_object('from',v_old,'to',p_status));
end $$;

create or replace function public.acknowledge_finance_policy(p_policy_id uuid)
returns void
language plpgsql security definer
set search_path='public','private','pg_temp'
as $$
declare v_version integer; v_status text;
begin
  if private.current_role() is null then raise exception 'Not authorized'; end if;
  select current_version,status into v_version,v_status from public.finance_policies where id=p_policy_id;
  if not found then raise exception 'Policy not found'; end if;
  if v_status<>'Active' then raise exception 'Only active policies can be acknowledged'; end if;
  insert into public.finance_policy_acknowledgements(policy_id,user_id,version_no,acknowledged_at)
  values(p_policy_id,auth.uid(),v_version,now()) on conflict(policy_id,user_id,version_no) do update set acknowledged_at=excluded.acknowledged_at;
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'POLICY_ACKNOWLEDGED','finance_policy',p_policy_id::text,jsonb_build_object('version',v_version));
end $$;

create or replace function public.get_finance_policy_register()
returns table(
  id uuid, policy_code text, title text, category text, purpose text, scope text, policy_text text,
  procedures text, responsibilities text, exceptions_text text, effective_date date, status text,
  current_version integer, created_at timestamptz, updated_at timestamptz,
  acknowledged_current boolean, acknowledged_count bigint, active_team_count bigint
)
language sql stable security definer
set search_path='public','private','pg_temp'
as $$
with team as (select count(*)::bigint c from public.profiles where active=true),
acks as (
 select a.policy_id,a.version_no,count(distinct a.user_id)::bigint c
 from public.finance_policy_acknowledgements a join public.profiles p on p.id=a.user_id and p.active=true
 group by a.policy_id,a.version_no
)
select p.id,p.policy_code,p.title,p.category,p.purpose,p.scope,p.policy_text,p.procedures,p.responsibilities,p.exceptions_text,p.effective_date,p.status,p.current_version,p.created_at,p.updated_at,
 exists(select 1 from public.finance_policy_acknowledgements a where a.policy_id=p.id and a.user_id=auth.uid() and a.version_no=p.current_version),
 coalesce(a.c,0),team.c
from public.finance_policies p
left join acks a on a.policy_id=p.id and a.version_no=p.current_version
cross join team
where private.current_role() is not null and (p.status<>'Draft' or private.current_role()='CFO')
order by case p.status when 'Active' then 1 when 'Draft' then 2 when 'Suspended' then 3 else 4 end,p.category,p.policy_code;
$$;

create or replace function public.get_finance_policy_versions(p_policy_id uuid)
returns table(version_no integer,snapshot jsonb,created_at timestamptz,created_by_name text)
language sql stable security definer
set search_path='public','private','pg_temp'
as $$
select v.version_no,v.snapshot,v.created_at,pr.full_name
from public.finance_policy_versions v left join public.profiles pr on pr.id=v.created_by
where v.policy_id=p_policy_id and private.current_role() is not null
order by v.version_no desc;
$$;

grant execute on function public.create_finance_policy(text,text,text,text,text,text,text,text,text,date,text) to authenticated;
grant execute on function public.update_finance_policy(uuid,text,text,text,text,text,text,text,text,text,date) to authenticated;
grant execute on function public.set_finance_policy_status(uuid,text) to authenticated;
grant execute on function public.acknowledge_finance_policy(uuid) to authenticated;
grant execute on function public.get_finance_policy_register() to authenticated;
grant execute on function public.get_finance_policy_versions(uuid) to authenticated;

create or replace function public.save_flexible_daily_plan(p_items jsonb)
returns integer
language plpgsql security definer
set search_path='public','private','pg_temp'
as $$
declare
  v_role text:=private.current_role(); v_today date:=(now() at time zone 'Asia/Riyadh')::date;
  v_item jsonb; v_id uuid; v_owner uuid; v_reviewer uuid; v_due_time time; v_priority text; v_name text; v_output text;
  v_owner_role text; v_count integer:=0; v_save_template boolean:=false;
begin
  if v_role not in ('CFO','Supervisor') then raise exception 'Only CFO or Supervisor can manage the daily work plan'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Daily plan must include at least one task'; end if;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_owner:=nullif(v_item->>'owner_id','')::uuid;
    if v_owner is null or not exists(select 1 from public.profiles where id=v_owner and active=true) then raise exception 'Valid owner is required'; end if;
    if coalesce(v_item->>'due_time','')='' then raise exception 'Due time is required'; end if;
    v_due_time:=(v_item->>'due_time')::time; v_priority:=coalesce(nullif(v_item->>'priority',''),'عادي');
    select role into v_owner_role from public.profiles where id=v_owner;
    if v_owner_role='Supervisor' then select id into v_reviewer from public.profiles where active=true and role='CFO' order by created_at limit 1;
    else select id into v_reviewer from public.profiles where active=true and role='Supervisor' order by created_at limit 1; end if;
    if coalesce(v_item->>'id','')<>'' then
      v_id:=(v_item->>'id')::uuid;
      if not exists(select 1 from public.tasks where id=v_id) then raise exception 'Task not found'; end if;
      if exists(select 1 from public.tasks where id=v_id and status='مكتمل') then continue; end if;
      update public.tasks set owner_id=v_owner,reviewer_id=v_reviewer,due_date=v_today,due_time=v_due_time,priority=v_priority,opened_at=coalesce(opened_at,now()),opened_by=auth.uid(),updated_at=now() where id=v_id;
      insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
      values(auth.uid(),'PLAN_EXISTING_TASK_FOR_TODAY','task',v_id::text,jsonb_build_object('owner_id',v_owner,'due_date',v_today,'due_time',v_due_time,'priority',v_priority,'operator_role',v_role));
    else
      v_name:=nullif(trim(coalesce(v_item->>'name','')),''); if v_name is null then raise exception 'Task name is required for new plan items'; end if;
      v_output:=nullif(trim(coalesce(v_item->>'output','')),''); v_save_template:=coalesce((v_item->>'save_as_template')::boolean,false);
      insert into public.tasks(name,frequency,owner_id,reviewer_id,due_date,due_time,priority,status,output,created_by,opened_at,opened_by,created_at,updated_at)
      values(v_name,'خطة اليوم',v_owner,v_reviewer,v_today,v_due_time,v_priority,'لم يبدأ',v_output,auth.uid(),now(),auth.uid(),now(),now()) returning id into v_id;
      if v_save_template then
        if v_role<>'CFO' then raise exception 'Only CFO can save a new task as a reusable template'; end if;
        insert into public.finance_task_catalog(name,default_owner_id,default_priority,output,created_by)
        values(v_name,v_owner,v_priority,v_output,auth.uid());
      end if;
      insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
      values(auth.uid(),'CREATE_DAILY_PLAN_TASK','task',v_id::text,jsonb_build_object('owner_id',v_owner,'due_date',v_today,'due_time',v_due_time,'priority',v_priority,'saved_as_template',v_save_template,'operator_role',v_role));
    end if;
    v_count:=v_count+1;
  end loop;
  return v_count;
end $$;

grant execute on function public.save_flexible_daily_plan(jsonb) to authenticated;
