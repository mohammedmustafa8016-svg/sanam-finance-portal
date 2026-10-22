-- Workflow alignment: Work Center-backed performance, standard imprest task lifecycle,
-- and CFO-controlled monthly close release gate.
-- Additive to the current portal; existing live task states are not rewritten.

-- ============================================================
-- 1) Monthly close release gate
-- ============================================================

alter table public.monthly_close_tasks
  add column if not exists planned_start_date date,
  add column if not exists release_status text not null default 'Planned',
  add column if not exists released_at timestamptz,
  add column if not exists released_by uuid references public.profiles(id),
  add column if not exists task_id uuid references public.tasks(id),
  add column if not exists release_notified_at timestamptz;

update public.monthly_close_tasks
set planned_start_date=due_date
where planned_start_date is null
  and due_date is not null;

do $$
begin
  if not exists(
    select 1 from pg_constraint
    where conrelid='public.monthly_close_tasks'::regclass
      and conname='monthly_close_tasks_release_status_check'
  ) then
    alter table public.monthly_close_tasks
      add constraint monthly_close_tasks_release_status_check
      check (release_status in ('Planned','Released','Completed','Cancelled'));
  end if;
end
$$;

create index if not exists idx_monthly_close_release_ready
  on public.monthly_close_tasks(release_status,planned_start_date,close_period);

create unique index if not exists uq_monthly_close_task_link
  on public.monthly_close_tasks(task_id)
  where task_id is not null;

create or replace function private.generate_monthly_close_tasks(p_close_period date default null)
returns integer
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
declare
  v_period date;
  v_due_month date;
  v_inserted integer;
begin
  v_period := coalesce(
    date_trunc('month',p_close_period)::date,
    (date_trunc('month',(now() at time zone 'Asia/Riyadh'))-interval '1 month')::date
  );
  v_due_month := (v_period+interval '1 month')::date;

  insert into public.monthly_close_tasks(
    track,code,name,owner_id,progress,status,created_by,
    due_date,planned_start_date,priority,output,close_period,release_status
  )
  select
    t.track,
    t.code,
    t.name,
    t.owner_id,
    0,
    t.status,
    t.created_by,
    (v_due_month+((substring(t.code from '[0-9]+'))::int-1)*interval '1 day')::date,
    (v_due_month+((substring(t.code from '[0-9]+'))::int-1)*interval '1 day')::date,
    coalesce(t.priority,'عادي'),
    t.output,
    v_period,
    'Planned'
  from private.monthly_close_templates t
  where t.active=true
  on conflict (close_period,owner_id,track,code,name) where close_period is not null
  do nothing;

  get diagnostics v_inserted=row_count;
  return v_inserted;
end
$function$;

create or replace function private.monthly_close_release_notification_tick()
returns integer
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
declare
  v_today date := (now() at time zone 'Asia/Riyadh')::date;
  v_cfo uuid;
  r record;
  v_count integer := 0;
begin
  select id into v_cfo
  from public.profiles
  where active=true and role='CFO'
  order by created_at
  limit 1;

  if v_cfo is null then
    return 0;
  end if;

  for r in
    select close_period,count(*)::int ready_count,min(planned_start_date) first_ready_date
    from public.monthly_close_tasks
    where release_status='Planned'
      and task_id is null
      and planned_start_date is not null
      and planned_start_date<=v_today
      and close_period is not null
    group by close_period
  loop
    perform private.create_task_notification(
      v_cfo,
      null,
      'MONTHLY_CLOSE_RELEASE_DUE',
      'مهام الإقفال جاهزة للمراجعة والفتح',
      'يوجد '||r.ready_count||' من مهام إقفال '||to_char(r.close_period,'YYYY-MM')
        ||' وصلت إلى تاريخ البدء أو تجاوزته. راجع صفحة الإقفال وافتح المهام المطلوبة.',
      'MONTHLY_CLOSE_RELEASE_DUE:'||r.close_period::text||':'||v_today::text
    );

    update public.monthly_close_tasks
    set release_notified_at=coalesce(release_notified_at,now()),
        updated_at=now()
    where close_period=r.close_period
      and release_status='Planned'
      and task_id is null
      and planned_start_date<=v_today;

    v_count:=v_count+r.ready_count;
  end loop;

  return v_count;
end
$function$;

