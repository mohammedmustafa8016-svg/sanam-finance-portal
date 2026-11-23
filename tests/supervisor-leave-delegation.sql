-- Disposable fixture database only; harness wraps every test in BEGIN/ROLLBACK.
do $$
declare cfo uuid; sup uuid; sub uuid; bank_user uuid; viewer uuid; lease uuid;
 task_key uuid; own_task uuid; payment_key uuid; own_payment uuid; bank_key uuid;
 d jsonb; role_before text; day_value date:=(now() at time zone 'Asia/Riyadh')::date;
begin
 if exists(select 1 from public.profiles where email not like '%@local.invalid') then raise exception 'LOCAL_FIXTURE_REQUIRED';end if;
 select id into strict cfo from public.profiles where role='CFO' limit 1;
 select id into strict sup from public.profiles where role='Supervisor' limit 1;
 select id into strict sub from public.profiles where role='ARAccountant' limit 1;
 select id into strict bank_user from public.profiles where role='BankAccountant' limit 1;
 select id into strict viewer from public.profiles where role='Viewer' limit 1;
 perform set_config('request.jwt.claim.sub',cfo::text,true);
 insert into public.leave_delegations(absent_user_id,substitute_user_id,date_from,date_to,created_by)
 values(sup,sub,day_value,day_value,cfo) returning id into lease;
 insert into public.bank_accounts(company,bank_name,account_name,balance,account_type)
 values('LOCAL-DELEGATION','Bank','Operating',10000,'Operational') returning id into bank_key;
 insert into public.payments(company,beneficiary,amount,due_date,bank_account_id,requested_by)
 values('LOCAL-DELEGATION','Synthetic third party',50,day_value,bank_key,bank_user) returning id into payment_key;
 insert into public.payments(company,beneficiary,amount,due_date,bank_account_id,requested_by)
 values('LOCAL-DELEGATION','Synthetic self request',60,day_value,bank_key,sub) returning id into own_payment;
 insert into public.tasks(name,owner_id,reviewer_id,due_date,due_time,status,priority,created_by,assigned_at,opened_at,opened_by)
 values('LOCAL-DELEGATION',sup,cfo,day_value+1,'17:00','لم يبدأ','عادي',cfo,now(),now(),cfo) returning id into task_key;
 insert into public.tasks(name,owner_id,reviewer_id,due_date,due_time,status,priority,created_by,assigned_at,opened_at,opened_by)
 values('LOCAL-SELF-REVIEW',sub,sup,day_value+1,'17:00','بانتظار المراجعة','عادي',cfo,now(),now(),cfo) returning id into own_task;
 perform set_config('request.jwt.claim.sub',sub::text,true);
 role_before:=private.current_role();
 d:=public.get_my_leave_delegation_context();
 if d->>'user_id'<>sub::text or not d->'roles' ? 'Supervisor' or jsonb_array_length(d->'delegations')<>1 then raise exception 'LIVE_CONTEXT_MISSING: %',d;end if;
 if private.current_role()<>'ARAccountant' or private.effective_supervisor_role()<>'Supervisor' then raise exception 'BASE_ROLE_CHANGED';end if;
 if not public.has_user_permission('page.control') or not public.has_user_permission('page.workload') then raise exception 'PAGES_NOT_DELEGATED';end if;
 if public.has_user_permission('page.permissions') then raise exception 'CFO_ADMIN_LEAK';end if;
 perform public.perform_supervisor_delegated_rpc('get_workcenter_dashboard_v5',jsonb_build_object('p_scope','team','p_filters','{}'::jsonb));
 if private.current_role()<>role_before then raise exception 'CONTEXT_NOT_RESTORED';end if;
 perform public.perform_supervisor_delegated_rpc('approve_payment_supervisor',jsonb_build_object('p_payment_id',payment_key));
 if (select supervisor_status from public.payments where id=payment_key)<>'موافق' then raise exception 'PAYMENT_APPROVAL_FAILED';end if;
 if not exists(select 1 from public.audit_log where actor_id=sub and action='SUPERVISOR_DELEGATED_ACTION' and details->>'delegation_id'=lease::text) then raise exception 'ACTOR_AUDIT_MISSING';end if;
 begin
  perform public.perform_supervisor_delegated_rpc('approve_payment_supervisor',jsonb_build_object('p_payment_id',own_payment));raise exception 'SELF_PAYMENT_ALLOWED';
 exception when others then if sqlerrm<>'DELEGATED_SELF_REVIEW_DENIED' then raise;end if;end;
 begin
  perform public.perform_supervisor_delegated_rpc('review_finance_task_scored',jsonb_build_object('p_task_id',own_task,'p_approve',true,'p_quality_score',95));raise exception 'SELF_TASK_ALLOWED';
 exception when others then if sqlerrm<>'DELEGATED_SELF_REVIEW_DENIED' then raise;end if;end;
 begin
  perform public.perform_supervisor_delegated_rpc('set_user_permission','{}');raise exception 'CFO_RPC_ALLOWED';
 exception when others then if sqlerrm<>'DELEGATED_FUNCTION_NOT_ALLOWED' then raise;end if;end;
 begin
  perform public.perform_supervisor_delegated_rpc('get_workcenter_dashboard_v5','{"injected":"x"}');raise exception 'UNKNOWN_ARGUMENT_ALLOWED';
 exception when others then if sqlerrm<>'DELEGATED_ARGUMENTS_INVALID' then raise;end if;end;
 perform public.perform_supervisor_delegated_rpc('start_finance_task',jsonb_build_object('p_task_id',task_key));
 perform public.perform_supervisor_delegated_rpc('submit_finance_task_result',jsonb_build_object('p_task_id',task_key,'p_result_description','Synthetic delegated result'));
 if (select status from public.tasks where id=task_key)<>'بانتظار المراجعة' then raise exception 'DELEGATED_SUBMIT_FAILED';end if;
 begin
  perform public.perform_supervisor_delegated_rpc('review_finance_task_scored',jsonb_build_object('p_task_id',task_key,'p_approve',true,'p_quality_score',95));raise exception 'DELEGATED_EXECUTOR_SELF_REVIEW_ALLOWED';
 exception when others then if sqlerrm<>'DELEGATED_SELF_REVIEW_DENIED' then raise;end if;end;
 perform set_config('request.jwt.claim.sub',cfo::text,true);
 perform public.review_finance_task_scored(task_key,true,95,'Independent review');
 perform set_config('request.jwt.claim.sub',sub::text,true);
 if (select role from public.profiles where id=sub)<>'ARAccountant' then raise exception 'STORED_ROLE_CHANGED';end if;
 update public.leave_delegations set date_from=day_value-2,date_to=day_value-1 where id=lease;
 if private.effective_supervisor_role()<>'ARAccountant' or public.get_my_leave_delegation_context()->'roles' ? 'Supervisor' then raise exception 'EXPIRED_DELEGATION_ACTIVE';end if;
 begin
  perform public.perform_supervisor_delegated_rpc('get_workcenter_dashboard_v5','{}');raise exception 'EXPIRED_RPC_ALLOWED';
 exception when others then if sqlerrm<>'SUPERVISOR_DELEGATION_INACTIVE' then raise;end if;end;
 update public.leave_delegations set date_from=day_value+1,date_to=day_value+2 where id=lease;
 if private.effective_supervisor_role()<>'ARAccountant' then raise exception 'FUTURE_DELEGATION_ACTIVE';end if;
 update public.leave_delegations set date_from=day_value,date_to=day_value,active=false where id=lease;
 if private.effective_supervisor_role()<>'ARAccountant' then raise exception 'CANCELLED_DELEGATION_ACTIVE';end if;
 update public.leave_delegations set active=true,substitute_user_id=viewer where id=lease;
 perform set_config('request.jwt.claim.sub',viewer::text,true);
 if private.effective_supervisor_role()<>'Viewer' then raise exception 'VIEWER_ESCALATED';end if;
end $$;
