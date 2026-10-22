-- Independent ad-hoc activity log for finance team members.
-- Additive only: does not change existing task/workflow logic or KPI formulas.

create table if not exists public.adhoc_activities (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.profiles(id),
  title text not null,
  activity_date date not null default ((now() at time zone 'Asia/Riyadh')::date),
  activity_time time without time zone not null,
  duration_minutes integer not null,
  category text,
  status text not null default 'Pending',
  approved_by uuid references public.profiles(id),
  approved_at timestamptz,
  recorded_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint adhoc_activity_title_check check (length(trim(title)) between 2 and 180),
  constraint adhoc_activity_duration_check check (duration_minutes between 5 and 720),
  constraint adhoc_activity_category_check check (
    category is null or category in (
      'BANKS','PAYMENTS','JOURNALS','CUSTOMERS','SUPPLIERS',
      'CLOSE','REPORTING','MEETING','OTHER'
    )
  ),
  constraint adhoc_activity_status_check check (status in ('Pending','Approved','Rejected'))
);

create index if not exists idx_adhoc_activities_employee_date
  on public.adhoc_activities(employee_id,activity_date desc,recorded_at desc);

create index if not exists idx_adhoc_activities_status_date
  on public.adhoc_activities(status,activity_date desc,recorded_at desc);

alter table public.adhoc_activities enable row level security;

revoke all on table public.adhoc_activities from public;
revoke all on table public.adhoc_activities from anon;
revoke all on table public.adhoc_activities from authenticated;

drop policy if exists adhoc_activities_deny_direct_access on public.adhoc_activities;
create policy adhoc_activities_deny_direct_access
on public.adhoc_activities
as restrictive
for all
to public
using (false)
with check (false);

create or replace function public.record_adhoc_activity(
  p_title text,
  p_activity_time time without time zone,
  p_duration_minutes integer,
  p_category text default null
)
returns public.adhoc_activities
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
declare
  v public.adhoc_activities;
  v_now_local timestamp without time zone := now() at time zone 'Asia/Riyadh';
  v_today date := (now() at time zone 'Asia/Riyadh')::date;
  v_time time without time zone := coalesce(p_activity_time,(now() at time zone 'Asia/Riyadh')::time);
  v_category text := nullif(trim(coalesce(p_category,'')),'');
  v_role text;
  v_finance boolean;
begin
  if auth.uid() is null then raise exception 'AUTHENTICATION_REQUIRED'; end if;

  select role,finance_team into v_role,v_finance
  from public.profiles
  where id=auth.uid() and active=true;

  if not found or coalesce(v_finance,false)=false or v_role='Viewer' then
    raise exception 'ACTIVE_FINANCE_TEAM_PROFILE_REQUIRED';
  end if;

  if length(trim(coalesce(p_title,'')))<2 then raise exception 'ACTIVITY_TITLE_REQUIRED'; end if;
  if p_duration_minutes is null or p_duration_minutes<5 or p_duration_minutes>720 then
    raise exception 'INVALID_ACTIVITY_DURATION';
  end if;
  if v_category is not null and v_category not in (
    'BANKS','PAYMENTS','JOURNALS','CUSTOMERS','SUPPLIERS',
    'CLOSE','REPORTING','MEETING','OTHER'
  ) then
    raise exception 'INVALID_ACTIVITY_CATEGORY';
  end if;

  if (v_today + v_time) > v_now_local + interval '5 minutes' then
    raise exception 'ACTIVITY_TIME_CANNOT_BE_IN_FUTURE';
  end if;


  insert into public.adhoc_activities(
    employee_id,title,activity_date,activity_time,duration_minutes,category,status
  )
  values(
    auth.uid(),trim(p_title),v_today,v_time,p_duration_minutes,v_category,'Pending'
  )
  returning * into v;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(
    auth.uid(),'ADHOC_ACTIVITY_RECORDED','adhoc_activity',v.id::text,
    jsonb_build_object(
      'activity_date',v.activity_date,
      'activity_time',v.activity_time,
      'duration_minutes',v.duration_minutes,
      'category',v.category,
      'status',v.status
    )
  );

  return v;
end
$function$;