create or replace function private.release_monthly_close_task_internal(
  p_close_task_id uuid,
  p_actor uuid
)
returns uuid
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
declare
  m public.monthly_close_tasks%rowtype;
  v_task_id uuid;
  v_reviewer uuid;
  v_due_date date;
  v_due_time time without time zone := time '23:59';
begin
  select * into m
  from public.monthly_close_tasks
  where id=p_close_task_id
  for update;

  if not found then raise exception 'MONTHLY_CLOSE_ITEM_NOT_FOUND'; end if;

  if m.task_id is not null then
    return m.task_id;
  end if;

  if m.release_status<>'Planned' then
    raise exception 'MONTHLY_CLOSE_ITEM_NOT_PLANNED';
  end if;

  if m.owner_id is null then
    raise exception 'MONTHLY_CLOSE_OWNER_REQUIRED';
  end if;

  if m.planned_start_date is null then
    raise exception 'MONTHLY_CLOSE_START_DATE_REQUIRED';
  end if;

  if m.planned_start_date>(now() at time zone 'Asia/Riyadh')::date then
    raise exception 'MONTHLY_CLOSE_NOT_READY_FOR_RELEASE';
  end if;

  if exists(select 1 from public.profiles where id=m.owner_id and role='Supervisor') then
    select id into v_reviewer
    from public.profiles
    where active=true and role='CFO'
    order by created_at
    limit 1;
  else
    select id into v_reviewer
    from public.profiles
    where active=true and role='Supervisor'
    order by created_at
    limit 1;
  end if;

  if v_reviewer is null then
    raise exception 'MONTHLY_CLOSE_REVIEWER_NOT_CONFIGURED';
  end if;

  v_due_date:=coalesce(m.due_date,m.planned_start_date);

  insert into public.tasks(
    name,frequency,owner_id,reviewer_id,due_date,due_time,priority,status,output,
    created_by,opened_at,opened_by,assigned_at,assigned_by,
    source_entity_type,source_entity_id,created_at,updated_at
  )
  values(
    m.name,'شهري',m.owner_id,v_reviewer,v_due_date,v_due_time,
    coalesce(nullif(m.priority,''),'عادي'),'لم يبدأ',m.output,
    p_actor,now(),p_actor,now(),p_actor,
    'monthly_close_task',m.id::text,now(),now()
  )
  returning id into v_task_id;

  insert into public.task_activity_events(task_id,actor_id,event_type,details)
  values(
    v_task_id,p_actor,'TASK_ASSIGNED',
    jsonb_build_object(
      'owner_id',m.owner_id,
      'reviewer_id',v_reviewer,
      'due_date',v_due_date,
      'due_time',v_due_time,
      'monthly_close_task_id',m.id,
      'close_period',m.close_period
    )
  );

  perform private.notify_task_participants_v4(
    v_task_id,p_actor,'TASK_ASSIGNED','مهمة إقفال شهرية مسندة',m.name,
    'V4:CLOSE_ASSIGNED:'||v_task_id::text
  );

  perform private.ensure_task_workflow_v3(v_task_id);

  update public.monthly_close_tasks
  set release_status='Released',
      released_at=now(),
      released_by=p_actor,
      task_id=v_task_id,
      status='لم يبدأ',
      progress=0,
      updated_at=now()
  where id=m.id;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(
    p_actor,'MONTHLY_CLOSE_TASK_RELEASED','monthly_close_task',m.id::text,
    jsonb_build_object(
      'task_id',v_task_id,
      'owner_id',m.owner_id,
      'reviewer_id',v_reviewer,
      'close_period',m.close_period,
      'planned_start_date',m.planned_start_date,
      'due_date',v_due_date
    )
  );

  return v_task_id;
end
$function$;

create or replace function public.get_monthly_close_release_queue(
  p_close_period date default null
)
returns table(
  close_task_id uuid,
  close_period date,
  track text,
  code text,
  name text,
  owner_id uuid,
  owner_name text,
  planned_start_date date,
  due_date date,
  priority text,
  output text,
  release_status text,
  released_at timestamptz,
  released_by uuid,
  task_id uuid,
  task_status text,
  ready_to_release boolean
)
language sql
stable
security definer
set search_path to 'public','private','pg_temp'
as $function$
select
  m.id,
  m.close_period,
  m.track,
  m.code,
  m.name,
  m.owner_id,
  p.full_name,
  m.planned_start_date,
  m.due_date,
  m.priority,
  m.output,
  m.release_status,
  m.released_at,
  m.released_by,
  m.task_id,
  t.status,
  (
    m.release_status='Planned'
    and m.task_id is null
    and m.planned_start_date is not null
    and m.planned_start_date<=(now() at time zone 'Asia/Riyadh')::date
  )
