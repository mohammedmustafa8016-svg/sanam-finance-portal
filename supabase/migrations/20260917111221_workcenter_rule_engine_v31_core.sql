-- Work Center V3.1 Rule Engine core hardening.
-- Applies on top of Workflow Engine V3 and the existing Work Center rule foundation.

alter table public.workcenter_action_rules
  add column if not exists effect text not null default 'ALLOW',
  add column if not exists source_guard_key text not null default 'ANY';

do $$ begin
  if not exists (select 1 from pg_constraint where conname='workcenter_action_rules_effect_check') then
    alter table public.workcenter_action_rules add constraint workcenter_action_rules_effect_check check (effect in ('ALLOW','DENY'));
  end if;
end $$;

-- Remove overly broad mutation authorization from the active matrix; explicit state rules are seeded separately.
update public.workcenter_action_rules set active=false,updated_at=now()
where active=true and status_key='*' and action_key in ('REASSIGN','CHANGE_DUE','CHANGE_PRIORITY','CHANGE_REVIEWER','FORCE_CLOSE','STAGE_OVERRIDE');

create or replace function private.workcenter_source_guard_allowed(p_handler text,p_source_type text,p_item_type text)
returns boolean language sql immutable set search_path=public,private,pg_temp as $$
select case
  when p_handler in ('PAYMENT_SUPERVISOR_APPROVE','PAYMENT_CFO_APPROVE','PAYMENT_BANK_EXECUTE','PAYMENT_ACCOUNTING_REGISTER','PAYMENT_POST') then p_source_type='payment' and p_item_type like 'PAYMENT_%'
  when p_handler in ('START','BLOCK','RESOLVE_BLOCKER','REQUEST_EXTENSION','DECIDE_EXTENSION','COMPLETE_TASK','REVIEW_TASK','REASSIGN_TASK','CHANGE_TASK','REQUEST_JUSTIFICATION') then p_source_type='task' and p_item_type='MANUAL_TASK'
  when p_handler in ('COMMENT','EVENT_ONLY','GENERIC') then true
  when p_handler='SOURCE_GUARDED' then p_source_type='task' and p_item_type='MANUAL_TASK'
  else false end;
$$;

create or replace function private.resolve_workcenter_rule(p_item_id uuid,p_action text,p_actor uuid,p_actor_role text)
returns table(rule_id text,action_key text,next_status text,audit_event text,requires_reason boolean,handler_key text,allowed boolean,denial_reason text)
language plpgsql stable security definer set search_path=public,private,pg_temp as $$
declare w public.work_items%rowtype; r public.workcenter_action_rules%rowtype; v_family text; v_overdue boolean;
begin
  select * into w from public.work_items where id=p_item_id;
  if not found then return query select null::text,p_action,null::text,null::text,false,null::text,false,'WORK_ITEM_NOT_FOUND'; return; end if;
  v_family:=private.workcenter_role_family(p_actor_role);
  select x.* into r from public.workcenter_action_rules x
  where x.active=true and x.action_key=p_action and x.status_key in (w.status,'*') and x.item_type_key in (w.item_type,'*')
    and x.role_key in (p_actor_role,v_family,case when p_actor_role='CFO' then 'Supervisor' else null end,case when p_actor_role in ('CFO','Supervisor') then 'Employee' else null end)
  order by case when x.role_key=p_actor_role then 0 when x.role_key=v_family then 1 when x.role_key='Supervisor' and p_actor_role='CFO' then 2 else 3 end,
           case when x.status_key=w.status then 0 else 1 end,
           case when x.item_type_key=w.item_type then 0 else 1 end,
           case when x.effect='DENY' then 0 else 1 end,x.sort_order limit 1;
  if r.rule_id is null then return query select null::text,p_action,null::text,null::text,false,null::text,false,'NO_MATCHING_RULE'; return; end if;
  if r.effect='DENY' then return query select r.rule_id,r.action_key,r.next_status,r.audit_event,r.requires_reason,r.handler_key,false,'EXPLICIT_DENY'; return; end if;
  if r.authorization_scope='EXACT_ROLE' and r.role_key<>p_actor_role then return query select r.rule_id,r.action_key,r.next_status,r.audit_event,r.requires_reason,r.handler_key,false,'ROLE_MISMATCH'; return; end if;
  if not private.workcenter_scope_allowed(r.authorization_scope,p_actor,p_actor_role,w.assignee_id,w.reviewer_id) then return query select r.rule_id,r.action_key,r.next_status,r.audit_event,r.requires_reason,r.handler_key,false,'AUTHORIZATION_SCOPE_DENIED'; return; end if;
  if not private.workcenter_source_guard_allowed(r.handler_key,w.source_entity_type,w.item_type) then return query select r.rule_id,r.action_key,r.next_status,r.audit_event,r.requires_reason,r.handler_key,false,'SOURCE_CONSTRAINT_DENIED'; return; end if;
  if p_action='APPROVE_COMPLETION' and p_actor=w.assignee_id and coalesce((w.metadata->>'allow_self_review')::boolean,false)=false then return query select r.rule_id,r.action_key,r.next_status,r.audit_event,r.requires_reason,r.handler_key,false,'SELF_REVIEW_DENIED'; return; end if;
  if p_action='REQUEST_JUSTIFICATION' then
    v_overdue:=w.due_at is not null and w.due_at<now() and w.status not in ('Completed','Closed','Cancelled');
    if not (w.status='Blocked' or v_overdue or coalesce((w.metadata->>'sla_breach')::boolean,false)) then return query select r.rule_id,r.action_key,r.next_status,r.audit_event,r.requires_reason,r.handler_key,false,'JUSTIFICATION_NOT_APPLICABLE'; return; end if;
  end if;
  if r.handler_key='SOURCE_GUARDED' then return query select r.rule_id,r.action_key,r.next_status,r.audit_event,r.requires_reason,r.handler_key,false,'SOURCE_GUARDED_ACTION_NOT_ENABLED'; return; end if;
  return query select r.rule_id,r.action_key,r.next_status,r.audit_event,r.requires_reason,r.handler_key,true,null::text;
