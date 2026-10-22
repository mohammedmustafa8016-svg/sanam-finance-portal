
-- SANAM task business calendar: Friday/Saturday are weekly non-working days.
-- Scope: task tracking, overdue evaluation, remaining/elapsed task minutes, task timing KPIs,
-- task escalation timing, and monthly-close task overdue display.
-- No task/payment/workflow/business data is updated by this migration.
-- Stored due_date/due_time values remain unchanged.

create function private.task_is_working_day(p_date date)
returns boolean
language sql
immutable
set search_path='public','private','pg_temp'
as $function$
  select p_date is not null and extract(isodow from p_date)::int not in (5,6)
$function$;

create function private.task_next_working_day(p_date date)
returns date
language sql
immutable
set search_path='public','private','pg_temp'
as $function$
  select case
    when p_date is null then null
    when extract(isodow from p_date)::int=5 then p_date+2
    when extract(isodow from p_date)::int=6 then p_date+1
    else p_date
  end
$function$;

create function private.task_effective_due_date(p_due_date date)
returns date
language sql
immutable
set search_path='public','private','pg_temp'
as $function$
  select private.task_next_working_day(p_due_date)
$function$;

create function private.task_effective_deadline(
  p_due_date date,
  p_due_time time without time zone
)
returns timestamp with time zone
language sql
stable
set search_path='public','private','pg_temp'
as $function$
  select case
    when p_due_date is null then null
    else (
      private.task_effective_due_date(p_due_date)::timestamp
      + coalesce(p_due_time,time '23:59:59')
    ) at time zone 'Asia/Riyadh'
  end
$function$;

create function private.task_effective_due_at(p_due_at timestamp with time zone)
returns timestamp with time zone
language sql
stable
set search_path='public','private','pg_temp'
as $function$
  select case
    when p_due_at is null then null
    else private.task_effective_deadline(
      (p_due_at at time zone 'Asia/Riyadh')::date,
      (p_due_at at time zone 'Asia/Riyadh')::time
    )
  end
$function$;

