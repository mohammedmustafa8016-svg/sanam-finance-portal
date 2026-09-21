-- Targeted workflow correction:
-- 1) CFO/Supervisor self-reviewed tasks complete immediately on submission.
-- 2) Supervisor tasks submitted to the CFO enter the active Work Center cycle,
--    including older tasks created before the current cycle.

create or replace function public.submit_finance_task_result(
  p_task_id uuid,
  p_result_description text,
  p_justification text default null
)
returns void
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare
  v_task public.tasks%rowtype;
  v_deadline timestamptz;
  v_requires_justification boolean;
  v_justification text;
  v_result text;
  v_role text:=private.current_role();
  v_self_complete boolean:=false;
begin
  select * into v_task from public.tasks where id=p_task_id for update;
  if not found then raise exception 'Task not found'; end if;
  if v_task.owner_id<>auth.uid() then raise exception 'Only task owner can submit the task'; end if;
  if v_task.started_at is null or v_task.status<>'قيد التنفيذ' then raise exception 'TASK_MUST_BE_STARTED'; end if;
  if nullif(trim(coalesce(v_task.blocker_note,'')),'') is not null then raise exception 'TASK_BLOCKER_MUST_BE_CLEARED'; end if;

  v_result:=nullif(trim(coalesce(p_result_description,'')),'');
  if v_result is null then raise exception 'RESULT_DESCRIPTION_REQUIRED'; end if;

  v_deadline:=private.task_deadline(v_task.due_date,v_task.due_time);
  v_requires_justification:=(v_deadline is not null and now()>v_deadline) or v_task.justification_requested_at is not null;
  v_justification:=coalesce(nullif(trim(coalesce(p_justification,'')),''),v_task.delay_justification);
  if v_requires_justification and v_justification is null then raise exception 'DELAY_JUSTIFICATION_REQUIRED'; end if;

  v_self_complete:=v_task.owner_id=v_task.reviewer_id
    and auth.uid()=v_task.owner_id
    and v_role in ('CFO','Supervisor');

  if v_self_complete then
    update public.tasks
       set status='مكتمل',
           review_requested_at=now(),
           reviewed_at=null,
           reviewed_by=null,
           review_note=null,
           completed_at=now(),
           result_description=v_result,
           quality_score=null,
           evaluation_note=null,
           evaluated_by=null,
           evaluated_at=null,
           delay_justification=case when v_requires_justification then v_justification else delay_justification end,
           justification_submitted_at=case when v_requires_justification then coalesce(justification_submitted_at,now()) else justification_submitted_at end,
           updated_at=now()
     where id=p_task_id;

    insert into public.task_comments(task_id,author_id,comment_type,body)
    values(p_task_id,auth.uid(),'Completion',v_result);

    insert into public.task_activity_events(task_id,actor_id,event_type,details)
    values(
      p_task_id,
      auth.uid(),
      'TASK_SELF_COMPLETED',
      jsonb_build_object(
        'deadline',v_deadline,
        'late',v_deadline is not null and now()>v_deadline,
        'result_description',v_result,
        'automatic',true,
        'reason','OWNER_IS_REVIEWER_MANAGER'
      )
    );

    insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
    values(
      auth.uid(),
      'SELF_COMPLETE_TASK_RESULT',
      'task',
      p_task_id::text,
      jsonb_build_object(
        'deadline',v_deadline,
        'late',v_deadline is not null and now()>v_deadline,
        'result_description',v_result,
        'justification',case when v_requires_justification then v_justification else null end,
        'automatic',true,
        'reason','OWNER_IS_REVIEWER_MANAGER'
      )
    );
  else
    update public.tasks
       set status='بانتظار المراجعة',
           review_requested_at=now(),
           reviewed_at=null,
           reviewed_by=null,
           review_note=null,
           result_description=v_result,
           quality_score=null,
           evaluation_note=null,
           evaluated_by=null,
           evaluated_at=null,
           delay_justification=case when v_requires_justification then v_justification else delay_justification end,
           justification_submitted_at=case when v_requires_justification then coalesce(justification_submitted_at,now()) else justification_submitted_at end,
           updated_at=now()
     where id=p_task_id;

    insert into public.task_comments(task_id,author_id,comment_type,body)
    values(p_task_id,auth.uid(),'Completion',v_result);

    insert into public.task_activity_events(task_id,actor_id,event_type,details)
    values(
      p_task_id,
      auth.uid(),
      'TASK_SUBMITTED_FOR_REVIEW',
      jsonb_build_object('deadline',v_deadline,'late',v_deadline is not null and now()>v_deadline,'result_description',v_result)
    );

    perform private.notify_task_participants_v4(
      p_task_id,
      auth.uid(),
      'TASK_PENDING_REVIEW',
      'مهمة بانتظار المراجعة',
      v_task.name,
      'V4:PENDING_REVIEW:'||p_task_id::text||':'||extract(epoch from now())::bigint::text
    );

    insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
    values(
      auth.uid(),
      'SUBMIT_TASK_RESULT',
      'task',
      p_task_id::text,
      jsonb_build_object(
        'deadline',v_deadline,
        'late',v_deadline is not null and now()>v_deadline,
        'result_description',v_result,
        'justification',case when v_requires_justification then v_justification else null end
      )
    );
  end if;
end $$;

revoke all on function public.submit_finance_task_result(uuid,text,text) from public,anon;
grant execute on function public.submit_finance_task_result(uuid,text,text) to authenticated;

