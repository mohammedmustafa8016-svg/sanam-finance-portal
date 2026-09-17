-- Run after the migration inside BEGIN/ROLLBACK. Never commit these fixtures.
do $$
declare cfo uuid; sup uuid; emp uuid; other_emp uuid; task_id uuid; item_id uuid; cycle uuid; d jsonb; r jsonb; old_item uuid;
begin
 select id into cfo from public.profiles where active and role='CFO' limit 1;
 select id into sup from public.profiles where active and role='Supervisor' limit 1;
 select id into emp from public.profiles where active and role='BankAccountant' limit 1;
 select id into other_emp from public.profiles where active and role='ARAccountant' limit 1;
 insert into private.workcenter_cycles(label,started_at,active) values('ROLLBACK TEST',now()-interval '1 second',true) returning id into cycle;
 perform set_config('request.jwt.claim.sub',cfo::text,true);
 d:=public.get_workcenter_dashboard_v5('team','{}');
 if (d#>>'{summary,total}')::int<>0 then raise exception 'RESET_NOT_EMPTY'; end if;
 select id into old_item from public.work_items order by created_at limit 1;
 update public.work_items set updated_at=now() where id=old_item;
 if exists(select 1 from private.workcenter_cycle_items where work_item_id=old_item) then raise exception 'OLD_SYNC_REAPPEARED'; end if;
 r:=public.try_perform_work_item_action_v5(old_item,'START','{}');
 if r->>'error'<>'WORK_ITEM_OUTSIDE_CURRENT_CYCLE' then raise exception 'OLD_ITEM_ACTION_NOT_GUARDED'; end if;
 insert into public.tasks(name,owner_id,reviewer_id,due_date,due_time,status,priority,created_by,assigned_at,opened_at,opened_by)
 values('V5_ROLLBACK_TEST',emp,sup,(now() at time zone 'Asia/Riyadh')::date+1,'17:00','لم يبدأ','عادي',cfo,now(),now(),cfo) returning id into task_id;
 perform private.ensure_task_workflow_v3(task_id);
 select id into item_id from public.work_items where source_entity_type='task' and source_entity_id=task_id::text;
 d:=public.get_workcenter_dashboard_v5('team','{}');
 if (d#>>'{summary,ready}')::int<>1 then raise exception 'NEW_TASK_NOT_VISIBLE: %',d; end if;
 if (d->'team'->0->>'quality_avg') is not null then raise exception 'QUALITY_MUST_BE_NULL'; end if;
 perform set_config('request.jwt.claim.sub',other_emp::text,true);
 d:=public.get_workcenter_dashboard_v5('mine','{}');
 if jsonb_array_length(d->'items')<>0 then raise exception 'OTHER_EMPLOYEE_LEAK'; end if;
 begin
   perform public.get_workcenter_dashboard_v5('team','{}'); raise exception 'TEAM_LEAK';
 exception when others then if sqlerrm<>'TEAM_SCOPE_NOT_ALLOWED' then raise; end if; end;
 begin
   perform public.get_workcenter_detail_v5(item_id); raise exception 'DETAIL_LEAK';
 exception when others then if sqlerrm<>'NOT_AUTHORIZED' then raise; end if; end;
 perform set_config('request.jwt.claim.sub',emp::text,true);
 r:=public.try_perform_work_item_action_v5(item_id,'START','{}');
 if not (r->>'ok')::boolean then raise exception 'START: %',r; end if;
 r:=public.try_perform_work_item_action_v5(item_id,'COMMENT','{"body":"Testing comment"}');
 if not (r->>'ok')::boolean then raise exception 'COMMENT: %',r; end if;
 r:=public.try_perform_work_item_action_v5(item_id,'REPORT_BLOCKER','{"reason":"Awaiting source documents"}');
 if not (r->>'ok')::boolean then raise exception 'BLOCK: %',r; end if;
 d:=public.get_workcenter_dashboard_v5('mine','{}');
 if (d#>>'{summary,attention}')::int<>1 then raise exception 'BLOCK_NOT_CLASSIFIED'; end if;
 r:=public.try_perform_work_item_action_v5(item_id,'RESOLVE_BLOCKER','{}');
 if not (r->>'ok')::boolean then raise exception 'UNBLOCK: %',r; end if;
 r:=public.try_perform_work_item_action_v5(item_id,'REQUEST_EXTENSION',jsonb_build_object('requested_due_date',(now() at time zone 'Asia/Riyadh')::date+2,'requested_due_time','17:00','justification','Source delay'));
 if not (r->>'ok')::boolean then raise exception 'EXTENSION: %',r; end if;
 perform set_config('request.jwt.claim.sub',sup::text,true);
 d:=public.get_workcenter_dashboard_v5('team','{}');
 if (d#>>'{summary,reviews}')::int<>1 or (d#>>'{summary,my_decisions}')::int<>1 then raise exception 'EXTENSION_NOT_REVIEW: %',d; end if;
 r:=public.try_perform_work_item_action_v5(item_id,'APPROVE_EXTENSION','{}');
 if not (r->>'ok')::boolean then raise exception 'EXTENSION_APPROVAL: %',r; end if;
 perform set_config('request.jwt.claim.sub',emp::text,true);
 r:=public.try_perform_work_item_action_v5(item_id,'SUBMIT_FOR_REVIEW','{"result_description":"Reconciled test result"}');
 if not (r->>'ok')::boolean then raise exception 'SUBMIT: %',r; end if;
 r:=public.try_perform_work_item_action_v5(item_id,'APPROVE_COMPLETION','{"quality_score":99}');
 if (r->>'ok')::boolean then raise exception 'SELF_REVIEW_ALLOWED'; end if;
 perform set_config('request.jwt.claim.sub',sup::text,true);
 r:=public.try_perform_work_item_action_v5(item_id,'RETURN_REWORK','{"reason":"Correct the result"}');
 if not (r->>'ok')::boolean then raise exception 'REWORK: %',r; end if;
 perform private.ensure_task_workflow_v3(task_id);
 if (select status from public.work_items where id=item_id)<>'Returned for Rework' then raise exception 'REWORK_LOST'; end if;
 perform set_config('request.jwt.claim.sub',emp::text,true);
 r:=public.try_perform_work_item_action_v5(item_id,'RESUME','{}');
 if not (r->>'ok')::boolean then raise exception 'RESUME: %',r; end if;
 r:=public.try_perform_work_item_action_v5(item_id,'COMPLETE','{"result_description":"Corrected result"}');
 if not (r->>'ok')::boolean then raise exception 'COMPLETE: %',r; end if;
 perform set_config('request.jwt.claim.sub',sup::text,true);
 r:=public.try_perform_work_item_action_v5(item_id,'APPROVE_COMPLETION','{"quality_score":92,"note":"Verified"}');
 if not (r->>'ok')::boolean then raise exception 'APPROVE: %',r; end if;
 d:=public.get_workcenter_dashboard_v5('team','{}');
 if (d#>>'{summary,completed}')::int<>1 or (d#>>'{summary,reviews}')::int<>0 then raise exception 'COMPLETED_COUNT'; end if;
 if (d->'items'->0->>'quality_score')::numeric<>92 then raise exception 'SCORE'; end if;
 perform private.ensure_task_workflow_v3(task_id);
 if (select count(*) from private.workcenter_cycle_items where work_item_id=item_id)<>1 then raise exception 'DOUBLE_COUNT'; end if;
 d:=public.get_workcenter_detail_v5(item_id);
 if jsonb_array_length(d->'comments')<1 or jsonb_array_length(d->'extensions')<>1 then raise exception 'DETAIL_MISSING'; end if;
 perform set_config('request.jwt.claim.sub','',true);
 begin
   perform public.get_workcenter_dashboard_v5('mine','{}'); raise exception 'ANON_LEAK';
 exception when others then if sqlerrm<>'NOT_AUTHORIZED' then raise; end if; end;
end $$;
select 'PASS: clean cycle, old sync, role isolation, start, comment, blocker, extension, review, rework, resume, scoring, no duplicates, detail, anonymous denial' as result;