from public.monthly_close_tasks m
left join public.profiles p on p.id=m.owner_id
left join public.tasks t on t.id=m.task_id
where private.current_role()='CFO'
  and (p_close_period is null or m.close_period=p_close_period)
order by m.close_period desc,m.planned_start_date,m.track,m.code,m.name;
$function$;

create or replace function public.release_monthly_close_task(p_close_task_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
begin
  if private.current_role()<>'CFO' then
    raise exception 'CFO_REQUIRED';
  end if;
  return private.release_monthly_close_task_internal(p_close_task_id,auth.uid());
end
$function$;

create or replace function public.release_monthly_close_ready_tasks(p_close_period date default null)
returns integer
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
declare
  r record;
  v_count integer:=0;
begin
  if private.current_role()<>'CFO' then
    raise exception 'CFO_REQUIRED';
  end if;

  for r in
    select id
    from public.monthly_close_tasks
    where release_status='Planned'
      and task_id is null
      and planned_start_date is not null
      and planned_start_date<=(now() at time zone 'Asia/Riyadh')::date
      and (p_close_period is null or close_period=p_close_period)
    order by planned_start_date,track,code,name
    for update skip locked
  loop
    perform private.release_monthly_close_task_internal(r.id,auth.uid());
    v_count:=v_count+1;
  end loop;

  return v_count;
end
$function$;

create or replace function private.sync_monthly_close_from_task()
returns trigger
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
begin
  if new.source_entity_type is distinct from 'monthly_close_task'
     or new.source_entity_id is null then
    return new;
  end if;

  update public.monthly_close_tasks
  set
    status=case
      when new.status='مكتمل' then 'مكتمل'
      when new.status='بانتظار المراجعة' then 'بانتظار المراجعة'
      when new.status='قيد التنفيذ' then 'قيد التنفيذ'
      else 'لم يبدأ'
    end,
    progress=case when new.status='مكتمل' then 100 else progress end,
    release_status=case when new.status='مكتمل' then 'Completed' else 'Released' end,
    updated_at=now()
  where id=new.source_entity_id::uuid;

  return new;
end
$function$;

drop trigger if exists trg_sync_monthly_close_from_task on public.tasks;
create trigger trg_sync_monthly_close_from_task
after insert or update of status,completed_at,reviewed_at
on public.tasks
for each row
execute function private.sync_monthly_close_from_task();

-- Daily Riyadh 00:15 release reminder. This does NOT release employee tasks.
do $$
declare
  v_jobid bigint;
begin
  select jobid into v_jobid
  from cron.job
  where jobname='sanam_monthly_close_release_alerts'
  limit 1;

  if v_jobid is not null then
    perform cron.unschedule(v_jobid);
  end if;

  perform cron.schedule(
    'sanam_monthly_close_release_alerts',
    '15 21 * * *',
    'select private.monthly_close_release_notification_tick();'
  );
end
$$;

-- ============================================================
-- 2) Imprest settlement tasks start at the standard Ready stage
-- ============================================================