end $$;

-- Preserve operational projection states instead of overwriting them during source synchronization.
create or replace function private.ensure_task_workflow_v3(p_task_id uuid) returns uuid
language plpgsql security definer set search_path=public,private,pg_temp as $$
declare t public.tasks%rowtype; v_instance uuid; v_step uuid; v_item uuid; v_status text; v_due timestamptz; v_existing_status text; v_extension_pending boolean;
begin
  if not private.workflow_v3_enabled() then return null; end if;
  select * into t from public.tasks where id=p_task_id; if not found then return null; end if;
  select w.status into v_existing_status from public.work_items w where w.source_entity_type='task' and w.source_entity_id=t.id::text and w.item_type='MANUAL_TASK' limit 1;
  select exists(select 1 from public.task_extension_requests er where er.task_id=t.id and er.status='Pending') into v_extension_pending;
  v_status:=case when t.status='مكتمل' then 'Completed' when t.status='بانتظار المراجعة' then 'Pending Review' when v_extension_pending then 'Extension Requested'
    when nullif(trim(coalesce(t.blocker_note,'')),'') is not null then 'Blocked'
    when v_existing_status in ('Paused','Waiting','Returned for Rework') and t.status<>'مكتمل' then v_existing_status
    when t.status='قيد التنفيذ' then 'In Progress' else 'Ready' end;
  v_due:=private.task_deadline(t.due_date,t.due_time);
  insert into public.workflow_instances(workflow_type,source_entity_type,source_entity_id,status,current_step_key,created_by,metadata)
  values('TASK','task',t.id::text,case when t.status='مكتمل' then 'Completed' else 'Active' end,'TASK_EXECUTION',t.created_by,jsonb_build_object('frequency',t.frequency,'output',t.output))
  on conflict(workflow_type,source_entity_type,source_entity_id) do update set status=excluded.status,metadata=public.workflow_instances.metadata||excluded.metadata,updated_at=now() returning id into v_instance;
  v_step:=private.upsert_workflow_step(v_instance,'TASK_EXECUTION',10,t.name,null,t.owner_id,t.reviewer_id,v_status,v_due,t.started_at,case when t.status='مكتمل' then coalesce(t.completed_at,t.reviewed_at) else null end,case when t.status='مكتمل' then coalesce(t.reviewed_by,t.owner_id) else null end,jsonb_build_object('task_status',t.status));
  v_item:=private.upsert_work_item(v_instance,v_step,'MANUAL_TASK','task',t.id::text,t.name,null,t.owner_id,t.reviewer_id,v_status,t.priority,v_due,t.started_at,case when t.status='مكتمل' then coalesce(t.completed_at,t.reviewed_at) else null end,case when t.status='مكتمل' then t.owner_id else null end,true,1,jsonb_build_object('task_status',t.status));
  if t.status='مكتمل' then update public.workflow_instances set completed_at=coalesce(t.completed_at,t.reviewed_at,now()),current_step_key=null where id=v_instance;
  else update public.workflow_instances set completed_at=null,current_step_key='TASK_EXECUTION' where id=v_instance; end if;
  return v_instance;
end $$;

