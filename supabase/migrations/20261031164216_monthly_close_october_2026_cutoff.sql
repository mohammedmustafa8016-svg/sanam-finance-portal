-- October 2026 close begins 1 November. Prior cycles remain historical records.
create or replace function private.close_work_in_scope(p_source_type text,p_source_id text)
returns boolean language sql stable security definer set search_path=public,private,pg_temp as $$
select not exists(
 select 1 from public.tasks t left join public.monthly_close_tasks m on m.id::text=t.source_entity_id
 where p_source_type='task' and t.id::text=p_source_id and t.source_entity_type='monthly_close_task'
 and (m.close_period is null or m.close_period<date '2026-10-01' or (now() at time zone 'Asia/Riyadh')::date<date '2026-11-01'));
$$;
revoke all on function private.close_work_in_scope(text,text) from public,anon,authenticated;
CREATE OR REPLACE FUNCTION private.generate_monthly_close_tasks(p_close_period date DEFAULT NULL::date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  v_period date;
  v_due_month date;
  v_inserted integer;
begin
  v_period := coalesce(
    date_trunc('month',p_close_period)::date,
    (date_trunc('month',(now() at time zone 'Asia/Riyadh'))-interval '1 month')::date
  );
  if v_period<date '2026-10-01' then return 0;end if;
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
$function$

CREATE OR REPLACE FUNCTION private.monthly_close_release_notification_tick()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
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
      and close_period>=date '2026-10-01'
      and v_today>=date '2026-11-01'
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
$function$

CREATE OR REPLACE FUNCTION private.release_monthly_close_task_internal(p_close_task_id uuid, p_actor uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
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

  if m.close_period is null or m.close_period<date '2026-10-01' then raise exception 'MONTHLY_CLOSE_HISTORICAL_CYCLE';end if;
  if (now() at time zone 'Asia/Riyadh')::date<date '2026-11-01' then raise exception 'MONTHLY_CLOSE_STARTS_NOVEMBER_2026';end if;
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
$function$

CREATE OR REPLACE FUNCTION public.release_monthly_close_ready_tasks(p_close_period date DEFAULT NULL::date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
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
      and close_period>=date '2026-10-01'
      and (now() at time zone 'Asia/Riyadh')::date>=date '2026-11-01'
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
$function$

CREATE OR REPLACE FUNCTION public.get_monthly_close_release_queue(p_close_period date DEFAULT NULL::date)
 RETURNS TABLE(close_task_id uuid, close_period date, track text, code text, name text, owner_id uuid, owner_name text, planned_start_date date, due_date date, priority text, output text, release_status text, released_at timestamp with time zone, released_by uuid, task_id uuid, task_status text, ready_to_release boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
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
    m.close_period>=date '2026-10-01'
    and (now() at time zone 'Asia/Riyadh')::date>=date '2026-11-01'
    and m.release_status='Planned'
    and m.task_id is null
    and m.planned_start_date is not null
    and m.planned_start_date<=(now() at time zone 'Asia/Riyadh')::date
  )
from public.monthly_close_tasks m
left join public.profiles p on p.id=m.owner_id
left join public.tasks t on t.id=m.task_id
where private.current_role()='CFO'
  and ((p_close_period is null and m.close_period>=date '2026-10-01') or m.close_period=p_close_period)
order by m.close_period desc,m.planned_start_date,m.track,m.code,m.name;
$function$

CREATE OR REPLACE FUNCTION public.get_workcenter_dashboard_v5(p_scope text DEFAULT 'mine'::text, p_filters jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  uid uuid:=auth.uid();
  actor_role text:=private.current_role();
  actor_family text;
  engine_enabled boolean;
  c private.workcenter_cycles%rowtype;
  items jsonb;
  people jsonb;
  stats jsonb;
  date_from date;
  date_to date;
begin
  if uid is null or actor_role is null then raise exception 'NOT_AUTHORIZED'; end if;
  if p_scope not in ('mine','team') then raise exception 'INVALID_SCOPE'; end if;
  if p_scope='team' and actor_role not in ('CFO','Supervisor') then raise exception 'TEAM_SCOPE_NOT_ALLOWED'; end if;

  actor_family:=private.workcenter_role_family(actor_role);
  engine_enabled:=private.workcenter_rule_engine_enabled();

  select * into c from private.workcenter_cycles where active;
  if not found then
    return jsonb_build_object('cycle',null,'items','[]'::jsonb,'team','[]'::jsonb,'summary','{}'::jsonb);
  end if;

  date_from:=coalesce(nullif(p_filters->>'from','')::date,(c.started_at at time zone 'Asia/Riyadh')::date);
  date_to:=coalesce(nullif(p_filters->>'to','')::date,(now() at time zone 'Asia/Riyadh')::date);
  if date_from>date_to then raise exception 'INVALID_DATE_RANGE'; end if;

  with base as materialized (
    select
      w.*,
      m.entered_at,
      pa.full_name assignee_name,
      pr.full_name reviewer_name,
      case when w.status='Completed' then w.completed_by else w.assignee_id end owner_id,
      coalesce(t.assigned_at,m.entered_at) assigned_at,
      t.result_description,
      t.quality_score,
      t.rework_count,
      t.blocker_note,
      t.review_requested_at,
      t.original_due_date,
      t.original_due_time,
      t.output task_description,
      t.source_entity_type task_source_type,
      w.status='Completed' is_completed,
      (
        w.status in ('Pending Review','Extension Requested')
        or (
          w.item_type in ('PAYMENT_SUPERVISOR_APPROVAL','PAYMENT_CFO_APPROVAL')
          and w.status in ('Ready','Assigned')
        )
      ) is_review,
      private.task_effective_due_at(w.due_at) effective_due_at
    from private.workcenter_cycle_items m
    join public.work_items w on w.id=m.work_item_id
    left join public.tasks t on w.source_entity_type='task' and t.id::text=w.source_entity_id
    left join public.profiles pa on pa.id=w.assignee_id
    left join public.profiles pr on pr.id=w.reviewer_id
    where m.cycle_id=c.id
      and private.close_work_in_scope(w.source_entity_type,w.source_entity_id)
      and w.performance_credit
      and w.status not in ('Waiting','Cancelled','Closed')
      and (
        actor_role in ('CFO','Supervisor')
        or w.assignee_id=uid
        or w.reviewer_id=uid
        or w.completed_by=uid
      )
      and (
        p_scope='team'
        or case
          when w.status='Completed' then w.completed_by=uid
          else w.assignee_id=uid
            or (w.reviewer_id=uid and w.status in ('Pending Review','Extension Requested'))
        end
      )
      and (
        nullif(p_filters->>'employee_id','') is null
        or (case when w.status='Completed' then w.completed_by else w.assignee_id end)::text=p_filters->>'employee_id'
      )
      and (nullif(p_filters->>'item_type','') is null or w.item_type=p_filters->>'item_type')
      and (nullif(p_filters->>'priority','') is null or w.priority=p_filters->>'priority')
      and (nullif(p_filters->>'search','') is null or w.title ilike '%'||(p_filters->>'search')||'%')
      and (
        w.status<>'Completed'
        or (w.completed_at at time zone 'Asia/Riyadh')::date between date_from and date_to
      )
  ),
  classified as materialized (
    select
      b.*,
      (b.effective_due_at<now() and b.status not in ('Completed','Closed','Cancelled','Waiting')) is_overdue,
      case
        when is_completed then 'completed'
        when is_review then 'reviews'
        when status in ('Blocked','Paused','Returned for Rework') then 'attention'
        else 'execution'
      end bucket,
      (
        coalesce(b.effective_due_at<now() and b.status not in ('Completed','Closed','Cancelled','Waiting'),false)
        or b.status in ('Blocked','Paused','Returned for Rework')
      ) is_attention,
      case
        when is_completed and b.effective_due_at is not null
          then coalesce(review_requested_at,completed_at)<=b.effective_due_at
        else null
      end on_time
    from base b
  ),
  action_keys as materialized (
    select distinct action_key
    from public.workcenter_action_rules
    where active and handler_key<>'SOURCE_GUARDED'
  ),
  ranked_rules as (
    select
      b.id work_item_id,
      ar.rule_id,
      ar.action_key,
      ar.next_status,
      ar.audit_event,
      ar.handler_key,
      ar.effect,
      ar.authorization_scope,
      ar.role_key,
      row_number() over (
        partition by b.id,ak.action_key
        order by
          case
            when ar.role_key=actor_role then 0
            when ar.role_key=actor_family then 1
            when ar.role_key='Supervisor' and actor_role='CFO' then 2
            else 3
          end,
          case when ar.status_key=b.status then 0 else 1 end,
          case when ar.item_type_key=b.item_type then 0 else 1 end,
          case when ar.effect='DENY' then 0 else 1 end,
          ar.sort_order
      ) rn,
      b.status,
      b.item_type,
      b.source_entity_type,
      b.assignee_id,
      b.reviewer_id,
      b.effective_due_at,
      b.metadata
    from classified b
    cross join action_keys ak
    join public.workcenter_action_rules ar
      on ar.active
     and ar.action_key=ak.action_key
     and ar.status_key in (b.status,'*')
     and ar.item_type_key in (b.item_type,'*')
     and ar.role_key in (
       actor_role,
       actor_family,
       case when actor_role='CFO' then 'Supervisor' end,
       case when actor_role in ('CFO','Supervisor') then 'Employee' end
     )
    where actor_role in ('CFO','Supervisor')
       or b.assignee_id=uid
       or b.reviewer_id=uid
  ),
  allowed_actions as (
    select r.*
    from ranked_rules r
    where r.rn=1
      and engine_enabled
      and r.handler_key<>'SOURCE_GUARDED'
      and r.effect<>'DENY'
      and not (r.authorization_scope='EXACT_ROLE' and r.role_key<>actor_role)
      and private.workcenter_scope_allowed(
        r.authorization_scope,uid,actor_role,r.assignee_id,r.reviewer_id
      )
      and private.workcenter_source_guard_allowed(
        r.handler_key,r.source_entity_type,r.item_type
      )
      and not (
        r.action_key='APPROVE_COMPLETION'
        and uid=r.assignee_id
        and coalesce((r.metadata->>'allow_self_review')::boolean,false)=false
      )
      and (
        r.action_key<>'REQUEST_JUSTIFICATION'
        or r.status='Blocked'
        or (
          r.effective_due_at is not null
          and r.effective_due_at<now()
          and r.status not in ('Completed','Closed','Cancelled')
        )
        or coalesce((r.metadata->>'sla_breach')::boolean,false)
      )
  ),
  action_sets as (
    select
      work_item_id,
      jsonb_agg(
        jsonb_build_object('action',action_key,'next_status',next_status)
        order by action_key
      ) actions,
      bool_or(
        action_key in (
          'APPROVE_COMPLETION',
          'RETURN_REWORK',
          'APPROVE_EXTENSION',
          'REJECT_EXTENSION',
          'REQUEST_EXTENSION_INFO',
          'APPROVE_PAYMENT_SUPERVISOR',
          'APPROVE_PAYMENT_CFO'
        )
      ) my_decision
    from allowed_actions
    group by work_item_id
  ),
  enriched as (
    select
      b.*,
      coalesce(a.actions,'[]'::jsonb) actions,
      coalesce(a.my_decision,false) requires_my_decision
    from classified b
    left join action_sets a on a.work_item_id=b.id
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'work_item_id',id,
        'source_type',source_entity_type,
        'source_id',source_entity_id,
        'item_type',item_type,
        'title',title,
        'assignee_id',assignee_id,
        'owner_id',owner_id,
        'assignee_name',assignee_name,
        'reviewer_id',reviewer_id,
        'reviewer_name',reviewer_name,
        'status',status,
        'priority',priority,
        'bucket',bucket,
        'is_overdue',coalesce(is_overdue,false),
        'is_attention',is_attention,
        'is_review',is_review,
        'requires_my_decision',requires_my_decision,
        'assigned_at',assigned_at,
        'entered_at',entered_at,
        'due_at',due_at,
        'started_at',started_at,
        'completed_at',completed_at,
        'completed_by',completed_by,
        'quality_score',quality_score,
        'on_time',on_time,
        'rework_count',coalesce(rework_count,0),
        'result_description',result_description,
        'blocker_note',blocker_note,
        'task_description',task_description,
        'task_source_type',task_source_type,
        'available_actions',actions,
        'remaining_minutes',
          case
            when effective_due_at is null or is_completed then null
            else private.task_business_minutes_between(now(),effective_due_at)
          end
      )
      order by is_attention desc,due_at nulls last,entered_at
    ),
    '[]'::jsonb
  )
  into items
  from enriched;

  select jsonb_build_object(
    'total',count(*),
    'execution',count(*) filter(where x->>'bucket'='execution'),
    'reviews',count(*) filter(where (x->>'is_review')::boolean),
    'attention',count(*) filter(where (x->>'is_attention')::boolean),
    'completed',count(*) filter(where x->>'bucket'='completed'),
    'ready',count(*) filter(where x->>'status' in ('Ready','Assigned') and x->>'bucket'='execution'),
    'in_progress',count(*) filter(where x->>'status' in ('Started','In Progress') and x->>'bucket'='execution'),
    'overdue',count(*) filter(where (x->>'is_overdue')::boolean),
    'my_decisions',count(*) filter(
      where (x->>'is_review')::boolean and (x->>'requires_my_decision')::boolean
    )
  )
  into stats
  from jsonb_array_elements(items) x;

  if actor_role in ('CFO','Supervisor') and p_scope='team' then
    select coalesce(jsonb_agg(z order by z->>'full_name'),'[]'::jsonb)
    into people
    from (
      select jsonb_build_object(
        'user_id',p.id,
        'full_name',p.full_name,
        'role',p.role,
        'ready',count(x) filter(where x->>'bucket'='execution' and x->>'status' in ('Assigned','Ready')),
        'in_progress',count(x) filter(where x->>'bucket'='execution' and x->>'status' in ('Started','In Progress')),
        'reviews',count(x) filter(where (x->>'is_review')::boolean),
        'attention',count(x) filter(where (x->>'is_attention')::boolean),
        'overdue',count(x) filter(where (x->>'is_overdue')::boolean),
        'completed',count(x) filter(where x->>'bucket'='completed'),
        'total',count(x),
        'quality_avg',round(avg((x->>'quality_score')::numeric) filter(where x->>'bucket'='completed'),1),
        'quality_count',count(x->>'quality_score') filter(where x->>'bucket'='completed'),
        'on_time_count',count(x) filter(where (x->>'on_time')::boolean),
        'timed_count',count(x->>'on_time'),
        'on_time_rate',
          round(
            100.0*count(x) filter(where (x->>'on_time')::boolean)
            /nullif(count(x->>'on_time'),0),
            1
          )
      ) z
      from public.profiles p
      left join jsonb_array_elements(items) x on x->>'owner_id'=p.id::text
      where p.active
        and p.role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
        and (
          nullif(p_filters->>'employee_id','') is null
          or p.id::text=p_filters->>'employee_id'
        )
      group by p.id,p.full_name,p.role
    ) q;
  else
    people:='[]'::jsonb;
  end if;

  return jsonb_build_object(
    'cycle',jsonb_build_object('id',c.id,'label',c.label,'started_at',c.started_at),
    'as_of',now(),
    'from',date_from,
    'to',date_to,
    'scope',p_scope,
    'items',items,
    'summary',stats,
    'team',people
  );
end
$function$

CREATE OR REPLACE FUNCTION public.get_finance_team_performance()
 RETURNS TABLE(user_id uuid, full_name text, role text, today_total integer, today_completed integer, today_overdue integer, pending_justifications integer, pending_review integer, month_total integer, month_completed integer, month_completion_rate numeric, tracked_on_time_rate numeric, close_total integer, close_completed integer, close_completion_rate numeric, today_operational_activities integer, month_operational_activities integer, payment_sla_overdue integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
with ctx as(
  select
    (now() at time zone 'Asia/Riyadh')::date today,
    date_trunc('month',now() at time zone 'Asia/Riyadh')::date month_start,
    private.current_role() current_role,
    auth.uid() current_uid,
    (select max(close_period) from public.monthly_close_tasks where close_period>=date '2026-10-01') active_close_period
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
        and private.task_effective_due_at(w.due_at)<now()
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
        and w.completed_at<=private.task_effective_due_at(w.due_at)
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
  left join public.work_items w on w.assignee_id=pe.id and private.close_work_in_scope(w.source_entity_type,w.source_entity_id)
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
    case when pe.role in ('GLAccountant','Supervisor') then
      count(p.id) filter(
        where p.executed_at is not null
          and p.posted_at is null
          and p.status in ('منفذ','تم التسجيل','معلقة')
          and now()>private.payment_sla_deadline(coalesce(p.accounting_registered_at,p.executed_at))
      )::int
    else 0 end overdue
  from people pe
  left join public.payments p on (pe.role='GLAccountant' and p.accounting_registered_at is null) or (pe.role='Supervisor' and p.accounting_registered_at is not null)
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
$function$



CREATE OR REPLACE FUNCTION public.get_notification_inbox_v6(p_scope text DEFAULT 'current'::text, p_unread_only boolean DEFAULT false, p_limit integer DEFAULT 30, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare uid uuid:=auth.uid(); v_cycle_id uuid; cycle_start timestamptz; result jsonb;
begin
 if uid is null or private.current_role() is null then raise exception 'NOT_AUTHORIZED'; end if;
 if p_scope is null or p_scope not in ('current','history') then raise exception 'INVALID_SCOPE'; end if;
 select id,started_at into v_cycle_id,cycle_start from private.workcenter_cycles where active;
 with owned as (
   select n.*, n.created_at>=cycle_start
     and private.close_work_in_scope('task',n.task_id::text)
     and (n.notification_type<>'MONTHLY_CLOSE_RELEASE_DUE' or (split_part(n.unique_key,':',2)>='2026-10-01' and (now() at time zone 'Asia/Riyadh')::date>=date '2026-11-01'))
     and (n.task_id is null or exists(
     select 1 from private.workcenter_cycle_items m join public.work_items w on w.id=m.work_item_id
     where m.cycle_id=v_cycle_id and w.source_entity_type='task' and w.source_entity_id=n.task_id::text
   )) as in_cycle
   from public.task_notifications n where n.user_id=uid
 ), scoped as (
   select * from owned where case when p_scope='current' then coalesce(in_cycle,false) else not coalesce(in_cycle,false) end
 ), filtered as (
   select * from scoped where not coalesce(p_unread_only,false) or read_at is null
 ), page as (
   select id,task_id,notification_type,title,message,read_at,created_at from filtered
   order by created_at desc,id desc limit least(greatest(coalesce(p_limit,30),1),100) offset greatest(coalesce(p_offset,0),0)
 ) select jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(p) order by created_at desc,id desc) from page p),'[]'::jsonb),
   'total',(select count(*) from filtered),'unread',(select count(*) from scoped where read_at is null),
   'scope',p_scope,'cycle_started_at',cycle_start) into result;
 return result;
end $function$