create or replace function public.open_imprest_settlement_task(
  p_fund_id uuid,
  p_amount numeric,
  p_invoice_count integer,
  p_due_date date,
  p_due_time time without time zone,
  p_priority text default 'عادي',
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
declare
  v_role text:=private.current_role();
  v_fund public.imprest_funds%rowtype;
  v_settlement_id uuid:=gen_random_uuid();
  v_task_id uuid;
  v_supervisor uuid;
  v_open numeric:=0;
  v_available numeric:=0;
begin
  if v_role not in ('APAccountant','BankAccountant','Supervisor','CFO') then
    raise exception 'NOT_AUTHORIZED';
  end if;
  if p_amount is null or p_amount<=0 then raise exception 'SETTLEMENT_AMOUNT_REQUIRED'; end if;
  if p_invoice_count is null or p_invoice_count<1 then raise exception 'INVOICE_COUNT_REQUIRED'; end if;
  if p_due_date is null or p_due_time is null then raise exception 'DUE_DATE_TIME_REQUIRED'; end if;

  select * into v_fund
  from public.imprest_funds
  where id=p_fund_id
  for update;
  if not found then raise exception 'IMPREST_NOT_FOUND'; end if;

  select coalesce(sum(amount),0) into v_open
  from public.imprest_settlements
  where imprest_fund_id=p_fund_id
    and status in ('In Progress','Pending Review','Returned for Rework');

  v_available:=greatest(coalesce(v_fund.unsettled,0)-v_open,0);
  if coalesce(v_fund.unsettled,0)>0 and p_amount>v_available then
    raise exception 'SETTLEMENT_EXCEEDS_AVAILABLE_BALANCE';
  end if;

  v_supervisor:=private.workflow_user_for_role('Supervisor');
  if v_supervisor is null then raise exception 'SUPERVISOR_NOT_CONFIGURED'; end if;

  insert into public.imprest_settlements(
    id,imprest_fund_id,handler_id,amount,invoice_count,notes,status,created_by
  )
  values(
    v_settlement_id,p_fund_id,auth.uid(),p_amount,p_invoice_count,
    nullif(trim(coalesce(p_notes,'')),''),
    'In Progress',auth.uid()
  );

  insert into public.tasks(
    name,frequency,owner_id,reviewer_id,due_date,due_time,priority,status,output,
    created_by,opened_at,opened_by,started_at,assigned_at,assigned_by,
    source_entity_type,source_entity_id,created_at,updated_at
  )
  values(
    'تصفية عهدة — '||coalesce(v_fund.name,'')||' — '||to_char(p_amount,'FM9999999990.00'),
    'عند الطلب',auth.uid(),v_supervisor,p_due_date,p_due_time,
    coalesce(nullif(p_priority,''),'عادي'),
    'لم يبدأ',
    'تصفية عهدة بمبلغ '||to_char(p_amount,'FM9999999990.00')||' وعدد فواتير '||p_invoice_count,
    auth.uid(),now(),auth.uid(),null,now(),auth.uid(),
    'imprest_settlement',v_settlement_id::text,now(),now()
  )
  returning id into v_task_id;

  update public.imprest_settlements
  set task_id=v_task_id,updated_at=now()
  where id=v_settlement_id;

  insert into public.task_activity_events(task_id,actor_id,event_type,details)
  values(
    v_task_id,auth.uid(),'TASK_ASSIGNED',
    jsonb_build_object(
      'owner_id',auth.uid(),
      'reviewer_id',v_supervisor,
      'due_date',p_due_date,
      'due_time',p_due_time,
      'source','imprest_settlement'
    )
  );

  perform private.notify_task_participants_v4(
    v_task_id,auth.uid(),'TASK_ASSIGNED','مهمة جديدة مسندة',
    'تصفية عهدة — '||coalesce(v_fund.name,'')||' — '||to_char(p_amount,'FM9999999990.00'),
    'V4:IMPREST_ASSIGNED:'||v_task_id::text
  );

  perform private.ensure_task_workflow_v3(v_task_id);

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(
    auth.uid(),'OPEN_IMPREST_SETTLEMENT','imprest_settlement',v_settlement_id::text,
    jsonb_build_object(
      'imprest_fund_id',p_fund_id,
      'task_id',v_task_id,
      'amount',p_amount,
      'invoice_count',p_invoice_count,
      'due_date',p_due_date,
      'due_time',p_due_time,
      'initial_task_status','لم يبدأ'
    )
  );

  return v_settlement_id;
end
$function$;

-- ============================================================
-- 3) Performance page and KPI report use Work Center/work_items
-- ============================================================

