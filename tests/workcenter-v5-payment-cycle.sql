-- Execute inside BEGIN/ROLLBACK before activation. No financial transaction is executed.
do $$
declare c uuid; cfo uuid; stage uuid; done_stage uuid; d jsonb;
begin
 select id into cfo from public.profiles where active and role='CFO' limit 1;
 perform set_config('request.jwt.claim.sub',cfo::text,true);
 insert into private.workcenter_cycles(label,started_at,active) values('PAYMENT ROLLBACK TEST',now()-interval '1 second',true) returning id into c;
 update public.work_items set updated_at=now();
 if exists(select 1 from private.workcenter_cycle_items where cycle_id=c) then raise exception 'UNCHANGED_HISTORY_RESURRECTED'; end if;
 select id into stage from public.work_items where source_entity_type='payment' and status='Waiting' limit 1;
 if stage is null then raise exception 'TEST_REQUIRES_WAITING_STAGE'; end if;
 update public.work_items set status='Ready' where id=stage;
 if not exists(select 1 from private.workcenter_cycle_items where cycle_id=c and work_item_id=stage) then raise exception 'NEW_PAYMENT_STAGE_MISSING'; end if;
 update public.work_items set updated_at=now() where id=stage;
 if (select count(*) from private.workcenter_cycle_items where cycle_id=c and work_item_id=stage)<>1 then raise exception 'PAYMENT_STAGE_DUPLICATED'; end if;
 select id into done_stage from public.work_items where source_entity_type='payment' and status='Ready' and id<>stage limit 1;
 update public.work_items set status='Completed',completed_at=now(),completed_by=cfo where id=done_stage;
 d:=public.get_workcenter_dashboard_v5('team','{}');
 if (d#>>'{summary,total}')::int<>2 or (d#>>'{summary,completed}')::int<>1 then raise exception 'PAYMENT_EVENT_COUNT: %',d; end if;
 if has_function_privilege('anon','public.get_workcenter_dashboard_v5(text,jsonb)','EXECUTE') then raise exception 'ANON_RPC_PRIVILEGE'; end if;
 if has_table_privilege('authenticated','private.workcenter_cycle_items','INSERT') then raise exception 'CYCLE_MEMBERSHIP_WRITABLE'; end if;
end $$;
select 'PASS: unchanged history hidden, new payment stage admitted once, new completion credited once, API grants restricted' as result;