create or replace function public.get_adhoc_activities(
  p_date_from date default null,
  p_date_to date default null
)
returns table(
  id uuid,
  employee_id uuid,
  employee_name text,
  employee_role text,
  title text,
  activity_date date,
  activity_time time without time zone,
  duration_minutes integer,
  category text,
  status text,
  approved_by uuid,
  approved_by_name text,
  approved_at timestamptz,
  recorded_at timestamptz
)
language plpgsql
stable
security definer
set search_path to 'public','private','pg_temp'
as $function$
declare
  v_role text:=private.current_role();
  v_today date:=(now() at time zone 'Asia/Riyadh')::date;
  v_from date:=coalesce(p_date_from,v_today);
  v_to date:=coalesce(p_date_to,v_today);
begin
  if auth.uid() is null then raise exception 'AUTHENTICATION_REQUIRED'; end if;
  if v_to<v_from then raise exception 'INVALID_DATE_RANGE'; end if;

  return query
  select
    a.id,a.employee_id,p.full_name,p.role,a.title,a.activity_date,a.activity_time,
    a.duration_minutes,a.category,a.status,a.approved_by,ap.full_name,a.approved_at,a.recorded_at
  from public.adhoc_activities a
  join public.profiles p on p.id=a.employee_id
  left join public.profiles ap on ap.id=a.approved_by
  where a.activity_date between v_from and v_to
    and (a.employee_id=auth.uid() or v_role in ('Supervisor','CFO'))
  order by a.activity_date desc,a.activity_time desc,a.recorded_at desc;
end
$function$;

create or replace function public.approve_adhoc_activity(
  p_activity_id uuid,
  p_approve boolean default true
)
returns public.adhoc_activities
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
declare
  v public.adhoc_activities;
  v_role text:=private.current_role();
begin
  if v_role not in ('Supervisor','CFO') then
    raise exception 'SUPERVISOR_OR_CFO_REQUIRED';
  end if;

  select * into v
  from public.adhoc_activities
  where id=p_activity_id
  for update;

  if not found then raise exception 'ACTIVITY_NOT_FOUND'; end if;
  if v.status<>'Pending' then raise exception 'ACTIVITY_ALREADY_REVIEWED'; end if;
  if v.employee_id=auth.uid() and v_role='Supervisor' then
    raise exception 'SUPERVISOR_CANNOT_APPROVE_OWN_ACTIVITY';
  end if;

  update public.adhoc_activities
  set status=case when p_approve then 'Approved' else 'Rejected' end,
      approved_by=auth.uid(),
      approved_at=now(),
      updated_at=now()
  where id=p_activity_id
  returning * into v;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(
    auth.uid(),
    case when p_approve then 'ADHOC_ACTIVITY_APPROVED' else 'ADHOC_ACTIVITY_REJECTED' end,
    'adhoc_activity',v.id::text,
    jsonb_build_object(
      'employee_id',v.employee_id,
      'duration_minutes',v.duration_minutes,
      'category',v.category,
      'status',v.status
    )
  );

  return v;
end
$function$;

create or replace function public.approve_all_adhoc_activities_today()
returns integer
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
declare
  v_role text:=private.current_role();
  v_today date:=(now() at time zone 'Asia/Riyadh')::date;
  v_count integer:=0;
begin
  if v_role not in ('Supervisor','CFO') then
    raise exception 'SUPERVISOR_OR_CFO_REQUIRED';
  end if;

  with updated as (
    update public.adhoc_activities
    set status='Approved',
        approved_by=auth.uid(),
        approved_at=now(),
        updated_at=now()
    where status='Pending'
      and activity_date=v_today
      and (v_role='CFO' or employee_id<>auth.uid())
    returning id,employee_id,duration_minutes,category
  ), audited as (
    insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
    select
      auth.uid(),'ADHOC_ACTIVITY_APPROVED','adhoc_activity',u.id::text,
      jsonb_build_object(
        'employee_id',u.employee_id,
        'duration_minutes',u.duration_minutes,
        'category',u.category,
        'status','Approved',
        'bulk',true
      )
    from updated u
    returning 1
  )
  select count(*) into v_count from audited;

  return v_count;
end
$function$;

revoke all on function public.record_adhoc_activity(text,time without time zone,integer,text) from public,anon;
grant execute on function public.record_adhoc_activity(text,time without time zone,integer,text) to authenticated,service_role;

revoke all on function public.get_adhoc_activities(date,date) from public,anon;
grant execute on function public.get_adhoc_activities(date,date) to authenticated,service_role;

revoke all on function public.approve_adhoc_activity(uuid,boolean) from public,anon;
grant execute on function public.approve_adhoc_activity(uuid,boolean) to authenticated,service_role;

revoke all on function public.approve_all_adhoc_activities_today() from public,anon;
grant execute on function public.approve_all_adhoc_activities_today() to authenticated,service_role;