create or replace function public.get_finance_team_performance()
returns table(
  user_id uuid,
  full_name text,
  role text,
  today_total integer,
  today_completed integer,
  today_overdue integer,
  pending_justifications integer,
  pending_review integer,
  month_total integer,
  month_completed integer,
  month_completion_rate numeric,
  tracked_on_time_rate numeric,
  close_total integer,
  close_completed integer,
  close_completion_rate numeric,
  today_operational_activities integer,
  month_operational_activities integer,
  payment_sla_overdue integer
)
language sql
stable
security definer
set search_path to 'public','private','pg_temp'
as $function$
with ctx as(
  select
    (now() at time zone 'Asia/Riyadh')::date today,
    date_trunc('month',now() at time zone 'Asia/Riyadh')::date month_start,
    private.current_role() current_role,
    auth.uid() current_uid,
    (select max(close_period) from public.monthly_close_tasks) active_close_period
),
people as(
  select p.id,p.full_name,p.role
  from public.profiles p,ctx c
  where p.active=true
    and p.role in ('Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
    and (c.current_role in ('CFO','Supervisor') or p.id=c.current_uid)
),
work_stats as(
  select
    pe.id,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status<>'Waiting'
        and (
          w.status in ('Assigned','Ready','Started','In Progress','Paused','Blocked','Extension Requested','Returned for Rework','Pending Review')
          or (w.status='Completed' and (w.completed_at at time zone 'Asia/Riyadh')::date=c.today)
        )
    )::int today_total,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status='Completed'
        and (w.completed_at at time zone 'Asia/Riyadh')::date=c.today
    )::int today_completed,
    count(w.id) filter(
      where w.performance_credit=true
        and w.due_at<now()
        and w.status not in ('Completed','Closed','Cancelled','Waiting')
    )::int today_overdue,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status='Pending Review'
    )::int pending_review,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status<>'Waiting'
        and (
          (w.created_at at time zone 'Asia/Riyadh')::date between c.month_start and c.today
          or (w.completed_at at time zone 'Asia/Riyadh')::date between c.month_start and c.today
        )
    )::int month_total,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status='Completed'
        and (w.completed_at at time zone 'Asia/Riyadh')::date between c.month_start and c.today
    )::int month_completed,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status='Completed'
        and w.due_at is not null
        and (w.completed_at at time zone 'Asia/Riyadh')::date between c.month_start and c.today
    )::int tracked_completed,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status='Completed'
        and w.due_at is not null
        and w.completed_at<=w.due_at
        and (w.completed_at at time zone 'Asia/Riyadh')::date between c.month_start and c.today
    )::int tracked_on_time,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status='Completed'
        and w.item_type<>'MANUAL_TASK'
        and (w.completed_at at time zone 'Asia/Riyadh')::date=c.today
    )::int today_ops,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status='Completed'
        and w.item_type<>'MANUAL_TASK'
        and (w.completed_at at time zone 'Asia/Riyadh')::date between c.month_start and c.today
    )::int month_ops
  from people pe
  cross join ctx c
  left join public.work_items w on w.assignee_id=pe.id
  group by pe.id
),
just_stats as(
  select
    pe.id,
    count(t.id) filter(
      where t.status not in ('مكتمل','بانتظار المراجعة')
        and (
          private.task_deadline(t.due_date,t.due_time)<now()
          or t.justification_requested_at is not null
        )
        and nullif(trim(coalesce(t.delay_justification,'')),'') is null
    )::int pending_justifications
  from people pe
  left join public.tasks t on t.owner_id=pe.id
  group by pe.id
),
close_stats as(
  select
    pe.id,
    count(m.id)::int close_total,
    count(m.id) filter(where m.status='مكتمل' or coalesce(m.progress,0)>=100)::int close_completed
  from people pe
  cross join ctx c
  left join public.monthly_close_tasks m
    on m.owner_id=pe.id
   and m.close_period=c.active_close_period
  group by pe.id
),
sla as(
  select
    pe.id,
    case when pe.role='GLAccountant' then
      count(p.id) filter(
        where p.executed_at is not null
          and p.posted_at is null
          and p.status in ('منفذ','تم التسجيل')
          and now()>p.executed_at+interval '48 hours'
      )::int
    else 0 end overdue
  from people pe
  left join public.payments p on pe.role='GLAccountant'
  group by pe.id,pe.role
)
select
  pe.id,
  pe.full_name,
  pe.role,
  coalesce(ws.today_total,0),
  coalesce(ws.today_completed,0),
  coalesce(ws.today_overdue,0),
  coalesce(js.pending_justifications,0),
  coalesce(ws.pending_review,0),
  coalesce(ws.month_total,0),
  coalesce(ws.month_completed,0),
  case when coalesce(ws.month_total,0)=0 then 0
       else round(ws.month_completed*100.0/ws.month_total,1) end,
  case when coalesce(ws.tracked_completed,0)=0 then 0
       else round(ws.tracked_on_time*100.0/ws.tracked_completed,1) end,
  coalesce(cs.close_total,0),
  coalesce(cs.close_completed,0),
  case when coalesce(cs.close_total,0)=0 then 0
       else round(cs.close_completed*100.0/cs.close_total,1) end,
  coalesce(ws.today_ops,0),
  coalesce(ws.month_ops,0),
  coalesce(sl.overdue,0)