create function private.task_business_minutes_between(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns bigint
language plpgsql
stable
set search_path='public','private','pg_temp'
as $function$
declare
  v_start timestamptz;
  v_end timestamptz;
  v_start_local timestamp;
  v_end_local timestamp;
  v_day date;
  v_seg_start timestamp;
  v_seg_end timestamp;
  v_total numeric:=0;
  v_sign integer:=1;
begin
  if p_start is null or p_end is null then return null; end if;
  if p_start=p_end then return 0; end if;

  if p_end<p_start then
    v_start:=p_end;
    v_end:=p_start;
    v_sign:=-1;
  else
    v_start:=p_start;
    v_end:=p_end;
  end if;

  v_start_local:=v_start at time zone 'Asia/Riyadh';
  v_end_local:=v_end at time zone 'Asia/Riyadh';
  v_day:=v_start_local::date;

  while v_day<=v_end_local::date loop
    if private.task_is_working_day(v_day) then
      v_seg_start:=greatest(v_start_local,v_day::timestamp);
      v_seg_end:=least(v_end_local,(v_day+1)::timestamp);
      if v_seg_end>v_seg_start then
        v_total:=v_total+(extract(epoch from(v_seg_end-v_seg_start))/60.0);
      end if;
    end if;
    v_day:=v_day+1;
  end loop;

  return v_sign*floor(v_total)::bigint;
end;
$function$;

comment on function private.task_is_working_day(date) is
'Task calendar helper: Sunday-Thursday are working days; Friday/Saturday are weekly holidays.';
comment on function private.task_effective_due_date(date) is
'Returns the stored task due date for working days, or the following Sunday when the stored due date is Friday/Saturday. Does not update stored data.';
comment on function private.task_business_minutes_between(timestamptz,timestamptz) is
'Counts task timeline minutes excluding all Friday/Saturday minutes in Asia/Riyadh.';

create or replace function private.task_deadline(
  p_due_date date,
  p_due_time time without time zone
)
returns timestamp with time zone
language sql
stable
set search_path='public','private','pg_temp'
as $function$
  select private.task_effective_deadline(p_due_date,p_due_time)
$function$;

create or replace function private.task_deadline_monitor_tick()
returns integer
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $function$
declare
  v_count integer:=0;
  v_rows integer:=0;
  v_today date:=(now() at time zone 'Asia/Riyadh')::date;
  v_go_live date;
begin
  -- Weekly holidays freeze task deadline alerts/escalations.
  if not private.task_is_working_day(v_today) then
    return 0;
  end if;

  select coalesce(
    (select trim(both '"' from setting_value::text)::date
     from public.finance_settings
     where setting_key='task_management_v2_go_live_date'),
    '2026-09-17'::date
  ) into v_go_live;

  insert into public.task_notifications(
    user_id,task_id,notification_type,title,message,unique_key
  )
  select
    t.owner_id,t.id,'DUE_SOON',t.name,'Task is due within 60 working minutes',
    'due-soon:'||t.id::text||':'||v_today::text
  from public.tasks t
  where t.due_date>=v_go_live
    and t.status not in ('مكتمل','بانتظار المراجعة')
    and private.task_deadline(t.due_date,t.due_time)>now()
    and private.task_business_minutes_between(
      now(),private.task_deadline(t.due_date,t.due_time)
    ) between 0 and 60
  on conflict(unique_key) do nothing;
  get diagnostics v_rows=row_count;
  v_count:=v_count+v_rows;

  insert into public.task_notifications(
    user_id,task_id,notification_type,title,message,unique_key
  )
  select
    t.owner_id,t.id,'OVERDUE',t.name,'Task is overdue',
    'overdue-owner:'||t.id::text||':'||v_today::text
  from public.tasks t
  where t.due_date>=v_go_live
    and t.status not in ('مكتمل','بانتظار المراجعة')
    and private.task_deadline(t.due_date,t.due_time)<now()
  on conflict(unique_key) do nothing;
  get diagnostics v_rows=row_count;
  v_count:=v_count+v_rows;

  insert into public.task_notifications(
    user_id,task_id,notification_type,title,message,unique_key
  )
  select
    t.reviewer_id,t.id,'OVERDUE_ESCALATION',t.name,
    'Assigned task is more than 60 working minutes overdue',
    'overdue-reviewer:'||t.id::text||':'||v_today::text
  from public.tasks t
  where t.reviewer_id is not null
    and t.due_date>=v_go_live
    and t.status not in ('مكتمل','بانتظار المراجعة')
    and private.task_deadline(t.due_date,t.due_time)<now()
    and private.task_business_minutes_between(
      private.task_deadline(t.due_date,t.due_time),now()
    )>60
  on conflict(unique_key) do nothing;
  get diagnostics v_rows=row_count;
  v_count:=v_count+v_rows;

  return v_count;
end
$function$;

-- Patch only the task-time expressions in the currently approved functions.
-- Each function keeps its signature, authorization, source selection and workflow logic.
do $patch$
declare
  r record;
  v_def text;
  v_new text;
begin
  for r in
    select p.oid,n.nspname,p.proname
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname in ('public','private')
      and p.proname in (
        'resolve_workcenter_rule',
        'get_workcenter_dashboard_v5',
        'get_readonly_workcenter_dashboard_v1',
        'get_workcenter_items',
        'get_workcenter_items_v4',
        'get_finance_team_performance',
        'get_finance_team_kpi_report',
        'get_employee_performance_report_v4',
        'get_workflow_v3_performance',
        'get_team_operations_monitor_v4',
        'get_supervisor_control_center',
        'get_workload_capacity',
        'get_escalation_center',
        'get_readonly_dashboard_snapshot',
        'get_readonly_page_snapshot'
      )
  loop
    v_def:=pg_get_functiondef(r.oid);
    v_new:=v_def;

    -- Overdue checks on derived Work Items.
    v_new:=replace(v_new,'w.due_at<now()','private.task_effective_due_at(w.due_at)<now()');
    v_new:=replace(v_new,'b.due_at<now()','private.task_effective_due_at(b.due_at)<now()');

    -- On-time/late performance classification.
    v_new:=replace(v_new,'w.completed_at<=w.due_at','w.completed_at<=private.task_effective_due_at(w.due_at)');
    v_new:=replace(v_new,'w.completed_at>w.due_at','w.completed_at>private.task_effective_due_at(w.due_at)');
    v_new:=replace(v_new,'coalesce(review_requested_at,completed_at)<=due_at',
                         'coalesce(review_requested_at,completed_at)<=private.task_effective_due_at(due_at)');

    -- Current-day task assignment uses effective working due date.
    v_new:=replace(v_new,'t.due_date=c.today','private.task_effective_due_date(t.due_date)=c.today');
    v_new:=replace(v_new,'due_date=c.today','private.task_effective_due_date(due_date)=c.today');
    v_new:=replace(v_new,'due_date=v_today','private.task_effective_due_date(due_date)=v_today');

    -- Monthly-close task overdue count: Friday/Saturday due dates roll to Sunday for timing only.
    v_new:=replace(v_new,'due_date<v_today','private.task_effective_due_date(due_date)<v_today');

    -- Work Center business-time counters.
    v_new:=replace(
      v_new,
      'floor(extract(epoch from (due_at-now()))/60)',
      'private.task_business_minutes_between(now(),private.task_effective_due_at(due_at))'
    );
    v_new:=replace(
      v_new,
      'floor(extract(epoch from(co.due_at-now()))/60)::int',
      'private.task_business_minutes_between(now(),co.due_at)::int'
    );
    v_new:=replace(
      v_new,
      'floor(extract(epoch from (b.due_at-now()))/60)::bigint',
      'private.task_business_minutes_between(now(),private.task_effective_due_at(b.due_at))'
    );
    v_new:=replace(
      v_new,
      'floor(extract(epoch from (b.due_at-coalesce(b.task_assigned_at,b.created_at)))/60)::bigint',
      'private.task_business_minutes_between(coalesce(b.task_assigned_at,b.created_at),private.task_effective_due_at(b.due_at))'
    );
    v_new:=replace(
      v_new,
      'floor(extract(epoch from (coalesce(b.completed_at,now())-b.started_at))/60)::bigint',
      'private.task_business_minutes_between(b.started_at,coalesce(b.completed_at,now()))'
    );

    -- Legacy Work Center due-today filter.
    v_new:=replace(
      v_new,
      '(b.due_at at time zone ''Asia/Riyadh'')::date=c.today',
      '(private.task_effective_due_at(b.due_at) at time zone ''Asia/Riyadh'')::date=c.today'
    );

    -- Escalation age freezes during Friday/Saturday.
    v_new:=replace(
      v_new,
      'greatest(0,floor(extract(epoch from(now()-issue_since))/60)::int)',
      'greatest(0,private.task_business_minutes_between(issue_since,now())::int)'
    );

    if v_new<>v_def then
      execute v_new;
    end if;
  end loop;
end
$patch$;

-- No grants are broadened. Helpers live in private and are used only by existing governed functions.
