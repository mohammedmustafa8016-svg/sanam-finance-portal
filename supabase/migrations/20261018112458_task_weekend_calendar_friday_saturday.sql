-- Friday/Saturday task business calendar. Applied to production as migration task_weekend_calendar_friday_saturday.


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


-- Freeze task deadline alerts/escalations during Friday/Saturday.
do $monitor_patch$
declare
  v_def text;
  v_new text;
begin
  select pg_get_functiondef(p.oid)
    into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='private'
    and p.proname='task_deadline_monitor_tick'
  limit 1;

  if v_def is null then
    raise exception 'task_deadline_monitor_tick not found';
  end if;

  v_new:=v_def;
  v_new:=replace(
    v_new,
    'begin select coalesce(',
    'begin if not private.task_is_working_day(v_today) then return 0; end if; select coalesce('
  );
  v_new:=replace(
    v_new,
    'private.task_deadline(t.due_date,t.due_time)<=now()+interval ''60 minutes''',
    'private.task_business_minutes_between(now(),private.task_deadline(t.due_date,t.due_time)) between 0 and 60'
  );
  v_new:=replace(
    v_new,
    'private.task_deadline(t.due_date,t.due_time)<now()-interval ''60 minutes''',
    'private.task_deadline(t.due_date,t.due_time)<now() and private.task_business_minutes_between(private.task_deadline(t.due_date,t.due_time),now())>60'
  );

  if v_new=v_def then
    raise exception 'task deadline monitor working-day patch made no change';
  end if;

  execute v_new;
end
$monitor_patch$;
