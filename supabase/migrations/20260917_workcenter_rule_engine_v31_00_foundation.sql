-- Work Center V3.1 rule engine foundation snapshot.
-- Idempotent: captures the already deployed foundation in source control.

create table if not exists public.workcenter_action_rules(
  rule_id text primary key,
  role_key text not null,
  status_key text not null,
  action_key text not null,
  item_type_key text not null default '*',
  authorization_scope text not null check (authorization_scope in ('ASSIGNEE','ACCESS','MANAGER','REVIEWER_OR_MANAGER','CFO','EXACT_ROLE','MANAGER_OR_ASSIGNEE')),
  next_status text,
  audit_event text not null,
  requires_reason boolean not null default false,
  handler_key text not null default 'GENERIC',
  sort_order integer not null default 100,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  effect text not null default 'ALLOW' check(effect in ('ALLOW','DENY')),
  source_guard_key text not null default 'ANY',
  unique(role_key,status_key,action_key,item_type_key)
);

alter table public.workcenter_action_rules enable row level security;
do $$ begin
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='workcenter_action_rules' and policyname='workcenter_action_rules_select') then
    create policy workcenter_action_rules_select on public.workcenter_action_rules for select to authenticated using(true);
  end if;
end $$;
revoke insert,update,delete on public.workcenter_action_rules from anon,authenticated;
grant select on public.workcenter_action_rules to authenticated;

insert into public.workflow_engine_settings(setting_key,enabled,updated_at)
values('workcenter_rule_engine_enabled',false,now()) on conflict(setting_key) do nothing;

create or replace function private.workcenter_rule_engine_enabled() returns boolean
language sql stable security definer set search_path=public,private,pg_temp as $$
select coalesce((select enabled from public.workflow_engine_settings where setting_key='workcenter_rule_engine_enabled'),false);
$$;

create or replace function private.workcenter_role_family(p_role text) returns text
language sql immutable as $$
select case when p_role in ('BankAccountant','GLAccountant','ARAccountant','APAccountant') then 'Employee' else p_role end;
$$;

create or replace function private.workcenter_scope_allowed(p_scope text,p_actor uuid,p_actor_role text,p_assignee uuid,p_reviewer uuid) returns boolean
language sql stable as $$
select case p_scope
 when 'ASSIGNEE' then p_actor is not null and p_actor=p_assignee
 when 'ACCESS' then p_actor_role in ('CFO','Supervisor') or p_actor=p_assignee or p_actor=p_reviewer
 when 'MANAGER' then p_actor_role in ('CFO','Supervisor')
 when 'REVIEWER_OR_MANAGER' then p_actor=p_reviewer or (p_actor_role in ('CFO','Supervisor') and p_actor is distinct from p_assignee)
 when 'CFO' then p_actor_role='CFO'
 when 'EXACT_ROLE' then true
 when 'MANAGER_OR_ASSIGNEE' then p_actor_role in ('CFO','Supervisor') or p_actor=p_assignee
 else false end;
$$;

create or replace function private.workcenter_source_guard_allowed(p_handler text,p_source_type text,p_item_type text) returns boolean
language sql immutable set search_path=public,private,pg_temp as $$
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
declare w public.work_items%rowtype; r public.workcenter_action_rules%rowtype; v_family text;
begin
 select * into w from public.work_items where id=p_item_id;
 if not found then return query select null::text,p_action,null::text,null::text,false,null::text,false,'WORK_ITEM_NOT_FOUND'; return; end if;
 v_family:=private.workcenter_role_family(p_actor_role);
 select x.* into r from public.workcenter_action_rules x where x.active=true and x.action_key=p_action and x.status_key in (w.status,'*') and x.item_type_key in (w.item_type,'*')
   and x.role_key in (p_actor_role,v_family,case when p_actor_role='CFO' then 'Supervisor' else null end,case when p_actor_role in ('CFO','Supervisor') then 'Employee' else null end)
 order by case when x.role_key=p_actor_role then 0 when x.role_key=v_family then 1 when x.role_key='Supervisor' and p_actor_role='CFO' then 2 else 3 end,
          case when x.status_key=w.status then 0 else 1 end,case when x.item_type_key=w.item_type then 0 else 1 end,x.sort_order limit 1;
 if r.rule_id is null then return query select null::text,p_action,null::text,null::text,false,null::text,false,'NO_MATCHING_RULE'; return; end if;
 if r.effect='DENY' then return query select r.rule_id,r.action_key,r.next_status,r.audit_event,r.requires_reason,r.handler_key,false,'EXPLICIT_DENY'; return; end if;
 if r.authorization_scope='EXACT_ROLE' and r.role_key<>p_actor_role then return query select r.rule_id,r.action_key,r.next_status,r.audit_event,r.requires_reason,r.handler_key,false,'ROLE_MISMATCH'; return; end if;
 if not private.workcenter_scope_allowed(r.authorization_scope,p_actor,p_actor_role,w.assignee_id,w.reviewer_id) then return query select r.rule_id,r.action_key,r.next_status,r.audit_event,r.requires_reason,r.handler_key,false,'AUTHORIZATION_SCOPE_DENIED'; return; end if;
 if not private.workcenter_source_guard_allowed(r.handler_key,w.source_entity_type,w.item_type) then return query select r.rule_id,r.action_key,r.next_status,r.audit_event,r.requires_reason,r.handler_key,false,'SOURCE_CONSTRAINT_DENIED'; return; end if;
 return query select r.rule_id,r.action_key,r.next_status,r.audit_event,r.requires_reason,r.handler_key,true,null::text;
