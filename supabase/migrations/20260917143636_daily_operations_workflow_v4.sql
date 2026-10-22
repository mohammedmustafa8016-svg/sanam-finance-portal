-- Sanam Finance Portal - Daily Operations Workflow V4
-- Preserves all historical task/performance data. No performance records are deleted.

alter table public.tasks add column if not exists result_description text;
alter table public.tasks add column if not exists quality_score numeric(5,2);
alter table public.tasks add column if not exists evaluation_note text;
alter table public.tasks add column if not exists evaluated_by uuid;
alter table public.tasks add column if not exists evaluated_at timestamptz;

do $$ begin
  if not exists (select 1 from pg_constraint where conname='tasks_quality_score_range') then
    alter table public.tasks add constraint tasks_quality_score_range check (quality_score is null or (quality_score>=0 and quality_score<=100));
  end if;
end $$;

create index if not exists idx_tasks_owner_due_status_v4 on public.tasks(owner_id,due_date,status);
create index if not exists idx_tasks_completed_at_v4 on public.tasks(completed_at) where completed_at is not null;
create index if not exists idx_work_items_assignee_status_v4 on public.work_items(assignee_id,status);
create index if not exists idx_work_items_completed_by_at_v4 on public.work_items(completed_by,completed_at) where completed_at is not null;

create or replace function private.notify_task_participants_v4(
  p_task_id uuid,
  p_actor uuid,
  p_type text,
  p_title text,
  p_message text,
  p_event_key text
) returns void
language plpgsql security definer
set search_path=public,private,pg_temp
as $$
declare t public.tasks%rowtype;
begin
  select * into t from public.tasks where id=p_task_id;
  if not found then return; end if;
  insert into public.task_notifications(user_id,task_id,notification_type,title,message,unique_key)
  select r.uid,p_task_id,p_type,p_title,p_message,p_event_key||':'||r.uid::text
  from (
    select t.owner_id uid
    union select t.reviewer_id
    union select id from public.profiles where active=true and role='CFO'
  ) r
  where r.uid is not null and r.uid is distinct from p_actor
  on conflict(unique_key) do nothing;
end $$;

create or replace function public.save_manual_daily_plan(p_items jsonb)
returns integer
language plpgsql security definer
set search_path=public,private,pg_temp
as $$
declare
 v_role text:=private.current_role(); v_today date:=(now() at time zone 'Asia/Riyadh')::date; v_item jsonb; v_catalog public.finance_task_catalog%rowtype;
 v_owner uuid; v_reviewer uuid; v_owner_role text; v_due_time time; v_priority text; v_name text; v_output text; v_task_id uuid; v_count int:=0; v_save_template boolean;