-- Safe dispatcher wrapper. It returns structured failure and persists audit instead of losing denial details to exception rollback.
create or replace function public.try_perform_work_item_action(p_work_item_id uuid,p_action text,p_payload jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path=public,private,pg_temp as $$
declare w public.work_items%rowtype; v_result public.work_items%rowtype; r record; v_role text:=private.current_role(); v_error text;
begin
  select * into w from public.work_items where id=p_work_item_id;
  if not found then return jsonb_build_object('ok',false,'error','WORK_ITEM_NOT_FOUND'); end if;
  if not private.workcenter_rule_engine_enabled() then return jsonb_build_object('ok',false,'error','WORKCENTER_RULE_ENGINE_DISABLED','work_item_id',p_work_item_id); end if;
  select * into r from private.resolve_workcenter_rule(p_work_item_id,p_action,auth.uid(),v_role) limit 1;
  if r.rule_id is null or not coalesce(r.allowed,false) then
    insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'WORKCENTER_ACTION_DENIED','work_item',p_work_item_id::text,jsonb_build_object('requested_action',p_action,'actor_role',v_role,'rule_id',r.rule_id,'denial_reason',coalesce(r.denial_reason,'NO_RULE'),'status',w.status,'item_type',w.item_type,'source_type',w.source_entity_type,'source_id',w.source_entity_id));
    return jsonb_build_object('ok',false,'error',coalesce(r.denial_reason,'NO_RULE'),'rule_id',r.rule_id,'work_item_id',p_work_item_id);
  end if;
  begin v_result:=public.perform_work_item_action(p_work_item_id,p_action,coalesce(p_payload,'{}'::jsonb));
  exception when others then
    get stacked diagnostics v_error = message_text;
    insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'WORKCENTER_ACTION_FAILED','work_item',p_work_item_id::text,jsonb_build_object('requested_action',p_action,'actor_role',v_role,'rule_id',r.rule_id,'error',v_error,'status',w.status,'item_type',w.item_type,'source_type',w.source_entity_type,'source_id',w.source_entity_id));
    return jsonb_build_object('ok',false,'error',v_error,'rule_id',r.rule_id,'work_item_id',p_work_item_id);
  end;
  return jsonb_build_object('ok',true,'rule_id',r.rule_id,'action',p_action,'work_item',to_jsonb(v_result));
end $$;
revoke all on function public.try_perform_work_item_action(uuid,text,jsonb) from public;
grant execute on function public.try_perform_work_item_action(uuid,text,jsonb) to authenticated;

-- Role-aware list API for the future consolidated Work Center UI.
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
 when 'active' then b.assignee_id=c.uid and b.status in ('Assigned','Ready','Started','In Progress','Paused','Returned for Rework')
 when 'waiting_on_me' then (b.reviewer_id=c.uid and b.status='Pending Review') or (c.role in ('CFO','Supervisor') and b.status in ('Pending Review','Extension Requested')) or (b.assignee_id=c.uid and b.item_type in ('PAYMENT_SUPERVISOR_APPROVAL','PAYMENT_CFO_APPROVAL') and b.status='Ready')
 when 'waiting_others' then b.participated and b.status not in ('Completed','Closed','Cancelled') and b.assignee_id is distinct from c.uid
 when 'exceptions' then b.overdue or b.status in ('Blocked','Extension Requested','Returned for Rework') or coalesce((b.metadata->>'sla_breach')::boolean,false)
 when 'completed_today' then b.status='Completed' and (b.completed_at at time zone 'Asia/Riyadh')::date=c.today and ((p_scope='team' and c.role in ('CFO','Supervisor')) or b.completed_by=c.uid)
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
revoke all on function public.get_workcenter_items(text,text,jsonb) from public;
grant execute on function public.get_workcenter_items(text,text,jsonb) to authenticated;

create or replace function public.get_workcenter_summary(p_scope text default 'mine') returns jsonb
language sql stable security definer set search_path=public,private,pg_temp as $$
select jsonb_build_object('active',(select count(*) from public.get_workcenter_items('active',p_scope,'{}')),'waiting_on_me',(select count(*) from public.get_workcenter_items('waiting_on_me',p_scope,'{}')),'waiting_others',(select count(*) from public.get_workcenter_items('waiting_others',p_scope,'{}')),'exceptions',(select count(*) from public.get_workcenter_items('exceptions',p_scope,'{}')),'completed_today',(select count(*) from public.get_workcenter_items('completed_today',p_scope,'{}')));
$$;
revoke all on function public.get_workcenter_summary(text) from public;
grant execute on function public.get_workcenter_summary(text) to authenticated;

insert into public.workflow_engine_settings(setting_key,enabled,updated_at) values('workcenter_rule_engine_enabled',false,now()) on conflict(setting_key) do nothing;
