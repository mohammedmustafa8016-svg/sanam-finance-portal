-- Work Center V5: isolated operational cycle. Source and performance history stay intact.
-- Qualify rule fields: output parameter action_key previously shadowed the table column.
create or replace function public.get_work_item_actions(p_work_item_id uuid)
returns table(rule_id text,action_key text,next_status text,audit_event text,handler_key text)
language plpgsql stable security definer set search_path=public,private,pg_temp as $$
declare w public.work_items%rowtype; v_role text:=private.current_role(); r record;
begin
 if auth.uid() is null or v_role is null or not private.workcenter_rule_engine_enabled() then return; end if;
 select * into w from public.work_items where id=p_work_item_id;
 if not found then return; end if;
 if v_role not in ('CFO','Supervisor') and w.assignee_id is distinct from auth.uid() and w.reviewer_id is distinct from auth.uid() then return; end if;
 for r in select distinct ar.action_key from public.workcenter_action_rules ar where ar.active and ar.handler_key<>'SOURCE_GUARDED' loop
   return query select z.rule_id,z.action_key,z.next_status,z.audit_event,z.handler_key
   from private.resolve_workcenter_rule(p_work_item_id,r.action_key,auth.uid(),v_role) z
   where z.allowed and z.handler_key<>'SOURCE_GUARDED' limit 1;
 end loop;
end $$;
revoke all on function public.get_work_item_actions(uuid) from public,anon;
grant execute on function public.get_work_item_actions(uuid) to authenticated;

create table private.workcenter_cycles (
 id uuid primary key default gen_random_uuid(),
 label text not null,
 started_at timestamptz not null default clock_timestamp(),
 active boolean not null default false,
 baseline jsonb not null default '{}'::jsonb
);
create unique index workcenter_one_active_cycle on private.workcenter_cycles(active) where active;
create table private.workcenter_cycle_items (
 cycle_id uuid not null references private.workcenter_cycles(id),
 work_item_id uuid not null references public.work_items(id),
 entered_at timestamptz not null default clock_timestamp(),
 primary key(cycle_id,work_item_id)
);
alter table private.workcenter_cycles enable row level security;
alter table private.workcenter_cycle_items enable row level security;
revoke all on private.workcenter_cycles,private.workcenter_cycle_items from public,anon,authenticated;

create function private.track_workcenter_cycle_item()
returns trigger language plpgsql security definer set search_path=public,private,pg_temp as $$
declare c private.workcenter_cycles%rowtype; source_created timestamptz; admit boolean:=false;
begin
 select * into c from private.workcenter_cycles where active;
 if not found or new.status in ('Waiting','Cancelled','Closed') then return new; end if;
 if exists(select 1 from private.workcenter_cycle_items where cycle_id=c.id and work_item_id=new.id) then return new; end if;
 if new.source_entity_type='task' then
   select created_at into source_created from public.tasks where id::text=new.source_entity_id;
 elsif new.source_entity_type='payment' then
   select created_at into source_created from public.payments where id::text=new.source_entity_id;
 else source_created:=new.created_at;
 end if;
 admit:=source_created>=c.started_at;
 -- Old payments may enter only through a newly activated or completed stage, never an unchanged sync.
 if tg_op='UPDATE' and new.source_entity_type='payment' then
   admit:=admit or (old.status='Waiting' and new.status not in ('Waiting','Completed','Closed','Cancelled'))
     or (old.status is distinct from new.status and new.status='Completed' and new.completed_at>=c.started_at);
 end if;
 if admit then
   insert into private.workcenter_cycle_items(cycle_id,work_item_id) values(c.id,new.id) on conflict do nothing;
 end if;
 return new;
end $$;
revoke all on function private.track_workcenter_cycle_item() from public,anon,authenticated;
create trigger workcenter_cycle_membership after insert or update on public.work_items
for each row execute function private.track_workcenter_cycle_item();