begin
 if v_role not in ('CFO','Supervisor') then raise exception 'Only CFO or Supervisor can manage the daily work plan'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Daily plan must include at least one selected task'; end if;
 for v_item in select value from jsonb_array_elements(p_items) loop
   if coalesce(v_item->>'catalog_id','')<>'' then
     select * into v_catalog from public.finance_task_catalog where id=(v_item->>'catalog_id')::uuid and active=true;
     if not found then raise exception 'Task template not found'; end if;
     v_name:=v_catalog.name; v_output:=v_catalog.output; v_owner:=coalesce(nullif(v_item->>'owner_id','')::uuid,v_catalog.default_owner_id); v_priority:=coalesce(nullif(v_item->>'priority',''),v_catalog.default_priority,'عادي');
   else
     v_name:=nullif(trim(coalesce(v_item->>'name','')),''); v_output:=nullif(trim(coalesce(v_item->>'output','')),''); v_owner:=nullif(v_item->>'owner_id','')::uuid; v_priority:=coalesce(nullif(v_item->>'priority',''),'عادي');
     if v_name is null then raise exception 'Task name is required'; end if;
   end if;
   if v_owner is null or not exists(select 1 from public.profiles where id=v_owner and active=true) then raise exception 'Valid owner is required'; end if;
   if coalesce(v_item->>'due_time','')='' then raise exception 'Due time is required'; end if;
   v_due_time:=(v_item->>'due_time')::time;
   select role into v_owner_role from public.profiles where id=v_owner;
   if v_owner_role='Supervisor' then select id into v_reviewer from public.profiles where active=true and role='CFO' order by created_at limit 1;
   else select id into v_reviewer from public.profiles where active=true and role='Supervisor' order by created_at limit 1; end if;
   insert into public.tasks(name,frequency,owner_id,reviewer_id,due_date,due_time,priority,status,output,created_by,opened_at,opened_by,assigned_at,assigned_by,created_at,updated_at)
   values(v_name,'خطة اليوم',v_owner,v_reviewer,v_today,v_due_time,v_priority,'لم يبدأ',v_output,auth.uid(),now(),auth.uid(),now(),auth.uid(),now(),now()) returning id into v_task_id;
   insert into public.task_activity_events(task_id,actor_id,event_type,details)
   values(v_task_id,auth.uid(),'TASK_ASSIGNED',jsonb_build_object('owner_id',v_owner,'reviewer_id',v_reviewer,'due_date',v_today,'due_time',v_due_time,'source','daily_plan'));
   perform private.notify_task_participants_v4(v_task_id,auth.uid(),'TASK_ASSIGNED','مهمة جديدة مسندة',v_name,'V4:ASSIGNED:'||v_task_id::text);
   v_save_template:=coalesce((v_item->>'save_as_template')::boolean,false);
   if v_save_template and coalesce(v_item->>'catalog_id','')='' then
     insert into public.finance_task_catalog(name,default_owner_id,default_priority,output,created_by) values(v_name,v_owner,v_priority,v_output,auth.uid());
   end if;
   insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
   values(auth.uid(),'OPEN_MANUAL_DAILY_TASK','task',v_task_id::text,jsonb_build_object('owner_id',v_owner,'due_date',v_today,'due_time',v_due_time,'priority',v_priority,'catalog_id',nullif(v_item->>'catalog_id',''),'operator_role',v_role,'saved_as_template',v_save_template));
   v_count:=v_count+1;
 end loop;
 return v_count;
end $$;

create or replace function public.create_finance_task_v2(p_name text,p_owner_id uuid,p_reviewer_id uuid,p_due_date date,p_due_time time,p_frequency text,p_priority text,p_status text default 'لم يبدأ')
returns uuid
language plpgsql security definer
set search_path=public,private,pg_temp
as $$
declare v_role text:=private.current_role(); v_id uuid; v_reviewer uuid:=p_reviewer_id;
begin
 if v_role not in ('CFO','Supervisor') then raise exception 'Not authorized to create tasks'; end if;
 if nullif(trim(coalesce(p_name,'')),'') is null then raise exception 'Task name is required'; end if;
 if p_owner_id is null or not exists(select 1 from public.profiles where id=p_owner_id and active=true) then raise exception 'Valid owner is required'; end if;
 if p_due_date is null or p_due_time is null then raise exception 'Due date and due time are required'; end if;
 if v_reviewer is null then
   if exists(select 1 from public.profiles where id=p_owner_id and role='Supervisor') then select id into v_reviewer from public.profiles where active=true and role='CFO' order by created_at limit 1;
   else select id into v_reviewer from public.profiles where active=true and role='Supervisor' order by created_at limit 1; end if;
 end if;
 insert into public.tasks(name,frequency,owner_id,reviewer_id,due_date,due_time,priority,status,created_by,opened_at,opened_by,assigned_at,assigned_by,created_at,updated_at)
 values(trim(p_name),coalesce(nullif(p_frequency,''),'حسب الحاجة'),p_owner_id,v_reviewer,p_due_date,p_due_time,coalesce(nullif(p_priority,''),'عادي'),coalesce(nullif(p_status,''),'لم يبدأ'),auth.uid(),now(),auth.uid(),now(),auth.uid(),now(),now()) returning id into v_id;
 insert into public.task_activity_events(task_id,actor_id,event_type,details) values(v_id,auth.uid(),'TASK_ASSIGNED',jsonb_build_object('owner_id',p_owner_id,'reviewer_id',v_reviewer,'due_date',p_due_date,'due_time',p_due_time));
 perform private.notify_task_participants_v4(v_id,auth.uid(),'TASK_ASSIGNED','مهمة جديدة مسندة',trim(p_name),'V4:ASSIGNED:'||v_id::text);
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'CREATE_TASK_V2','task',v_id::text,jsonb_build_object('owner_id',p_owner_id,'reviewer_id',v_reviewer));
 return v_id;