from people pe
left join work_stats ws on ws.id=pe.id
left join just_stats js on js.id=pe.id
left join close_stats cs on cs.id=pe.id
left join sla sl on sl.id=pe.id
order by case pe.role
  when 'Supervisor' then 1
  when 'BankAccountant' then 2
  when 'GLAccountant' then 3
  when 'ARAccountant' then 4
  when 'APAccountant' then 5
  else 9 end,pe.full_name;
$function$;

create or replace function public.get_finance_team_kpi_report(
  p_from date,
  p_to date
)
returns table(
  user_id uuid,
  full_name text,
  role text,
  assigned_tasks integer,
  completed_tasks integer,
  on_time_tasks integer,
  completion_rate numeric,
  on_time_rate numeric,
  operational_activities integer,
  sla_overdue_activities integer,
  activity_breakdown jsonb
)
language sql
stable
security definer
set search_path to 'public','private','pg_temp'
as $function$
with ctx as(
  select
    coalesce(p_from,(now() at time zone 'Asia/Riyadh')::date) d1,
    coalesce(p_to,(now() at time zone 'Asia/Riyadh')::date) d2,
    private.current_role() role
),
people as(
  select p.id,p.full_name,p.role
  from public.profiles p,ctx c
  where p.active=true
    and p.role in ('Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
    and c.role in ('CFO','Supervisor')
),
stats as(
  select
    pe.id,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status<>'Waiting'
        and (
          (w.created_at at time zone 'Asia/Riyadh')::date between c.d1 and c.d2
          or (w.completed_at at time zone 'Asia/Riyadh')::date between c.d1 and c.d2
        )
    )::int assigned,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status='Completed'
        and (w.completed_at at time zone 'Asia/Riyadh')::date between c.d1 and c.d2
    )::int completed,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status='Completed'
        and w.due_at is not null
        and w.completed_at<=w.due_at
        and (w.completed_at at time zone 'Asia/Riyadh')::date between c.d1 and c.d2
    )::int ontime,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status='Completed'
        and w.item_type<>'MANUAL_TASK'
        and (w.completed_at at time zone 'Asia/Riyadh')::date between c.d1 and c.d2
    )::int ops,
    count(w.id) filter(
      where w.performance_credit=true
        and (
          (w.status='Completed' and w.due_at is not null and w.completed_at>w.due_at
           and (w.completed_at at time zone 'Asia/Riyadh')::date between c.d1 and c.d2)
          or
          (w.status not in ('Completed','Closed','Cancelled','Waiting')
           and w.due_at<now()
           and (w.created_at at time zone 'Asia/Riyadh')::date<=c.d2)
        )
    )::int overdue
  from people pe
  cross join ctx c
  left join public.work_items w on w.assignee_id=pe.id
  group by pe.id
),
breakdown as(
  select
    pe.id,
    coalesce(jsonb_object_agg(x.item_type,x.cnt) filter(where x.item_type is not null),'{}'::jsonb) data
  from people pe
  left join lateral(
    select w.item_type,count(*)::int cnt
    from public.work_items w,ctx c
    where w.assignee_id=pe.id
      and w.performance_credit=true
      and w.status='Completed'
      and (w.completed_at at time zone 'Asia/Riyadh')::date between c.d1 and c.d2
    group by w.item_type
  ) x on true
  group by pe.id
)
select
  pe.id,
  pe.full_name,
  pe.role,
  coalesce(s.assigned,0),
  coalesce(s.completed,0),
  coalesce(s.ontime,0),
  case when coalesce(s.assigned,0)=0 then 0
       else round(s.completed*100.0/s.assigned,1) end,
  case when coalesce(s.completed,0)=0 then 0
       else round(s.ontime*100.0/s.completed,1) end,
  coalesce(s.ops,0),
  coalesce(s.overdue,0),
  coalesce(b.data,'{}'::jsonb)
from people pe
left join stats s on s.id=pe.id
left join breakdown b on b.id=pe.id
order by pe.full_name;
$function$;

