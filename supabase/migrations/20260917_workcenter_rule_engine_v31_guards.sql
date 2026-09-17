-- Work Center V3.1 guard refinements.

create or replace function public.request_task_extension(p_task_id uuid,p_requested_due_date date,p_requested_due_time time without time zone,p_justification text)
returns uuid language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_task public.tasks%rowtype; v_id uuid; v_requested timestamptz; v_current timestamptz;
begin
  select * into v_task from public.tasks where id=p_task_id for update; if not found then raise exception 'Task not found'; end if;
  if v_task.owner_id<>auth.uid() then raise exception 'Only task owner can request extension'; end if;
  if v_task.status in ('مكتمل','بانتظار المراجعة') then raise exception 'Closed/submitted task cannot request extension'; end if;
  if nullif(trim(coalesce(p_justification,'')),'') is null then raise exception 'Extension justification is required'; end if;
  v_requested:=private.task_deadline(p_requested_due_date,p_requested_due_time);
  v_current:=private.task_deadline(v_task.due_date,v_task.due_time);
  if v_requested<=now() then raise exception 'Requested deadline must be in the future'; end if;
  if v_current is not null and v_requested<=v_current then raise exception 'Requested deadline must be later than the current deadline'; end if;
  if exists(select 1 from public.task_extension_requests where task_id=p_task_id and status='Pending') then raise exception 'A pending extension request already exists'; end if;
  insert into public.task_extension_requests(task_id,requested_by,requested_due_date,requested_due_time,justification)
  values(p_task_id,auth.uid(),p_requested_due_date,p_requested_due_time,trim(p_justification)) returning id into v_id;
  insert into public.task_activity_events(task_id,actor_id,event_type,details)
  values(p_task_id,auth.uid(),'EXTENSION_REQUESTED',jsonb_build_object('request_id',v_id,'requested_due_date',p_requested_due_date,'requested_due_time',p_requested_due_time,'previous_due_date',v_task.due_date,'previous_due_time',v_task.due_time,'justification',trim(p_justification)));
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'REQUEST_TASK_EXTENSION','task',p_task_id::text,jsonb_build_object('request_id',v_id,'previous_due_date',v_task.due_date,'previous_due_time',v_task.due_time,'requested_due_date',p_requested_due_date,'requested_due_time',p_requested_due_time));
  return v_id;
end $$;

-- CFO exceptional actions are represented but deliberately source-guarded until a dedicated safe source handler is introduced.
insert into public.workcenter_action_rules(rule_id,role_key,status_key,action_key,item_type_key,authorization_scope,next_status,audit_event,requires_reason,handler_key,sort_order,active,effect,source_guard_key)
select 'CFO_'||replace(upper(s),' ','_')||'_FORCE_CLOSE','CFO',s,'FORCE_CLOSE','MANUAL_TASK','CFO','Closed','CFO_FORCE_CLOSED',true,'SOURCE_GUARDED',80,true,'ALLOW','TASK'
from unnest(array['Assigned','Ready','In Progress','Blocked','Extension Requested','Pending Review','Returned for Rework']) s
on conflict(role_key,status_key,action_key,item_type_key) do update set authorization_scope=excluded.authorization_scope,next_status=excluded.next_status,audit_event=excluded.audit_event,requires_reason=excluded.requires_reason,handler_key=excluded.handler_key,sort_order=excluded.sort_order,active=excluded.active,effect=excluded.effect,source_guard_key=excluded.source_guard_key,updated_at=now();

insert into public.workcenter_action_rules(rule_id,role_key,status_key,action_key,item_type_key,authorization_scope,next_status,audit_event,requires_reason,handler_key,sort_order,active,effect,source_guard_key)
select 'CFO_'||replace(upper(s),' ','_')||'_STAGE_OVERRIDE','CFO',s,'STAGE_OVERRIDE','MANUAL_TASK','CFO',null,'CFO_STAGE_OVERRIDE',true,'SOURCE_GUARDED',90,true,'ALLOW','TASK'
from unnest(array['Assigned','Ready','In Progress','Blocked','Extension Requested','Pending Review','Returned for Rework','Completed','Closed']) s
on conflict(role_key,status_key,action_key,item_type_key) do update set authorization_scope=excluded.authorization_scope,next_status=excluded.next_status,audit_event=excluded.audit_event,requires_reason=excluded.requires_reason,handler_key=excluded.handler_key,sort_order=excluded.sort_order,active=excluded.active,effect=excluded.effect,source_guard_key=excluded.source_guard_key,updated_at=now();