-- Explicit CFO rules make Supervisor submissions visible as actionable review
-- work without changing the existing Supervisor or employee rules.
insert into public.workcenter_action_rules(
  rule_id,role_key,status_key,action_key,item_type_key,authorization_scope,
  next_status,audit_event,requires_reason,handler_key,sort_order,active,effect,source_guard_key
) values
  ('CFO_REVIEW_APPROVE','CFO','Pending Review','APPROVE_COMPLETION','MANUAL_TASK','CFO','Completed','WORK_APPROVED',false,'REVIEW_TASK',5,true,'ALLOW','TASK'),
  ('CFO_REVIEW_REWORK','CFO','Pending Review','RETURN_REWORK','MANUAL_TASK','CFO','Returned for Rework','WORK_RETURNED_FOR_REWORK',true,'REVIEW_TASK',6,true,'ALLOW','TASK')
on conflict(role_key,status_key,action_key,item_type_key) do update set
  authorization_scope=excluded.authorization_scope,
  next_status=excluded.next_status,
  audit_event=excluded.audit_event,
  requires_reason=excluded.requires_reason,
  handler_key=excluded.handler_key,
  sort_order=excluded.sort_order,
  active=excluded.active,
  effect=excluded.effect,
  source_guard_key=excluded.source_guard_key,
  updated_at=now();

create or replace function private.track_workcenter_cycle_item()
returns trigger
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare
  c private.workcenter_cycles%rowtype;
  source_created timestamptz;
  source_owner_role text;
  source_reviewer_role text;
  admit boolean:=false;
begin
  select * into c from private.workcenter_cycles where active;
  if not found or new.status in ('Waiting','Cancelled','Closed') then return new; end if;
  if exists(select 1 from private.workcenter_cycle_items where cycle_id=c.id and work_item_id=new.id) then return new; end if;

  if new.source_entity_type='task' then
    select t.created_at,owner_profile.role,reviewer_profile.role
      into source_created,source_owner_role,source_reviewer_role
      from public.tasks t
      left join public.profiles owner_profile on owner_profile.id=t.owner_id
      left join public.profiles reviewer_profile on reviewer_profile.id=t.reviewer_id
     where t.id::text=new.source_entity_id;
  elsif new.source_entity_type='payment' then
    select created_at into source_created from public.payments where id::text=new.source_entity_id;
  else
    source_created:=new.created_at;
  end if;

  admit:=source_created>=c.started_at;

  -- An older Supervisor task enters the active cycle when it is newly submitted
  -- to the CFO. This is deliberately limited to the requested review transition.
  if tg_op='UPDATE' and new.source_entity_type='task' then
    admit:=admit or (
      old.status is distinct from new.status
      and new.status='Pending Review'
      and source_owner_role='Supervisor'
      and source_reviewer_role='CFO'
    );
  end if;

  -- Preserve the existing payment-cycle admission behavior unchanged.
  if tg_op='UPDATE' and new.source_entity_type='payment' then
    admit:=admit or (old.status='Waiting' and new.status not in ('Waiting','Completed','Closed','Cancelled'))
      or (old.status is distinct from new.status and new.status='Completed' and new.completed_at>=c.started_at);
  end if;

  if admit then
    insert into private.workcenter_cycle_items(cycle_id,work_item_id)
    values(c.id,new.id)
    on conflict do nothing;
  end if;
  return new;
end $$;

revoke all on function private.track_workcenter_cycle_item() from public,anon,authenticated;

-- Repair manager self-review tasks that were already waiting before this change.
do $$
declare r record;
begin
  for r in
    select t.id,t.owner_id,t.result_description,t.review_requested_at
      from public.tasks t
      join public.profiles owner_profile on owner_profile.id=t.owner_id
     where t.status='بانتظار المراجعة'
       and t.owner_id=t.reviewer_id
       and owner_profile.role in ('CFO','Supervisor')
       and nullif(trim(coalesce(t.result_description,'')),'') is not null
     for update
  loop
    update public.tasks
       set status='مكتمل',
           completed_at=coalesce(r.review_requested_at,now()),
           reviewed_at=null,
           reviewed_by=null,
           review_note=null,
           quality_score=null,
           evaluation_note=null,
           evaluated_by=null,
           evaluated_at=null,
           updated_at=now()
     where id=r.id;

    insert into public.task_activity_events(task_id,actor_id,event_type,details)
    values(
      r.id,
      r.owner_id,
      'TASK_SELF_COMPLETED',
      jsonb_build_object(
        'result_description',r.result_description,
        'automatic',true,
        'backfilled',true,
        'reason','OWNER_IS_REVIEWER_MANAGER'
      )
    );

    insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
    values(
      r.owner_id,
      'SELF_COMPLETE_TASK_RESULT_BACKFILL',
      'task',
      r.id::text,
      jsonb_build_object('automatic',true,'backfilled',true,'reason','OWNER_IS_REVIEWER_MANAGER')
    );

    perform private.ensure_task_workflow_v3(r.id);
  end loop;
end $$;

-- Backfill any Supervisor review already pending but excluded solely because
-- the task predates the active Work Center cycle.
insert into private.workcenter_cycle_items(cycle_id,work_item_id)
select c.id,w.id
  from private.workcenter_cycles c
  join public.work_items w
    on w.source_entity_type='task'
   and w.item_type='MANUAL_TASK'
   and w.status='Pending Review'
  join public.tasks t on t.id::text=w.source_entity_id
  join public.profiles owner_profile on owner_profile.id=t.owner_id
  join public.profiles reviewer_profile on reviewer_profile.id=t.reviewer_id
 where c.active
   and t.status='بانتظار المراجعة'
   and owner_profile.role='Supervisor'
   and reviewer_profile.role='CFO'
on conflict do nothing;