end $$;

create or replace function private.workcenter_apply_presentational_transition(p_item_id uuid,p_next_status text,p_actor uuid,p_event text,p_details jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_step uuid; v_old text;
begin
 select status,workflow_step_id into v_old,v_step from public.work_items where id=p_item_id for update;
 if p_next_status is not null and p_next_status is distinct from v_old then
   update public.work_items set status=p_next_status,started_at=case when p_next_status='In Progress' then coalesce(started_at,now()) else started_at end,
     completed_at=case when p_next_status in ('Completed','Closed') then coalesce(completed_at,now()) else completed_at end,
     completed_by=case when p_next_status in ('Completed','Closed') then coalesce(completed_by,p_actor) else completed_by end,updated_at=now() where id=p_item_id;
   if v_step is not null then
     update public.workflow_steps set status=p_next_status,started_at=case when p_next_status='In Progress' then coalesce(started_at,now()) else started_at end,
       completed_at=case when p_next_status in ('Completed','Closed') then coalesce(completed_at,now()) else completed_at end,
       completed_by=case when p_next_status in ('Completed','Closed') then coalesce(completed_by,p_actor) else completed_by end,updated_at=now() where id=v_step;
   end if;
 end if;
 insert into public.work_item_events(work_item_id,actor_id,event_type,details) values(p_item_id,p_actor,p_event,coalesce(p_details,'{}'::jsonb)||jsonb_build_object('from',v_old,'to',coalesce(p_next_status,v_old)));
end $$;

create or replace function public.get_work_item_actions(p_work_item_id uuid)
returns table(rule_id text,action_key text,next_status text,audit_event text,handler_key text)
language plpgsql stable security definer set search_path=public,private,pg_temp as $$
declare w public.work_items%rowtype; v_role text:=private.current_role(); r record;
begin
 if not private.workcenter_rule_engine_enabled() then return; end if;
 select * into w from public.work_items where id=p_work_item_id; if not found then return; end if;
 if not (v_role in ('CFO','Supervisor') or w.assignee_id=auth.uid() or w.reviewer_id=auth.uid()) then return; end if;
 for r in select distinct x.action_key from public.workcenter_action_rules x where x.active=true loop
   if exists(select 1 from private.resolve_workcenter_rule(p_work_item_id,r.action_key,auth.uid(),v_role) z where z.allowed) then
     return query select z.rule_id,z.action_key,z.next_status,z.audit_event,z.handler_key from private.resolve_workcenter_rule(p_work_item_id,r.action_key,auth.uid(),v_role) z where z.allowed limit 1;
   end if;
 end loop;
end $$;
revoke all on function public.get_work_item_actions(uuid) from public;
grant execute on function public.get_work_item_actions(uuid) to authenticated;

create or replace function public.perform_work_item_action(p_work_item_id uuid,p_action text,p_payload jsonb default '{}'::jsonb) returns public.work_items
language plpgsql security definer set search_path=public,private,pg_temp as $$
declare w public.work_items%rowtype; r record; v_role text:=private.current_role(); v_reason text; v_task public.tasks%rowtype; v_req uuid; v_due_date date; v_due_time time; v_new_owner uuid; v_result public.work_items%rowtype;
begin
 if not private.workcenter_rule_engine_enabled() then raise exception 'WORKCENTER_RULE_ENGINE_DISABLED'; end if;
 select * into w from public.work_items where id=p_work_item_id for update; if not found then raise exception 'WORK_ITEM_NOT_FOUND'; end if;
 select * into r from private.resolve_workcenter_rule(p_work_item_id,p_action,auth.uid(),v_role) limit 1;
 if r.rule_id is null or not r.allowed then raise exception 'WORKCENTER_ACTION_DENIED:%',coalesce(r.denial_reason,'NO_RULE'); end if;
 v_reason:=coalesce(nullif(trim(coalesce(p_payload->>'reason','')),''),nullif(trim(coalesce(p_payload->>'justification','')),''),nullif(trim(coalesce(p_payload->>'note','')),''));
 if r.requires_reason and v_reason is null then raise exception 'ACTION_REASON_REQUIRED'; end if;
 if r.handler_key='COMMENT' then
   if w.source_entity_type='task' then perform public.add_task_comment(w.source_entity_id::uuid,coalesce(p_payload->>'body',v_reason),coalesce(p_payload->>'comment_type','Comment'));
   else perform private.workcenter_apply_presentational_transition(w.id,null,auth.uid(),r.audit_event,p_payload); end if;
 elsif r.handler_key='EVENT_ONLY' then perform private.workcenter_apply_presentational_transition(w.id,r.next_status,auth.uid(),r.audit_event,p_payload);
 elsif r.handler_key='START' then
   if w.source_entity_type='task' then perform public.start_finance_task(w.source_entity_id::uuid); perform private.ensure_task_workflow_v3(w.source_entity_id::uuid);
   else perform private.workcenter_apply_presentational_transition(w.id,r.next_status,auth.uid(),r.audit_event,p_payload); end if;
 elsif r.handler_key='GENERIC' then perform private.workcenter_apply_presentational_transition(w.id,r.next_status,auth.uid(),r.audit_event,p_payload);
 elsif r.handler_key='BLOCK' then
   if w.source_entity_type='task' then perform public.mark_task_blocker(w.source_entity_id::uuid,v_reason); perform private.ensure_task_workflow_v3(w.source_entity_id::uuid); update public.work_items set status='Blocked',updated_at=now() where id=w.id;
   else perform private.workcenter_apply_presentational_transition(w.id,'Blocked',auth.uid(),r.audit_event,p_payload); end if;
 elsif r.handler_key='RESOLVE_BLOCKER' then
   if w.source_entity_type='task' then perform public.clear_task_blocker(w.source_entity_id::uuid); perform private.ensure_task_workflow_v3(w.source_entity_id::uuid);
   else perform private.workcenter_apply_presentational_transition(w.id,'In Progress',auth.uid(),r.audit_event,p_payload); end if;
 elsif r.handler_key='REQUEST_EXTENSION' then
   if w.source_entity_type<>'task' then raise exception 'SOURCE_ACTION_NOT_SUPPORTED'; end if;
   v_due_date:=(p_payload->>'requested_due_date')::date; v_due_time:=(p_payload->>'requested_due_time')::time; if v_due_date is null or v_due_time is null then raise exception 'REQUESTED_DUE_REQUIRED'; end if;
   v_req:=public.request_task_extension(w.source_entity_id::uuid,v_due_date,v_due_time,v_reason); update public.work_items set status='Extension Requested',metadata=metadata||jsonb_build_object('extension_request_id',v_req),updated_at=now() where id=w.id;
   insert into public.work_item_events(work_item_id,actor_id,event_type,details) values(w.id,auth.uid(),r.audit_event,jsonb_build_object('request_id',v_req,'requested_due_date',v_due_date,'requested_due_time',v_due_time,'reason',v_reason));
 elsif r.handler_key='DECIDE_EXTENSION' then
   if w.source_entity_type<>'task' then raise exception 'SOURCE_ACTION_NOT_SUPPORTED'; end if;
   select id into v_req from public.task_extension_requests where task_id=w.source_entity_id::uuid and status='Pending' order by created_at desc limit 1; if v_req is null then raise exception 'PENDING_EXTENSION_NOT_FOUND'; end if;
   if p_action='APPROVE_EXTENSION' then perform public.decide_task_extension(v_req,'Approved',p_payload->>'note',null,null);
   elsif p_action='REJECT_EXTENSION' then perform public.decide_task_extension(v_req,'Rejected',v_reason,null,null);
   else perform public.decide_task_extension(v_req,'Needs Clarification',v_reason,null,null); end if;
   perform private.ensure_task_workflow_v3(w.source_entity_id::uuid); if p_action='REQUEST_EXTENSION_INFO' then update public.work_items set status='Extension Requested',updated_at=now() where id=w.id; end if;
 elsif r.handler_key='COMPLETE_TASK' then
   if w.source_entity_type<>'task' then raise exception 'SOURCE_ACTION_NOT_SUPPORTED'; end if; perform public.complete_finance_task(w.source_entity_id::uuid,p_payload->>'justification'); perform private.ensure_task_workflow_v3(w.source_entity_id::uuid);
 elsif r.handler_key='REVIEW_TASK' then
   if w.source_entity_type<>'task' then raise exception 'SOURCE_ACTION_NOT_SUPPORTED'; end if; perform public.review_finance_task(w.source_entity_id::uuid,p_action='APPROVE_COMPLETION',p_payload->>'note'); perform private.ensure_task_workflow_v3(w.source_entity_id::uuid); if p_action='RETURN_REWORK' then update public.work_items set status='Returned for Rework',updated_at=now() where id=w.id; end if;
 elsif r.handler_key='REASSIGN_TASK' then
   if w.source_entity_type<>'task' then raise exception 'SOURCE_ACTION_NOT_SUPPORTED'; end if; v_new_owner:=(p_payload->>'new_owner_id')::uuid; if v_new_owner is null then raise exception 'NEW_OWNER_REQUIRED'; end if; perform public.reassign_finance_task(w.source_entity_id::uuid,v_new_owner,v_reason); perform private.ensure_task_workflow_v3(w.source_entity_id::uuid);
 elsif r.handler_key='CHANGE_TASK' then
   if w.source_entity_type<>'task' then raise exception 'SOURCE_ACTION_NOT_SUPPORTED'; end if; select * into v_task from public.tasks where id=w.source_entity_id::uuid; if not found then raise exception 'TASK_NOT_FOUND'; end if;
   perform public.update_finance_task_management(v_task.id,v_task.name,case when p_action='CHANGE_PRIORITY' then coalesce(p_payload->>'priority',v_task.priority) else v_task.priority end,case when p_action='CHANGE_DUE' then coalesce((p_payload->>'due_date')::date,v_task.due_date) else v_task.due_date end,case when p_action='CHANGE_DUE' then coalesce((p_payload->>'due_time')::time,v_task.due_time) else v_task.due_time end,case when p_action='CHANGE_REVIEWER' then coalesce((p_payload->>'reviewer_id')::uuid,v_task.reviewer_id) else v_task.reviewer_id end,v_reason); perform private.ensure_task_workflow_v3(v_task.id);
 elsif r.handler_key='REQUEST_JUSTIFICATION' then if w.source_entity_type<>'task' then raise exception 'SOURCE_ACTION_NOT_SUPPORTED'; end if; perform public.request_task_justification(w.source_entity_id::uuid,v_reason);
 elsif r.handler_key='PAYMENT_SUPERVISOR_APPROVE' then perform public.approve_payment_supervisor(w.source_entity_id::uuid); perform private.ensure_payment_workflow_v3(w.source_entity_id::uuid);
 elsif r.handler_key='PAYMENT_CFO_APPROVE' then perform public.approve_payment_cfo(w.source_entity_id::uuid); perform private.ensure_payment_workflow_v3(w.source_entity_id::uuid);
 elsif r.handler_key='PAYMENT_BANK_EXECUTE' then perform public.execute_payment(w.source_entity_id::uuid); perform private.ensure_payment_workflow_v3(w.source_entity_id::uuid);
 elsif r.handler_key='PAYMENT_ACCOUNTING_REGISTER' then perform public.register_payment_accounting(w.source_entity_id::uuid); perform private.ensure_payment_workflow_v3(w.source_entity_id::uuid);
 elsif r.handler_key='PAYMENT_POST' then perform public.supervisor_finalize_registered_payment(w.source_entity_id::uuid,'Posted',null,null,null,null); perform private.ensure_payment_workflow_v3(w.source_entity_id::uuid);
 elsif r.handler_key='SOURCE_GUARDED' then raise exception 'SOURCE_GUARDED_ACTION_REQUIRES_DEDICATED_SOURCE_HANDLER';
 else raise exception 'UNKNOWN_WORKCENTER_HANDLER:%',r.handler_key; end if;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'WORKCENTER_'||r.audit_event,'work_item',w.id::text,jsonb_build_object('rule_id',r.rule_id,'actor_role',v_role,'workflow_instance_id',w.workflow_instance_id,'source_type',w.source_entity_type,'source_id',w.source_entity_id,'action',p_action,'previous_status',w.status,'payload',coalesce(p_payload,'{}'::jsonb)));
 select * into v_result from public.work_items where id=w.id; return v_result;
