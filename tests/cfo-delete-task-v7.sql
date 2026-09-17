-- Execute after the migration inside BEGIN/ROLLBACK. No test task survives.
do $$
declare cfo uuid; sup uuid; emp uuid; task_id uuid; item_id uuid; r jsonb; audit_row record; state text;
begin
 select id into cfo from public.profiles where active and role='CFO' limit 1;
 select id into sup from public.profiles where active and role='Supervisor' limit 1;
 select id into emp from public.profiles where active and role='BankAccountant' limit 1;
 foreach state in array array['لم يبدأ','قيد التنفيذ','مكتمل'] loop
   insert into public.tasks(name,owner_id,reviewer_id,due_date,due_time,status,priority,created_by,assigned_at,opened_at,opened_by,started_at,completed_at)
   values('DELETE_V7_'||state,emp,sup,(now() at time zone 'Asia/Riyadh')::date+1,'17:00',state,'عادي',cfo,now(),now(),cfo,case when state<>'لم يبدأ' then now() end,case when state='مكتمل' then now() end)
   returning id into task_id;
   perform private.ensure_task_workflow_v3(task_id);
   select id into item_id from public.work_items where source_entity_type='task' and source_entity_id=task_id::text;
   insert into public.task_comments(task_id,author_id,body,comment_type) values(task_id,emp,'Rollback comment','Comment');
   insert into public.task_notifications(user_id,task_id,notification_type,title) values(emp,task_id,'TASK_COMMENT','Rollback notification');

   perform set_config('request.jwt.claim.sub',sup::text,true);
   begin perform public.delete_finance_task_cfo_v7(task_id,'DELETE_V7_'||state,'Supervisor cannot delete');raise exception 'SUPERVISOR_DELETE_ALLOWED';exception when others then if sqlerrm<>'CFO_ONLY' then raise;end if;end;
   perform set_config('request.jwt.claim.sub',cfo::text,true);
   begin perform public.delete_finance_task_cfo_v7(task_id,'WRONG NAME','Valid deletion reason');raise exception 'BAD_CONFIRMATION_ALLOWED';exception when others then if sqlerrm<>'CONFIRMATION_NAME_MISMATCH' then raise;end if;end;
   begin perform public.delete_finance_task_cfo_v7(task_id,'DELETE_V7_'||state,'short');raise exception 'SHORT_REASON_ALLOWED';exception when others then if sqlerrm<>'DELETE_REASON_MIN_10' then raise;end if;end;
   r:=public.delete_finance_task_cfo_v7(task_id,'DELETE_V7_'||state,'Rollback deletion reason');
   if not (r->>'ok')::boolean or r->>'previous_status'<>state then raise exception 'DELETE_RESULT: %',r;end if;
   if exists(select 1 from public.tasks where id=task_id) or exists(select 1 from public.work_items where id=item_id) or exists(select 1 from private.workcenter_cycle_items where work_item_id=item_id) then raise exception 'RELATED_ROWS_REMAIN';end if;
   select * into audit_row from public.audit_log where action='CFO_DELETE_TASK' and entity_id=task_id::text order by created_at desc limit 1;
   if audit_row.actor_id<>cfo or audit_row.details#>>'{task,name}'<>'DELETE_V7_'||state or (audit_row.details#>>'{related_counts,comments}')::int<>1 or audit_row.details->>'reason'<>'Rollback deletion reason' then raise exception 'AUDIT_INCOMPLETE: %',audit_row.details;end if;
 end loop;
 if has_function_privilege('anon','public.delete_finance_task_cfo_v7(uuid,text,text)','EXECUTE') then raise exception 'ANON_GRANT';end if;
 perform set_config('request.jwt.claim.sub','',true);
 begin perform public.delete_finance_task_cfo_v7(gen_random_uuid(),'x','Long enough reason');raise exception 'ANON_DELETE_ALLOWED';exception when others then if sqlerrm<>'CFO_ONLY' then raise;end if;end;
end $$;
select 'PASS: CFO-only, confirmation and reason required, ready/in-progress/completed deletion, work-center cleanup, cascade cleanup and retained audit snapshot' result;