end $$;

create or replace function public.start_finance_task(p_task_id uuid)
returns void
language plpgsql security definer
set search_path=public,private,pg_temp
as $$
declare v_task public.tasks%rowtype;
begin
 select * into v_task from public.tasks where id=p_task_id for update; if not found then raise exception 'Task not found'; end if;
 if v_task.owner_id<>auth.uid() then raise exception 'Only task owner can start the task'; end if;
 if v_task.opened_at is null then raise exception 'Task has not been released by the Supervisor'; end if;
 if v_task.status in ('مكتمل','بانتظار المراجعة') then raise exception 'Task cannot be started in its current status'; end if;
 update public.tasks set status='قيد التنفيذ',started_at=coalesce(started_at,now()),updated_at=now() where id=p_task_id;
 insert into public.task_activity_events(task_id,actor_id,event_type,details) values(p_task_id,auth.uid(),'TASK_STARTED',jsonb_build_object('started_at',coalesce(v_task.started_at,now())));
 perform private.notify_task_participants_v4(p_task_id,auth.uid(),'TASK_STARTED','تم بدء المهمة',v_task.name,'V4:STARTED:'||p_task_id::text||':'||coalesce(v_task.started_at,now())::text);
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'START_TASK','task',p_task_id::text,jsonb_build_object('name',v_task.name));
end $$;

create or replace function public.submit_finance_task_result(p_task_id uuid,p_result_description text,p_justification text default null)
returns void
language plpgsql security definer
set search_path=public,private,pg_temp
as $$
declare v_task public.tasks%rowtype; v_deadline timestamptz; v_requires_justification boolean; v_justification text; v_result text;
begin
 select * into v_task from public.tasks where id=p_task_id for update; if not found then raise exception 'Task not found'; end if;
 if v_task.owner_id<>auth.uid() then raise exception 'Only task owner can submit the task'; end if;
 if v_task.started_at is null or v_task.status<>'قيد التنفيذ' then raise exception 'TASK_MUST_BE_STARTED'; end if;
 if nullif(trim(coalesce(v_task.blocker_note,'')),'') is not null then raise exception 'TASK_BLOCKER_MUST_BE_CLEARED'; end if;
 v_result:=nullif(trim(coalesce(p_result_description,'')),''); if v_result is null then raise exception 'RESULT_DESCRIPTION_REQUIRED'; end if;
 v_deadline:=private.task_deadline(v_task.due_date,v_task.due_time);
 v_requires_justification:=(v_deadline is not null and now()>v_deadline) or v_task.justification_requested_at is not null;
 v_justification:=coalesce(nullif(trim(coalesce(p_justification,'')),''),v_task.delay_justification);
 if v_requires_justification and v_justification is null then raise exception 'DELAY_JUSTIFICATION_REQUIRED'; end if;
 update public.tasks set status='بانتظار المراجعة',review_requested_at=now(),reviewed_at=null,reviewed_by=null,review_note=null,result_description=v_result,quality_score=null,evaluation_note=null,evaluated_by=null,evaluated_at=null,delay_justification=case when v_requires_justification then v_justification else delay_justification end,justification_submitted_at=case when v_requires_justification then coalesce(justification_submitted_at,now()) else justification_submitted_at end,updated_at=now() where id=p_task_id;
 insert into public.task_comments(task_id,author_id,comment_type,body) values(p_task_id,auth.uid(),'Completion',v_result);
 insert into public.task_activity_events(task_id,actor_id,event_type,details) values(p_task_id,auth.uid(),'TASK_SUBMITTED_FOR_REVIEW',jsonb_build_object('deadline',v_deadline,'late',v_deadline is not null and now()>v_deadline,'result_description',v_result));
 perform private.notify_task_participants_v4(p_task_id,auth.uid(),'TASK_PENDING_REVIEW','مهمة بانتظار المراجعة',v_task.name,'V4:PENDING_REVIEW:'||p_task_id::text||':'||extract(epoch from now())::bigint::text);
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'SUBMIT_TASK_RESULT','task',p_task_id::text,jsonb_build_object('deadline',v_deadline,'late',v_deadline is not null and now()>v_deadline,'result_description',v_result,'justification',case when v_requires_justification then v_justification else null end));
end $$;