end $$;
revoke all on function public.perform_work_item_action(uuid,text,jsonb) from public;
grant execute on function public.perform_work_item_action(uuid,text,jsonb) to authenticated;

-- Base action rules; later migrations narrow/extend these without deleting history.
insert into public.workcenter_action_rules(rule_id,role_key,status_key,action_key,item_type_key,authorization_scope,next_status,audit_event,requires_reason,handler_key,sort_order,active,effect,source_guard_key) values
('BANK_PAYMENT_EXECUTE','BankAccountant','Ready','EXECUTE_PAYMENT','PAYMENT_BANK_EXECUTION','EXACT_ROLE','Completed','PAYMENT_BANK_EXECUTED',false,'PAYMENT_BANK_EXECUTE',10,true,'ALLOW','PAYMENT'),
('CFO_PAYMENT_APPROVE','CFO','Ready','APPROVE_PAYMENT_CFO','PAYMENT_CFO_APPROVAL','EXACT_ROLE','Completed','PAYMENT_CFO_APPROVED',false,'PAYMENT_CFO_APPROVE',10,true,'ALLOW','PAYMENT'),
('CFO_PAYMENT_POST','CFO','Ready','FINALIZE_POSTING','PAYMENT_POSTING_FINALIZATION','CFO','Completed','PAYMENT_POSTED',false,'PAYMENT_POST',20,true,'ALLOW','PAYMENT'),
('EMP_COMMENT','Employee','*','COMMENT','*','ACCESS',null,'COMMENT_ADDED',false,'COMMENT',90,true,'ALLOW','ANY'),
('EMP_ASSIGNED_ACK','Employee','Assigned','ACKNOWLEDGE','*','ASSIGNEE','Ready','WORK_ACKNOWLEDGED',false,'GENERIC',10,true,'ALLOW','ANY'),
('EMP_ASSIGNED_START','Employee','Assigned','START','*','ASSIGNEE','In Progress','WORK_STARTED',false,'START',20,true,'ALLOW','ANY'),
('EMP_ASSIGNED_EXT','Employee','Assigned','REQUEST_EXTENSION','MANUAL_TASK','ASSIGNEE','Extension Requested','EXTENSION_REQUESTED',true,'REQUEST_EXTENSION',30,true,'ALLOW','TASK'),
('EMP_READY_ACK','Employee','Ready','ACKNOWLEDGE','*','ASSIGNEE','Ready','WORK_ACKNOWLEDGED',false,'GENERIC',10,true,'ALLOW','ANY'),
('EMP_READY_START','Employee','Ready','START','*','ASSIGNEE','In Progress','WORK_STARTED',false,'START',20,true,'ALLOW','ANY'),
('EMP_READY_EXT','Employee','Ready','REQUEST_EXTENSION','MANUAL_TASK','ASSIGNEE','Extension Requested','EXTENSION_REQUESTED',true,'REQUEST_EXTENSION',30,true,'ALLOW','TASK'),
('EMP_READY_CLARIFY','Employee','Ready','REQUEST_CLARIFICATION','*','ASSIGNEE','Waiting','CLARIFICATION_REQUESTED',true,'EVENT_ONLY',40,true,'ALLOW','ANY'),
('EMP_PROGRESS_COMPLETE','Employee','In Progress','COMPLETE','MANUAL_TASK','ASSIGNEE','Pending Review','WORK_COMPLETED',false,'COMPLETE_TASK',10,true,'ALLOW','TASK'),
('EMP_PROGRESS_SUBMIT','Employee','In Progress','SUBMIT_FOR_REVIEW','MANUAL_TASK','ASSIGNEE','Pending Review','WORK_SUBMITTED_FOR_REVIEW',false,'COMPLETE_TASK',11,true,'ALLOW','TASK'),
('EMP_PROGRESS_PAUSE','Employee','In Progress','PAUSE','*','ASSIGNEE','Paused','WORK_PAUSED',false,'GENERIC',20,true,'ALLOW','ANY'),
('EMP_PROGRESS_BLOCK','Employee','In Progress','REPORT_BLOCKER','*','ASSIGNEE','Blocked','WORK_BLOCKED',true,'BLOCK',30,true,'ALLOW','ANY'),
('EMP_PROGRESS_EXT','Employee','In Progress','REQUEST_EXTENSION','MANUAL_TASK','ASSIGNEE','Extension Requested','EXTENSION_REQUESTED',true,'REQUEST_EXTENSION',40,true,'ALLOW','TASK'),
('EMP_PROGRESS_UPDATE','Employee','In Progress','PROGRESS_UPDATE','*','ASSIGNEE',null,'PROGRESS_UPDATED',false,'EVENT_ONLY',50,true,'ALLOW','ANY'),
('EMP_PROGRESS_CLARIFY','Employee','In Progress','REQUEST_CLARIFICATION','*','ASSIGNEE','Waiting','CLARIFICATION_REQUESTED',true,'EVENT_ONLY',60,true,'ALLOW','ANY'),
('EMP_BLOCKED_RESOLVE','Employee','Blocked','RESOLVE_BLOCKER','*','ASSIGNEE','In Progress','BLOCKER_RESOLVED',false,'RESOLVE_BLOCKER',10,true,'ALLOW','ANY'),
('EMP_BLOCKED_EXT','Employee','Blocked','REQUEST_EXTENSION','MANUAL_TASK','ASSIGNEE','Extension Requested','EXTENSION_REQUESTED',true,'REQUEST_EXTENSION',20,true,'ALLOW','TASK'),
('EMP_PAUSED_RESUME','Employee','Paused','RESUME','*','ASSIGNEE','In Progress','WORK_RESUMED',false,'GENERIC',10,true,'ALLOW','ANY'),
('EMP_REWORK_START','Employee','Returned for Rework','START','*','ASSIGNEE','In Progress','REWORK_STARTED',false,'START',10,true,'ALLOW','ANY'),
('EMP_REWORK_RESUME','Employee','Returned for Rework','RESUME','*','ASSIGNEE','In Progress','WORK_RESUMED',false,'GENERIC',11,true,'ALLOW','ANY'),
('EMP_REWORK_COMPLETE','Employee','Returned for Rework','COMPLETE','MANUAL_TASK','ASSIGNEE','Pending Review','WORK_COMPLETED',false,'COMPLETE_TASK',20,true,'ALLOW','TASK'),
('EMP_REWORK_SUBMIT','Employee','Returned for Rework','SUBMIT_FOR_REVIEW','MANUAL_TASK','ASSIGNEE','Pending Review','WORK_SUBMITTED_FOR_REVIEW',false,'COMPLETE_TASK',21,true,'ALLOW','TASK'),
('EMP_REWORK_BLOCK','Employee','Returned for Rework','REPORT_BLOCKER','*','ASSIGNEE','Blocked','WORK_BLOCKED',true,'BLOCK',30,true,'ALLOW','ANY'),
('EMP_REWORK_EXT','Employee','Returned for Rework','REQUEST_EXTENSION','MANUAL_TASK','ASSIGNEE','Extension Requested','EXTENSION_REQUESTED',true,'REQUEST_EXTENSION',40,true,'ALLOW','TASK'),
('EMP_REWORK_PROGRESS','Employee','Returned for Rework','PROGRESS_UPDATE','*','ASSIGNEE',null,'PROGRESS_UPDATED',false,'EVENT_ONLY',50,true,'ALLOW','ANY'),
('EMP_REWORK_CLARIFY','Employee','Returned for Rework','REQUEST_CLARIFICATION','*','ASSIGNEE','Waiting','CLARIFICATION_REQUESTED',true,'EVENT_ONLY',60,true,'ALLOW','ANY'),
('GL_PAYMENT_REGISTER','GLAccountant','Ready','REGISTER_ACCOUNTING','PAYMENT_ACCOUNTING_REGISTRATION','EXACT_ROLE','Completed','PAYMENT_ACCOUNTING_REGISTERED',false,'PAYMENT_ACCOUNTING_REGISTER',10,true,'ALLOW','PAYMENT'),
('GL_PAYMENT_POST','GLAccountant','Ready','FINALIZE_POSTING','PAYMENT_POSTING_FINALIZATION','EXACT_ROLE','Completed','PAYMENT_POSTED',false,'PAYMENT_POST',20,true,'ALLOW','PAYMENT'),
('SUP_EXT_APPROVE','Supervisor','Extension Requested','APPROVE_EXTENSION','MANUAL_TASK','MANAGER',null,'EXTENSION_APPROVED',false,'DECIDE_EXTENSION',10,true,'ALLOW','TASK'),
('SUP_EXT_REJECT','Supervisor','Extension Requested','REJECT_EXTENSION','MANUAL_TASK','MANAGER',null,'EXTENSION_REJECTED',true,'DECIDE_EXTENSION',20,true,'ALLOW','TASK'),
('SUP_EXT_INFO','Supervisor','Extension Requested','REQUEST_EXTENSION_INFO','MANUAL_TASK','MANAGER','Extension Requested','EXTENSION_INFO_REQUESTED',true,'DECIDE_EXTENSION',30,true,'ALLOW','TASK'),
('SUP_REVIEW_APPROVE','Supervisor','Pending Review','APPROVE_COMPLETION','MANUAL_TASK','REVIEWER_OR_MANAGER','Completed','WORK_APPROVED',false,'REVIEW_TASK',10,true,'ALLOW','TASK'),
('SUP_REVIEW_REWORK','Supervisor','Pending Review','RETURN_REWORK','MANUAL_TASK','REVIEWER_OR_MANAGER','Returned for Rework','WORK_RETURNED_FOR_REWORK',true,'REVIEW_TASK',20,true,'ALLOW','TASK'),
('SUP_PAYMENT_APPROVE','Supervisor','Ready','APPROVE_PAYMENT_SUPERVISOR','PAYMENT_SUPERVISOR_APPROVAL','EXACT_ROLE','Completed','PAYMENT_SUPERVISOR_APPROVED',false,'PAYMENT_SUPERVISOR_APPROVE',10,true,'ALLOW','PAYMENT'),
('SUP_PAYMENT_POST','Supervisor','Ready','FINALIZE_POSTING','PAYMENT_POSTING_FINALIZATION','MANAGER','Completed','PAYMENT_POSTED',false,'PAYMENT_POST',20,true,'ALLOW','PAYMENT'),
('SUP_CANCEL_DRAFT','Supervisor','Draft','CANCEL_MANUAL_TASK','MANUAL_TASK','MANAGER','Cancelled','WORK_CANCELLED',true,'SOURCE_GUARDED',70,true,'ALLOW','TASK'),
('SUP_CANCEL_ASSIGNED','Supervisor','Assigned','CANCEL_MANUAL_TASK','MANUAL_TASK','MANAGER','Cancelled','WORK_CANCELLED',true,'SOURCE_GUARDED',70,true,'ALLOW','TASK'),
('SUP_CANCEL_READY','Supervisor','Ready','CANCEL_MANUAL_TASK','MANUAL_TASK','MANAGER','Cancelled','WORK_CANCELLED',true,'SOURCE_GUARDED',70,true,'ALLOW','TASK'),
('SUP_REOPEN_COMPLETED','Supervisor','Completed','REOPEN','MANUAL_TASK','MANAGER','Assigned','WORK_REOPENED',true,'SOURCE_GUARDED',80,true,'ALLOW','TASK'),
('SUP_REOPEN_APPROVED','Supervisor','Approved','REOPEN','MANUAL_TASK','MANAGER','Assigned','WORK_REOPENED',true,'SOURCE_GUARDED',80,true,'ALLOW','TASK'),
('CFO_REOPEN_COMPLETED','CFO','Completed','REOPEN','MANUAL_TASK','CFO','Assigned','CFO_WORK_REOPENED',true,'SOURCE_GUARDED',80,true,'ALLOW','TASK'),
('CFO_REOPEN_CLOSED','CFO','Closed','REOPEN','MANUAL_TASK','CFO','Assigned','CFO_WORK_REOPENED',true,'SOURCE_GUARDED',80,true,'ALLOW','TASK')
on conflict(role_key,status_key,action_key,item_type_key) do update set authorization_scope=excluded.authorization_scope,next_status=excluded.next_status,audit_event=excluded.audit_event,requires_reason=excluded.requires_reason,handler_key=excluded.handler_key,sort_order=excluded.sort_order,active=excluded.active,effect=excluded.effect,source_guard_key=excluded.source_guard_key,updated_at=now();
