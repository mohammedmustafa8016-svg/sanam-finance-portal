-- Run inside BEGIN/ROLLBACK before activation. All created tasks/templates/sessions roll back.
do $$
declare manager record; emp uuid; c uuid; t uuid; catalog uuid; d jsonb; opened int;
begin
 select id into emp from public.profiles where active and role='BankAccountant' limit 1;
 insert into private.workcenter_cycles(label,started_at,active) values('PLAN ROLLBACK TEST',now()-interval '1 second',true) returning id into c;
 for manager in select id,role from public.profiles where active and role in ('CFO','Supervisor') loop
   perform set_config('request.jwt.claim.sub',manager.id::text,true);
   perform public.start_workday('V5 rollback test');
   if not exists(select 1 from public.get_my_workday() where ended_at is null and started_at is not null) then raise exception 'WORKDAY_START_FAILED: %',manager.role; end if;
 end loop;
 perform set_config('request.jwt.claim.sub',(select id::text from public.profiles where active and role='Supervisor' limit 1),true);
 t:=public.create_finance_task_v2('V5 API ROLLBACK',emp,null,(now() at time zone 'Asia/Riyadh')::date+1,'17:00','حسب الحاجة','عادي');
 opened:=public.save_manual_daily_plan(jsonb_build_array(jsonb_build_object('name','V5 TEMPLATE ROLLBACK','owner_id',emp,'due_time','17:00','save_as_template',true,'output','Test result')));
 if opened<>1 then raise exception 'PLAN_COUNT'; end if;
 select id into catalog from public.finance_task_catalog where name='V5 TEMPLATE ROLLBACK';
 if catalog is null then raise exception 'TEMPLATE_NOT_SAVED'; end if;
 opened:=public.save_manual_daily_plan(jsonb_build_array(jsonb_build_object('catalog_id',catalog,'owner_id',emp,'due_time','17:00')));
 d:=public.get_workcenter_dashboard_v5('team','{}');
 if (d#>>'{summary,total}')::int<>3 then raise exception 'CREATION_NOT_VISIBLE: %',d; end if;
 perform set_config('request.jwt.claim.sub',emp::text,true);
 d:=public.get_workcenter_dashboard_v5('mine','{}');
 if (d#>>'{summary,total}')::int<>3 then raise exception 'EMPLOYEE_ASSIGNMENT_NOT_VISIBLE'; end if;
end $$;
select 'PASS: CFO/Supervisor start workday, one-off creation, save template, use template, assigned tasks visible to employee and manager' as result;