create or replace function public.review_finance_task_scored(p_task_id uuid,p_approve boolean,p_quality_score numeric default null,p_note text default null)
returns void
language plpgsql security definer
set search_path=public,private,pg_temp
as $$
declare v_task public.tasks%rowtype; v_role text:=private.current_role(); v_score numeric;
begin
 select * into v_task from public.tasks where id=p_task_id for update; if not found then raise exception 'Task not found'; end if;
 if v_task.status<>'بانتظار المراجعة' then raise exception 'Task is not awaiting review'; end if;
 if not (auth.uid()=v_task.reviewer_id or v_role='CFO' or (v_role='Supervisor' and v_task.owner_id<>auth.uid())) then raise exception 'Not authorized to review this task'; end if;
 if p_approve then
   v_score:=p_quality_score; if v_score is null or v_score<0 or v_score>100 then raise exception 'QUALITY_SCORE_REQUIRED_0_100'; end if;
   update public.tasks set status='مكتمل',completed_at=now(),reviewed_at=now(),reviewed_by=auth.uid(),review_note=nullif(trim(coalesce(p_note,'')),''),quality_score=v_score,evaluation_note=nullif(trim(coalesce(p_note,'')),''),evaluated_by=auth.uid(),evaluated_at=now(),updated_at=now() where id=p_task_id;
 else
   update public.tasks set status='قيد التنفيذ',review_requested_at=null,reviewed_at=now(),reviewed_by=auth.uid(),review_note=nullif(trim(coalesce(p_note,'')),''),completed_at=null,quality_score=null,evaluation_note=null,evaluated_by=null,evaluated_at=null,rework_count=coalesce(rework_count,0)+1,updated_at=now() where id=p_task_id;
 end if;
 insert into public.task_activity_events(task_id,actor_id,event_type,details) values(p_task_id,auth.uid(),case when p_approve then 'TASK_APPROVED_SCORED' else 'TASK_RETURNED_FOR_REWORK' end,jsonb_build_object('note',nullif(trim(coalesce(p_note,'')),''),'quality_score',case when p_approve then v_score else null end));
 perform private.notify_task_participants_v4(p_task_id,auth.uid(),case when p_approve then 'TASK_APPROVED' else 'TASK_REWORK' end,case when p_approve then 'تم اعتماد المهمة' else 'تمت إعادة المهمة للعمل' end,v_task.name,'V4:REVIEW:'||p_task_id::text||':'||extract(epoch from now())::bigint::text);
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),case when p_approve then 'APPROVE_TASK_WITH_SCORE' else 'RETURN_TASK_REVIEW' end,'task',p_task_id::text,jsonb_build_object('note',nullif(trim(coalesce(p_note,'')),''),'quality_score',case when p_approve then v_score else null end));
end $$;

create or replace function public.add_task_comment(p_task_id uuid,p_body text,p_comment_type text default 'Comment')
returns uuid
language plpgsql security definer
set search_path=public,private,pg_temp
as $$
declare v_task public.tasks%rowtype; v_id uuid; v_type text:=coalesce(nullif(trim(p_comment_type),''),'Comment');
begin
 if nullif(trim(coalesce(p_body,'')),'') is null then raise exception 'Comment is required'; end if;
 select * into v_task from public.tasks where id=p_task_id; if not found then raise exception 'Task not found'; end if;
 if not private.can_access_task(v_task) then raise exception 'Not authorized for this task'; end if;
 insert into public.task_comments(task_id,author_id,comment_type,body) values(p_task_id,auth.uid(),v_type,trim(p_body)) returning id into v_id;
 insert into public.task_activity_events(task_id,actor_id,event_type,details) values(p_task_id,auth.uid(),'COMMENT_ADDED',jsonb_build_object('comment_id',v_id,'comment_type',v_type));
 perform private.notify_task_participants_v4(p_task_id,auth.uid(),'TASK_COMMENT','تحديث على المهمة',v_task.name||': '||left(trim(p_body),180),'V4:COMMENT:'||v_id::text);
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'ADD_TASK_COMMENT','task',p_task_id::text,jsonb_build_object('comment_type',v_type));
 return v_id;
