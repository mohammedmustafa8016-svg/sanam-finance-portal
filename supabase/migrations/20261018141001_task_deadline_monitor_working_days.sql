-- Freeze task deadline notifications/escalations on Friday/Saturday without changing notification records.
do $patch$
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
$patch$;