-- Monitor the new reminder job in the existing automation-health page.
create or replace function public.get_automation_health()
returns table(
  system_name text,
  job_name text,
  active boolean,
  schedule text,
  last_run_at timestamptz,
  last_status text,
  next_run_at timestamptz,
  missing_count integer,
  detail text
)
language sql
stable
security definer
set search_path to 'public','private','cron','pg_temp'
as $function$
with ctx as(
  select
    private.current_role() current_role,
    (now() at time zone 'Asia/Riyadh') local_now,
    (now() at time zone 'Asia/Riyadh')::date local_date
),
jobs as(
  select j.jobid,j.jobname,j.active,j.schedule
  from cron.job j,ctx c
  where c.current_role in ('CFO','Supervisor')
    and j.jobname in (
      'sanam_generate_daily_tasks',
      'sanam_generate_monthly_close_tasks',
      'sanam_monthly_close_release_alerts',
      'sanam_task_v2_deadline_monitor'
    )
),
latest as(
  select j.*,r.start_time,r.status,r.return_message
  from jobs j
  left join lateral(
    select d.start_time,d.status,d.return_message
    from cron.job_run_details d
    where d.jobid=j.jobid
    order by d.start_time desc
    limit 1
  ) r on true
),
counts as(
  select
    (select count(*)::int from private.daily_task_templates where active=true) daily_expected,
    (select count(*)::int
     from public.tasks t
     join private.daily_task_templates d
       on d.active=true and d.owner_id=t.owner_id and d.name=t.name
     where t.frequency='يومي' and t.due_date=(select local_date from ctx)) daily_actual,
    (select count(*)::int from private.monthly_close_templates where active=true) close_expected,
    (select count(*)::int
     from public.monthly_close_tasks
     where close_period=(select max(close_period) from public.monthly_close_tasks)) close_actual,
    (select count(*)::int
     from public.monthly_close_tasks
     where release_status='Planned'
       and task_id is null
       and planned_start_date<=(select local_date from ctx)) close_ready
)
select
  case l.jobname
    when 'sanam_generate_daily_tasks' then 'تجديد المهام اليومية'
    when 'sanam_generate_monthly_close_tasks' then 'تجديد خطة الإقفال الشهري'
    when 'sanam_monthly_close_release_alerts' then 'تنبيه المدير المالي لفتح مهام الإقفال'
    else 'مراقبة مواعيد المهام والتنبيهات'
  end,
  l.jobname,
  l.active,
  l.schedule,
  l.start_time,
  l.status,
  case
    when l.jobname='sanam_generate_daily_tasks' then
      ((case when (select local_now::time from ctx)<time '00:05'
        then (select local_date from ctx)
        else (select local_date+1 from ctx) end)::timestamp+time '00:05') at time zone 'Asia/Riyadh'
    when l.jobname='sanam_generate_monthly_close_tasks' then
      (date_trunc('month',(select local_date from ctx)+interval '1 month')::date::timestamp+time '00:10') at time zone 'Asia/Riyadh'
    when l.jobname='sanam_monthly_close_release_alerts' then
      (((select local_date+1 from ctx)::timestamp+time '00:15') at time zone 'Asia/Riyadh')
    else date_trunc('hour',now())+interval '1 hour'
  end,
  case
    when l.jobname='sanam_generate_daily_tasks' then greatest(0,c.daily_expected-c.daily_actual)
    when l.jobname='sanam_generate_monthly_close_tasks' then greatest(0,c.close_expected-c.close_actual)
    when l.jobname='sanam_monthly_close_release_alerts' then c.close_ready
    else 0
  end,
  coalesce(
    l.return_message,
    case
      when l.jobname='sanam_task_v2_deadline_monitor' and l.active=false then 'جاهز — ينتظر تفعيل المدير المالي'
      when l.start_time is null then 'لم يتم تسجيل تشغيل بعد'
      else '—'
    end
  )
from latest l
cross join counts c
order by l.jobname;
$function$;

revoke all on function public.get_monthly_close_release_queue(date) from public,anon;
grant execute on function public.get_monthly_close_release_queue(date) to authenticated,service_role;

revoke all on function public.release_monthly_close_task(uuid) from public,anon;
grant execute on function public.release_monthly_close_task(uuid) to authenticated,service_role;

revoke all on function public.release_monthly_close_ready_tasks(date) from public,anon;
grant execute on function public.release_monthly_close_ready_tasks(date) to authenticated,service_role;

-- Create the current CFO reminder immediately if unreleased close items are already due.
select private.monthly_close_release_notification_tick();