end $$;

create or replace function public.get_work_item_actions_safe_v4(p_work_item_id uuid)
returns jsonb
language plpgsql security definer
set search_path=public,private,pg_temp
as $$
declare v jsonb;
begin
 begin
   select coalesce(jsonb_agg(jsonb_build_object('rule_id',x.rule_id,'action',x.action_key,'next_status',x.next_status,'audit_event',x.audit_event,'handler',x.handler_key) order by x.action_key),'[]'::jsonb) into v
   from public.get_work_item_actions(p_work_item_id) x;
 exception when others then v:='[]'::jsonb; end;
 return coalesce(v,'[]'::jsonb);
end $$;

create or replace function public.try_perform_work_item_action_v4(p_work_item_id uuid,p_action text,p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path=public,private,pg_temp
as $$
declare w public.work_items%rowtype; r record; v_role text:=private.current_role(); v_error text;
begin
 select * into w from public.work_items where id=p_work_item_id; if not found then return jsonb_build_object('ok',false,'error','WORK_ITEM_NOT_FOUND'); end if;
 if w.source_entity_type='task' and p_action in ('COMPLETE','APPROVE_COMPLETION','RETURN_REWORK') then
   select * into r from private.resolve_workcenter_rule(p_work_item_id,p_action,auth.uid(),v_role) limit 1;
   if r.rule_id is null or not coalesce(r.allowed,false) then return jsonb_build_object('ok',false,'error',coalesce(r.denial_reason,'NO_RULE')); end if;
   begin
     if p_action='COMPLETE' then
       perform public.submit_finance_task_result(w.source_entity_id::uuid,p_payload->>'result_description',p_payload->>'justification');
     elsif p_action='APPROVE_COMPLETION' then
       perform public.review_finance_task_scored(w.source_entity_id::uuid,true,nullif(p_payload->>'quality_score','')::numeric,p_payload->>'note');
     else
       perform public.review_finance_task_scored(w.source_entity_id::uuid,false,null,p_payload->>'reason');
     end if;
     perform private.ensure_task_workflow_v3(w.source_entity_id::uuid);
   exception when others then get stacked diagnostics v_error=message_text; return jsonb_build_object('ok',false,'error',v_error); end;
   return jsonb_build_object('ok',true,'action',p_action,'work_item_id',p_work_item_id);
 end if;
 return public.try_perform_work_item_action(p_work_item_id,p_action,coalesce(p_payload,'{}'::jsonb));
end $$;

create or replace function public.get_workcenter_items_v4(p_tab text default 'active',p_scope text default 'mine',p_filters jsonb default '{}')
returns table(
 work_item_id uuid,workflow_instance_id uuid,item_type text,source_type text,source_id text,title text,
 assignee_id uuid,assignee_name text,reviewer_id uuid,reviewer_name text,status text,priority text,due_at timestamptz,
 assigned_at timestamptz,started_at timestamptz,completed_at timestamptz,current_step_key text,is_overdue boolean,
 planned_minutes bigint,elapsed_minutes bigint,remaining_minutes bigint,result_description text,quality_score numeric,rework_count integer,task_source_type text,available_actions jsonb)
language sql stable security definer
set search_path=public,private,pg_temp
as $$
with ctx as (select auth.uid() uid,private.current_role() role,(now() at time zone 'Asia/Riyadh')::date today),
base as (
 select w.*,wi.current_step_key,pa.full_name assignee_name,pr.full_name reviewer_name,t.assigned_at task_assigned_at,t.result_description,t.quality_score,coalesce(t.rework_count,0) rework_count,t.source_entity_type task_source_type,
   (w.due_at is not null and w.due_at<now() and w.status not in ('Completed','Closed','Cancelled')) overdue,
   exists(select 1 from public.work_items mine where mine.workflow_instance_id=w.workflow_instance_id and mine.completed_by=(select uid from ctx) and mine.status='Completed') participated
 from public.work_items w join public.workflow_instances wi on wi.id=w.workflow_instance_id
 left join public.profiles pa on pa.id=w.assignee_id left join public.profiles pr on pr.id=w.reviewer_id
 left join public.tasks t on w.source_entity_type='task' and t.id::text=w.source_entity_id
 cross join ctx c
 where (c.role in ('CFO','Supervisor') or w.assignee_id=c.uid or w.reviewer_id=c.uid or exists(select 1 from public.work_items hx where hx.workflow_instance_id=w.workflow_instance_id and hx.completed_by=c.uid))
   and (p_scope<>'team' or c.role in ('CFO','Supervisor'))
   and (p_scope='team' or w.assignee_id=c.uid or w.reviewer_id=c.uid or exists(select 1 from public.work_items hx where hx.workflow_instance_id=w.workflow_instance_id and hx.completed_by=c.uid))
)
select b.id,b.workflow_instance_id,b.item_type,b.source_entity_type,b.source_entity_id,b.title,b.assignee_id,b.assignee_name,b.reviewer_id,b.reviewer_name,b.status,b.priority,b.due_at,
 coalesce(b.task_assigned_at,b.created_at),b.started_at,b.completed_at,b.current_step_key,b.overdue,
 case when b.due_at is null then null else floor(extract(epoch from (b.due_at-coalesce(b.task_assigned_at,b.created_at)))/60)::bigint end,
 case when b.started_at is null then 0 else floor(extract(epoch from (coalesce(b.completed_at,now())-b.started_at))/60)::bigint end,
 case when b.due_at is null then null else floor(extract(epoch from (b.due_at-now()))/60)::bigint end,
 b.result_description,b.quality_score,b.rework_count,b.task_source_type,public.get_work_item_actions_safe_v4(b.id)
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
order by case when coalesce((b.metadata->>'escalated')::boolean,false) then 0 when b.overdue then 1 when b.priority in ('حرج','Critical') then 2 when b.priority in ('عالي','High') then 3 else 4 end,b.due_at nulls last,b.created_at;
$$;

create or replace function public.get_workcenter_summary_v4(p_scope text default 'mine')
returns jsonb language sql stable security definer set search_path=public,private,pg_temp as $$
select jsonb_build_object(
 'active',(select count(*) from public.get_workcenter_items_v4('active',p_scope,'{}')),
 'waiting_on_me',(select count(*) from public.get_workcenter_items_v4('waiting_on_me',p_scope,'{}')),
 'waiting_others',(select count(*) from public.get_workcenter_items_v4('waiting_others',p_scope,'{}')),
 'exceptions',(select count(*) from public.get_workcenter_items_v4('exceptions',p_scope,'{}')),
 'completed_today',(select count(*) from public.get_workcenter_items_v4('completed_today',p_scope,'{}'))
); $$;

create or replace function public.get_team_operations_monitor_v4()
returns table(
 user_id uuid,full_name text,role text,workday_started_at timestamptz,workday_active boolean,total_today integer,not_started integer,in_progress integer,pending_review integer,completed_today integer,overdue integer,remaining_open integer,completion_today_rate numeric,current_work text,
 ytd_total integer,ytd_completed integer,ytd_completion_rate numeric,ytd_on_time_rate numeric,ytd_quality_avg numeric,month_quality_avg numeric)
language sql stable security definer set search_path=public,private,pg_temp as $$
with ctx as(select (now() at time zone 'Asia/Riyadh')::date today,date_trunc('year',now() at time zone 'Asia/Riyadh')::date ystart,date_trunc('month',now() at time zone 'Asia/Riyadh')::date mstart,private.current_role() caller),
people as(select p.id,p.full_name,p.role from public.profiles p,ctx c where p.active=true and p.role in ('Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant') and c.caller in ('CFO','Supervisor')),
wd as(select d.user_id,d.started_at,d.ended_at from public.daily_work_sessions d,ctx c where d.work_date=c.today),
ops as(
 select pe.id,
 count(w.id) filter(where w.status in ('Assigned','Ready','Started','In Progress','Paused','Blocked','Extension Requested','Returned for Rework','Pending Review') or (w.status='Completed' and (w.completed_at at time zone 'Asia/Riyadh')::date=c.today))::int total_today,
 count(w.id) filter(where w.status in ('Assigned','Ready'))::int not_started,
 count(w.id) filter(where w.status in ('Started','In Progress','Paused','Blocked','Extension Requested','Returned for Rework'))::int in_progress,
 count(w.id) filter(where w.status='Pending Review')::int pending_review,
 count(w.id) filter(where w.status='Completed' and (w.completed_at at time zone 'Asia/Riyadh')::date=c.today)::int completed_today,
 count(w.id) filter(where w.due_at<now() and w.status not in ('Completed','Closed','Cancelled','Waiting'))::int overdue,
 count(w.id) filter(where w.status in ('Assigned','Ready','Started','In Progress','Paused','Blocked','Extension Requested','Returned for Rework','Pending Review'))::int remaining_open,
 string_agg(w.title,' | ' order by w.started_at desc nulls last) filter(where w.status in ('Started','In Progress')) current_work
 from people pe cross join ctx c left join public.work_items w on w.assignee_id=pe.id and w.performance_credit=true and w.status<>'Waiting' group by pe.id),
ytd as(
 select pe.id,count(w.id) filter(where w.created_at::date>=c.ystart and w.status<>'Waiting')::int total,
 count(w.id) filter(where w.status='Completed' and (w.completed_at at time zone 'Asia/Riyadh')::date>=c.ystart)::int completed,
 count(w.id) filter(where w.status='Completed' and w.due_at is not null and w.completed_at<=w.due_at and (w.completed_at at time zone 'Asia/Riyadh')::date>=c.ystart)::int ontime,
 count(w.id) filter(where w.status='Completed' and w.due_at is not null and (w.completed_at at time zone 'Asia/Riyadh')::date>=c.ystart)::int tracked
 from people pe cross join ctx c left join public.work_items w on w.assignee_id=pe.id and w.performance_credit=true group by pe.id),
qual as(select pe.id,avg(t.quality_score) filter(where t.status='مكتمل' and t.completed_at::date>=c.ystart) yavg,avg(t.quality_score) filter(where t.status='مكتمل' and t.completed_at::date>=c.mstart) mavg from people pe cross join ctx c left join public.tasks t on t.owner_id=pe.id group by pe.id)
select pe.id,pe.full_name,pe.role,wd.started_at,(wd.started_at is not null and wd.ended_at is null),coalesce(o.total_today,0),coalesce(o.not_started,0),coalesce(o.in_progress,0),coalesce(o.pending_review,0),coalesce(o.completed_today,0),coalesce(o.overdue,0),coalesce(o.remaining_open,0),
 case when coalesce(o.total_today,0)=0 then 0 else round(o.completed_today*100.0/o.total_today,1) end,o.current_work,
 coalesce(y.total,0),coalesce(y.completed,0),case when coalesce(y.total,0)=0 then 0 else round(y.completed*100.0/y.total,1) end,case when coalesce(y.tracked,0)=0 then 0 else round(y.ontime*100.0/y.tracked,1) end,round(coalesce(q.yavg,0),1),round(coalesce(q.mavg,0),1)
from people pe left join ops o on o.id=pe.id left join ytd y on y.id=pe.id left join qual q on q.id=pe.id left join wd on wd.user_id=pe.id
order by case pe.role when 'Supervisor' then 1 when 'BankAccountant' then 2 when 'GLAccountant' then 3 when 'ARAccountant' then 4 when 'APAccountant' then 5 else 9 end,pe.full_name;
$$;

create or replace function public.get_employee_performance_report_v4(p_user_id uuid,p_from date,p_to date)
returns jsonb
language plpgsql stable security definer set search_path=public,private,pg_temp
as $$
declare v_role text:=private.current_role(); v_from date:=coalesce(p_from,date_trunc('month',now() at time zone 'Asia/Riyadh')::date); v_to date:=coalesce(p_to,(now() at time zone 'Asia/Riyadh')::date); v_emp jsonb; v_items jsonb; v_summary jsonb;
begin
 if not (v_role in ('CFO','Supervisor') or auth.uid()=p_user_id) then raise exception 'NOT_AUTHORIZED'; end if;
 select jsonb_build_object('id',p.id,'full_name',p.full_name,'role',p.role) into v_emp from public.profiles p where p.id=p_user_id;
 if v_emp is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('work_item_id',w.id,'date',(w.completed_at at time zone 'Asia/Riyadh')::date,'title',w.title,'item_type',w.item_type,'source_type',w.source_entity_type,'source_id',w.source_entity_id,'assigned_at',coalesce(t.assigned_at,w.created_at),'started_at',w.started_at,'completed_at',w.completed_at,'due_at',w.due_at,'on_time',case when w.due_at is null then null else w.completed_at<=w.due_at end,'quality_score',t.quality_score,'result_description',t.result_description,'rework_count',coalesce(t.rework_count,0),'extension_count',(select count(*) from public.task_extension_requests er where er.task_id=t.id)) order by w.completed_at desc),'[]'::jsonb) into v_items
 from public.work_items w left join public.tasks t on w.source_entity_type='task' and t.id::text=w.source_entity_id
 where w.performance_credit=true and w.status='Completed' and w.completed_by=p_user_id and (w.completed_at at time zone 'Asia/Riyadh')::date between v_from and v_to;
 select jsonb_build_object(
 'completed',count(*),
 'manual_tasks',count(*) filter(where w.item_type='MANUAL_TASK'),
 'transaction_items',count(*) filter(where w.item_type<>'MANUAL_TASK'),
 'on_time',count(*) filter(where w.due_at is not null and w.completed_at<=w.due_at),
 'late',count(*) filter(where w.due_at is not null and w.completed_at>w.due_at),
 'on_time_rate',case when count(*) filter(where w.due_at is not null)=0 then 0 else round(count(*) filter(where w.due_at is not null and w.completed_at<=w.due_at)*100.0/count(*) filter(where w.due_at is not null),1) end,
 'avg_quality_score',round(coalesce(avg(t.quality_score),0),1),
 'rework_count',coalesce(sum(coalesce(t.rework_count,0)),0),
 'extension_count',coalesce(sum((select count(*) from public.task_extension_requests er where er.task_id=t.id)),0)
 ) into v_summary
 from public.work_items w left join public.tasks t on w.source_entity_type='task' and t.id::text=w.source_entity_id
 where w.performance_credit=true and w.status='Completed' and w.completed_by=p_user_id and (w.completed_at at time zone 'Asia/Riyadh')::date between v_from and v_to;
 return jsonb_build_object('employee',v_emp,'from',v_from,'to',v_to,'summary',coalesce(v_summary,'{}'::jsonb),'items',coalesce(v_items,'[]'::jsonb),'history_retained',true);
end $$;

grant execute on function public.submit_finance_task_result(uuid,text,text) to authenticated;
grant execute on function public.review_finance_task_scored(uuid,boolean,numeric,text) to authenticated;
grant execute on function public.get_work_item_actions_safe_v4(uuid) to authenticated;
grant execute on function public.try_perform_work_item_action_v4(uuid,text,jsonb) to authenticated;
grant execute on function public.get_workcenter_items_v4(text,text,jsonb) to authenticated;
grant execute on function public.get_workcenter_summary_v4(text) to authenticated;
grant execute on function public.get_team_operations_monitor_v4() to authenticated;
grant execute on function public.get_employee_performance_report_v4(uuid,date,date) to authenticated;
