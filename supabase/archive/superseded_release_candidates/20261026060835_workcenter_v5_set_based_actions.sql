-- Official Work Center V5 performance migration.
-- Replaces row-by-row action evaluation in the dashboard read path with a
-- set-based rule evaluation while preserving existing authorization semantics.
-- Validated by role/action parity, functional regression, and performance gates.

create or replace function public.get_workcenter_dashboard_v5(
  p_scope text default 'mine',
  p_filters jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,private,pg_temp
as $$
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
$$;

revoke all on function public.get_workcenter_dashboard_v5(text,jsonb) from public,anon;
grant execute on function public.get_workcenter_dashboard_v5(text,jsonb) to authenticated;
