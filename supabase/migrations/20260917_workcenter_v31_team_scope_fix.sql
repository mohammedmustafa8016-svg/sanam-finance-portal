create or replace function public.get_workcenter_items(p_tab text default 'active',p_scope text default 'mine',p_filters jsonb default '{}'::jsonb)
returns table(work_item_id uuid,workflow_instance_id uuid,item_type text,source_type text,source_id text,title text,assignee_id uuid,assignee_name text,reviewer_id uuid,reviewer_name text,status text,priority text,due_at timestamptz,started_at timestamptz,completed_at timestamptz,current_step_key text,is_overdue boolean,available_actions jsonb)
language sql stable security definer set search_path=public,private,pg_temp as $$
with ctx as (select auth.uid() uid,private.current_role() role,(now() at time zone 'Asia/Riyadh')::date today),
base as (
 select w.*,wi.current_step_key,pa.full_name assignee_name,pr.full_name reviewer_name,
   (w.due_at is not null and w.due_at<now() and w.status not in ('Completed','Closed','Cancelled')) overdue,
   exists(select 1 from public.work_items mine where mine.workflow_instance_id=w.workflow_instance_id and mine.completed_by=(select uid from ctx) and mine.status='Completed') participated
 from public.work_items w join public.workflow_instances wi on wi.id=w.workflow_instance_id
 left join public.profiles pa on pa.id=w.assignee_id left join public.profiles pr on pr.id=w.reviewer_id cross join ctx c
 where (c.role in ('CFO','Supervisor') or w.assignee_id=c.uid or w.reviewer_id=c.uid or exists(select 1 from public.work_items hx where hx.workflow_instance_id=w.workflow_instance_id and hx.completed_by=c.uid))
   and (p_scope<>'team' or c.role in ('CFO','Supervisor'))
   and (p_scope='team' or w.assignee_id=c.uid or w.reviewer_id=c.uid or exists(select 1 from public.work_items hx where hx.workflow_instance_id=w.workflow_instance_id and hx.completed_by=c.uid))
)
select b.id,b.workflow_instance_id,b.item_type,b.source_entity_type,b.source_entity_id,b.title,b.assignee_id,b.assignee_name,b.reviewer_id,b.reviewer_name,b.status,b.priority,b.due_at,b.started_at,b.completed_at,b.current_step_key,b.overdue,
 coalesce((select jsonb_agg(jsonb_build_object('rule_id',a.rule_id,'action',a.action_key,'next_status',a.next_status,'audit_event',a.audit_event,'handler',a.handler_key) order by a.action_key) from public.get_work_item_actions(b.id) a),'[]'::jsonb)
from base b cross join ctx c
where case lower(coalesce(p_tab,'active'))
 when 'active' then b.status in ('Assigned','Ready','Started','In Progress','Paused','Returned for Rework') and (((p_scope='team') and c.role in ('CFO','Supervisor')) or b.assignee_id=c.uid)
 when 'waiting_on_me' then (b.reviewer_id=c.uid and b.status='Pending Review') or ((p_scope='team') and c.role in ('CFO','Supervisor') and b.status in ('Pending Review','Extension Requested')) or (b.assignee_id=c.uid and b.item_type in ('PAYMENT_SUPERVISOR_APPROVAL','PAYMENT_CFO_APPROVAL') and b.status='Ready')
 when 'waiting_others' then b.participated and b.status not in ('Completed','Closed','Cancelled') and b.assignee_id is distinct from c.uid
 when 'exceptions' then b.overdue or b.status in ('Blocked','Extension Requested','Returned for Rework') or coalesce((b.metadata->>'sla_breach')::boolean,false)
 when 'completed_today' then b.status='Completed' and (b.completed_at at time zone 'Asia/Riyadh')::date=c.today and (((p_scope='team') and c.role in ('CFO','Supervisor')) or b.completed_by=c.uid)
 when 'all' then true else false end
 and (not (p_filters ? 'employee_id') or b.assignee_id=(p_filters->>'employee_id')::uuid)
 and (not (p_filters ? 'item_type') or b.item_type=p_filters->>'item_type')
 and (not (p_filters ? 'status') or b.status=p_filters->>'status')
 and (not (p_filters ? 'priority') or b.priority=p_filters->>'priority')
 and (not (p_filters ? 'source_type') or b.source_entity_type=p_filters->>'source_type')
 and (not coalesce((p_filters->>'due_today')::boolean,false) or (b.due_at at time zone 'Asia/Riyadh')::date=c.today)
 and (not coalesce((p_filters->>'overdue')::boolean,false) or b.overdue)
order by case when coalesce((b.metadata->>'escalated')::boolean,false) then 0 when b.overdue then 1 when b.priority in ('حرج','Critical') then 2 when b.priority in ('عالي','High') then 3 else 4 end,b.due_at nulls last,b.created_at;
$$;
