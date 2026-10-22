-- Daily Operations Workflow V4 follow-up
-- Ensure Submit for Review uses the scored/result path and preserve explicit Rework state.

create or replace function public.try_perform_work_item_action_v4(p_work_item_id uuid,p_action text,p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path=public,private,pg_temp
as $$
declare w public.work_items%rowtype; r record; v_role text:=private.current_role(); v_error text;
begin
 select * into w from public.work_items where id=p_work_item_id;
 if not found then return jsonb_build_object('ok',false,'error','WORK_ITEM_NOT_FOUND'); end if;
 if w.source_entity_type='task' and p_action in ('COMPLETE','SUBMIT_FOR_REVIEW','APPROVE_COMPLETION','RETURN_REWORK') then
   select * into r from private.resolve_workcenter_rule(p_work_item_id,p_action,auth.uid(),v_role) limit 1;
   if r.rule_id is null or not coalesce(r.allowed,false) then return jsonb_build_object('ok',false,'error',coalesce(r.denial_reason,'NO_RULE')); end if;
   begin
     if p_action in ('COMPLETE','SUBMIT_FOR_REVIEW') then
       perform public.submit_finance_task_result(w.source_entity_id::uuid,p_payload->>'result_description',p_payload->>'justification');
     elsif p_action='APPROVE_COMPLETION' then
       perform public.review_finance_task_scored(w.source_entity_id::uuid,true,nullif(p_payload->>'quality_score','')::numeric,p_payload->>'note');
     else
       perform public.review_finance_task_scored(w.source_entity_id::uuid,false,null,p_payload->>'reason');
     end if;
     perform private.ensure_task_workflow_v3(w.source_entity_id::uuid);
     if p_action='RETURN_REWORK' then
       update public.work_items
       set status='Returned for Rework',metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('rework_reason',p_payload->>'reason'),updated_at=now()
       where id=p_work_item_id;
       insert into public.work_item_events(work_item_id,actor_id,event_type,details)
       values(p_work_item_id,auth.uid(),'WORK_RETURNED_FOR_REWORK',jsonb_build_object('reason',p_payload->>'reason'));
     end if;
   exception when others then
     get stacked diagnostics v_error=message_text;
     return jsonb_build_object('ok',false,'error',v_error);
   end;
   return jsonb_build_object('ok',true,'action',p_action,'work_item_id',p_work_item_id);
 end if;
 return public.try_perform_work_item_action(p_work_item_id,p_action,coalesce(p_payload,'{}'::jsonb));
end $$;

grant execute on function public.try_perform_work_item_action_v4(uuid,text,jsonb) to authenticated;

create or replace function public.request_task_extension(p_task_id uuid,p_requested_due_date date,p_requested_due_time time,p_justification text)
returns uuid
language plpgsql security definer
set search_path=public,private,pg_temp
as $$
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
  perform private.notify_task_participants_v4(p_task_id,auth.uid(),'EXTENSION_REQUESTED','طلب تمديد مهمة',v_task.name||' — '||trim(p_justification),'V4:EXTENSION_REQUEST:'||v_id::text);
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'REQUEST_TASK_EXTENSION','task',p_task_id::text,jsonb_build_object('request_id',v_id,'previous_due_date',v_task.due_date,'previous_due_time',v_task.due_time,'requested_due_date',p_requested_due_date,'requested_due_time',p_requested_due_time));
  return v_id;
end $$;

create or replace function public.decide_task_extension(p_request_id uuid,p_decision text,p_note text default null,p_due_date date default null,p_due_time time default null)
returns void
language plpgsql security definer
set search_path=public,private,pg_temp
as $$
declare v_req public.task_extension_requests%rowtype; v_task public.tasks%rowtype; v_status text; v_date date; v_time time;
begin
 if private.current_role() not in ('CFO','Supervisor') then raise exception 'Only CFO or Supervisor can decide extension requests'; end if;
 select * into v_req from public.task_extension_requests where id=p_request_id for update; if not found then raise exception 'Extension request not found'; end if;
 if v_req.status<>'Pending' then raise exception 'Extension request is already decided'; end if;
 select * into v_task from public.tasks where id=v_req.task_id for update;
 if p_decision not in ('Approved','Rejected','Needs Clarification') then raise exception 'Invalid decision'; end if;
 v_status:=p_decision;
 if v_status='Approved' then
   v_date:=coalesce(p_due_date,v_req.requested_due_date); v_time:=coalesce(p_due_time,v_req.requested_due_time);
   if private.task_deadline(v_date,v_time)<=now() then raise exception 'Approved deadline must be in the future'; end if;
   update public.tasks set original_due_date=coalesce(original_due_date,due_date),original_due_time=coalesce(original_due_time,due_time),due_date=v_date,due_time=v_time,updated_at=now() where id=v_task.id;
 end if;
 update public.task_extension_requests set status=v_status,supervisor_note=nullif(trim(coalesce(p_note,'')),''),decided_by=auth.uid(),decided_at=now(),updated_at=now() where id=p_request_id;
 insert into public.task_activity_events(task_id,actor_id,event_type,details)
 values(v_task.id,auth.uid(),'EXTENSION_'||upper(replace(v_status,' ', '_')),jsonb_build_object('request_id',p_request_id,'decision',v_status,'note',nullif(trim(coalesce(p_note,'')),''),'approved_due_date',v_date,'approved_due_time',v_time));
 perform private.notify_task_participants_v4(v_task.id,auth.uid(),'EXTENSION_DECIDED','قرار طلب التمديد',v_task.name||' — '||v_status,'V4:EXTENSION_DECISION:'||p_request_id::text||':'||v_status);
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'DECIDE_TASK_EXTENSION','task',v_task.id::text,jsonb_build_object('request_id',p_request_id,'decision',v_status));
end $$;

grant execute on function public.request_task_extension(uuid,date,time,text) to authenticated;
grant execute on function public.decide_task_extension(uuid,text,text,date,time) to authenticated;