create function public.get_workcenter_dashboard_v5(p_scope text default 'mine',p_filters jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path=public,private,pg_temp as $$
declare uid uuid:=auth.uid(); actor_role text:=private.current_role(); c private.workcenter_cycles%rowtype;
 items jsonb; people jsonb; stats jsonb; date_from date; date_to date;
begin
 if uid is null or actor_role is null then raise exception 'NOT_AUTHORIZED'; end if;
 if p_scope not in ('mine','team') then raise exception 'INVALID_SCOPE'; end if;
 if p_scope='team' and actor_role not in ('CFO','Supervisor') then raise exception 'TEAM_SCOPE_NOT_ALLOWED'; end if;
 select * into c from private.workcenter_cycles where active;
 if not found then return jsonb_build_object('cycle',null,'items','[]'::jsonb,'team','[]'::jsonb,'summary','{}'::jsonb); end if;
 date_from:=coalesce(nullif(p_filters->>'from','')::date,(c.started_at at time zone 'Asia/Riyadh')::date);
 date_to:=coalesce(nullif(p_filters->>'to','')::date,(now() at time zone 'Asia/Riyadh')::date);
 if date_from>date_to then raise exception 'INVALID_DATE_RANGE'; end if;
 with base as (
 select w.*,m.entered_at,pa.full_name assignee_name,pr.full_name reviewer_name,
   case when w.status='Completed' then w.completed_by else w.assignee_id end owner_id,
   coalesce(t.assigned_at,m.entered_at) assigned_at,t.result_description,t.quality_score,t.rework_count,
   t.blocker_note,t.review_requested_at,t.original_due_date,t.original_due_time,t.output task_description,
   t.source_entity_type task_source_type,
   w.status='Completed' is_completed,
   (w.status in ('Pending Review','Extension Requested') or (w.item_type in ('PAYMENT_SUPERVISOR_APPROVAL','PAYMENT_CFO_APPROVAL') and w.status in ('Ready','Assigned'))) is_review,
   (w.due_at<now() and w.status not in ('Completed','Closed','Cancelled','Waiting')) is_overdue
 from private.workcenter_cycle_items m join public.work_items w on w.id=m.work_item_id
 left join public.tasks t on w.source_entity_type='task' and t.id::text=w.source_entity_id
 left join public.profiles pa on pa.id=w.assignee_id left join public.profiles pr on pr.id=w.reviewer_id
 where m.cycle_id=c.id and w.performance_credit and w.status not in ('Waiting','Cancelled','Closed')
   and (actor_role in ('CFO','Supervisor') or w.assignee_id=uid or w.reviewer_id=uid or w.completed_by=uid)
   and (p_scope='team' or (case when w.status='Completed' then w.completed_by=uid else w.assignee_id=uid or (w.reviewer_id=uid and w.status in ('Pending Review','Extension Requested')) end))
   and (nullif(p_filters->>'employee_id','') is null or (case when w.status='Completed' then w.completed_by else w.assignee_id end)::text=p_filters->>'employee_id')
   and (nullif(p_filters->>'item_type','') is null or w.item_type=p_filters->>'item_type')
   and (nullif(p_filters->>'priority','') is null or w.priority=p_filters->>'priority')
   and (nullif(p_filters->>'search','') is null or w.title ilike '%'||(p_filters->>'search')||'%')
   and (w.status<>'Completed' or (w.completed_at at time zone 'Asia/Riyadh')::date between date_from and date_to)
 ), classified as (
 select b.*,case when is_completed then 'completed' when is_review then 'reviews'
   when status in ('Blocked','Paused','Returned for Rework') then 'attention' else 'execution' end bucket,
   coalesce(is_overdue,false) or status in ('Blocked','Paused','Returned for Rework') is_attention,
   case when is_completed and due_at is not null then coalesce(review_requested_at,completed_at)<=due_at else null end on_time
 from base b
 ), enriched as (
 select b.*,coalesce(a.actions,'[]'::jsonb) actions,
   coalesce(a.my_decision,false) requires_my_decision
 from classified b
 left join lateral (
   select jsonb_agg(jsonb_build_object('action',x.action_key,'next_status',x.next_status) order by x.action_key) actions,
     bool_or(x.action_key in ('APPROVE_COMPLETION','RETURN_REWORK','APPROVE_EXTENSION','REJECT_EXTENSION','REQUEST_EXTENSION_INFO','APPROVE_PAYMENT_SUPERVISOR','APPROVE_PAYMENT_CFO')) my_decision
   from public.get_work_item_actions(b.id) x
 ) a on true
 )
 select coalesce(jsonb_agg(jsonb_build_object(
   'work_item_id',id,'source_type',source_entity_type,'source_id',source_entity_id,'item_type',item_type,
   'title',title,'assignee_id',assignee_id,'owner_id',owner_id,'assignee_name',assignee_name,'reviewer_id',reviewer_id,'reviewer_name',reviewer_name,
   'status',status,'priority',priority,'bucket',bucket,'is_overdue',coalesce(is_overdue,false),'is_attention',is_attention,
   'is_review',is_review,'requires_my_decision',requires_my_decision,'assigned_at',assigned_at,'entered_at',entered_at,
   'due_at',due_at,'started_at',started_at,'completed_at',completed_at,'completed_by',completed_by,
   'quality_score',quality_score,'on_time',on_time,'rework_count',coalesce(rework_count,0),'result_description',result_description,
   'blocker_note',blocker_note,'task_description',task_description,'task_source_type',task_source_type,
   'available_actions',actions,'remaining_minutes',case when due_at is null or is_completed then null else floor(extract(epoch from (due_at-now()))/60) end
 ) order by is_attention desc,due_at nulls last,entered_at),'[]'::jsonb) into items from enriched;
 select jsonb_build_object('total',count(*),'execution',count(*) filter(where x->>'bucket'='execution'),
   'reviews',count(*) filter(where (x->>'is_review')::boolean),'attention',count(*) filter(where (x->>'is_attention')::boolean),
   'completed',count(*) filter(where x->>'bucket'='completed'),
   'ready',count(*) filter(where x->>'status' in ('Ready','Assigned') and x->>'bucket'='execution'),
   'in_progress',count(*) filter(where x->>'status' in ('Started','In Progress') and x->>'bucket'='execution'),
   'overdue',count(*) filter(where (x->>'is_overdue')::boolean),
   'my_decisions',count(*) filter(where (x->>'is_review')::boolean and (x->>'requires_my_decision')::boolean)) into stats
 from jsonb_array_elements(items) x;
 if actor_role in ('CFO','Supervisor') and p_scope='team' then
   select coalesce(jsonb_agg(z order by z->>'full_name'),'[]'::jsonb) into people from (
   select jsonb_build_object('user_id',p.id,'full_name',p.full_name,'role',p.role,
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
     'on_time_rate',round(100.0*count(x) filter(where (x->>'on_time')::boolean)/nullif(count(x->>'on_time'),0),1)
   ) z from public.profiles p left join jsonb_array_elements(items) x on x->>'owner_id'=p.id::text
   where p.active and p.role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
     and (nullif(p_filters->>'employee_id','') is null or p.id::text=p_filters->>'employee_id')
   group by p.id,p.full_name,p.role) q;
 else people:='[]'::jsonb; end if;
 return jsonb_build_object('cycle',jsonb_build_object('id',c.id,'label',c.label,'started_at',c.started_at),
   'as_of',now(),'from',date_from,'to',date_to,'scope',p_scope,'items',items,'summary',stats,'team',people);
end $$;
revoke all on function public.get_workcenter_dashboard_v5(text,jsonb) from public,anon;
grant execute on function public.get_workcenter_dashboard_v5(text,jsonb) to authenticated;

create function public.get_workcenter_detail_v5(p_work_item_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,private,pg_temp as $$
declare w public.work_items%rowtype; actor_role text:=private.current_role(); events jsonb; comments jsonb; extensions jsonb;
begin
 if auth.uid() is null or actor_role is null then raise exception 'NOT_AUTHORIZED'; end if;
 select * into w from public.work_items where id=p_work_item_id;
 if not found then raise exception 'WORK_ITEM_NOT_FOUND'; end if;
 if actor_role not in ('CFO','Supervisor') and auth.uid() is distinct from w.assignee_id and auth.uid() is distinct from w.reviewer_id and auth.uid() is distinct from w.completed_by then raise exception 'NOT_AUTHORIZED'; end if;
 select coalesce(jsonb_agg(e order by e->>'created_at' desc),'[]'::jsonb) into events from (
   select jsonb_build_object('created_at',e.created_at,'event_type',e.event_type,'actor_name',p.full_name,'details',e.details) e
   from public.work_item_events e left join public.profiles p on p.id=e.actor_id where e.work_item_id=w.id
   union all
   select jsonb_build_object('created_at',e.created_at,'event_type',e.event_type,'actor_name',p.full_name,'details',e.details)
   from public.task_activity_events e left join public.profiles p on p.id=e.actor_id where w.source_entity_type='task' and e.task_id::text=w.source_entity_id
 ) a;
 select coalesce(jsonb_agg(jsonb_build_object('body',t.body,'author',p.full_name,'created_at',t.created_at) order by t.created_at desc),'[]'::jsonb) into comments
 from public.task_comments t left join public.profiles p on p.id=t.author_id where w.source_entity_type='task' and t.task_id::text=w.source_entity_id;
 select coalesce(jsonb_agg(jsonb_build_object('status',status,'created_at',created_at,'due_date',requested_due_date,'due_time',requested_due_time,'reason',justification,'note',supervisor_note) order by created_at desc),'[]'::jsonb) into extensions
 from public.task_extension_requests where w.source_entity_type='task' and task_id::text=w.source_entity_id;
 return jsonb_build_object('events',events,'comments',comments,'extensions',extensions);
end $$;
revoke all on function public.get_workcenter_detail_v5(uuid) from public,anon;
grant execute on function public.get_workcenter_detail_v5(uuid) to authenticated;

-- A current-cycle action guard; original modules and historical reports remain compatible.
create function public.try_perform_work_item_action_v5(p_work_item_id uuid,p_action text,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare r jsonb;
begin
 if auth.uid() is null or private.current_role() is null then raise exception 'NOT_AUTHORIZED'; end if;
 if not exists(select 1 from private.workcenter_cycle_items m join private.workcenter_cycles c on c.id=m.cycle_id and c.active where m.work_item_id=p_work_item_id) then
   return jsonb_build_object('ok',false,'error','WORK_ITEM_OUTSIDE_CURRENT_CYCLE');
 end if;
 if p_action in ('RETURN_REWORK','REPORT_BLOCKER','REQUEST_CLARIFICATION','REJECT_EXTENSION','REQUEST_EXTENSION_INFO') and nullif(trim(p_payload->>'reason'),'') is null then
   return jsonb_build_object('ok',false,'error','ACTION_REASON_REQUIRED');
 end if;
 r:=public.try_perform_work_item_action_v4(p_work_item_id,p_action,p_payload);
 return r;
end $$;
revoke all on function public.try_perform_work_item_action_v5(uuid,text,jsonb) from public,anon;
grant execute on function public.try_perform_work_item_action_v5(uuid,text,jsonb) to authenticated;

-- Deliver current work changes to authorized clients; existing SELECT RLS still applies.
do $$ begin
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='work_items') then
   alter publication supabase_realtime add table public.work_items;
 end if;
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='tasks') then
   alter publication supabase_realtime add table public.tasks;
 end if;
end $$;

