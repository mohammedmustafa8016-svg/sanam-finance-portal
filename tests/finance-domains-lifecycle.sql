-- Disposable local harness only; setup and all effects are wrapped in BEGIN/ROLLBACK.
-- Exercises existing APIs and accounting invariants, without changing their implementation.
do $$begin
 if exists(select 1 from public.profiles where email not like '%@local.invalid')
 or (select count(distinct role) from public.profiles where active)<>7 then
  raise exception 'DISPOSABLE_SEVEN_ROLE_FIXTURE_REQUIRED';
 end if;
end$$;

create function pg_temp.expect_domain_denial(q text,expected text) returns void language plpgsql as $$
begin
 begin execute q;exception when others then
  if position(expected in sqlerrm)>0 then return;end if;
  raise exception 'WRONG_DENIAL expected=% actual=%',expected,sqlerrm;
 end;
 raise exception 'EXPECTED_DENIAL_NOT_RAISED: %',q;
end$$;

do $$
declare cfo uuid;sup uuid;banker uuid;gl uuid;u record;account uuid;payment uuid;fund uuid;
 settlement uuid;linked_task uuid;close_item uuid;close_task uuid;wi uuid;funding jsonb;r jsonb;
begin
 select id into cfo from public.profiles where role='CFO';
 select id into sup from public.profiles where role='Supervisor';
 select id into banker from public.profiles where role='BankAccountant';
 select id into gl from public.profiles where role='GLAccountant';
 perform set_config('request.jwt.claim.sub',cfo::text,true);
 update private.workcenter_cycles set active=false where active;
 insert into private.workcenter_cycles(label,started_at,active) values('DOMAIN HARNESS',now()-interval '1 second',true);
 insert into public.bank_accounts(company,bank_name,account_name,balance,created_by)
 values('LOCAL-DOMAINS','Local bank','Operating',10000,cfo) returning id into account;
 insert into public.payments(due_date,company,beneficiary,amount,bank_account_id,requested_by)
 values(current_date+1,'LOCAL-DOMAINS','Local vendor',125.25,account,banker) returning id into payment;
 if (select reserved_balance from public.bank_liquidity where id=account)<>125.25 then raise exception 'REQUEST_NOT_RESERVED';end if;
 insert into public.monthly_close_tasks(name,owner_id,due_date,planned_start_date,close_period,release_status)
 values('LOCAL-DOMAIN-CLOSE',banker,current_date+2,current_date,date_trunc('month',current_date)::date,'Planned') returning id into close_item;

 for u in select id,role from public.profiles where active loop
  perform set_config('request.jwt.claim.sub',u.id::text,true);
  if u.role not in ('Supervisor','CFO') then
   perform pg_temp.expect_domain_denial(format('select public.approve_payment_supervisor(%L)',payment),'Not authorized');
   perform pg_temp.expect_domain_denial(format('select public.supervisor_finalize_registered_payment(%L,''Posted'')',payment),'FINAL_POSTING_RESTRICTED');
  end if;
  if u.role<>'CFO' then
   perform pg_temp.expect_domain_denial(format('select public.approve_payment_cfo(%L)',payment),'CFO approval requires');
   perform pg_temp.expect_domain_denial(format('select public.release_monthly_close_task(%L)',close_item),'CFO_REQUIRED');
  end if;
  if u.role not in ('BankAccountant','CFO') then
   perform pg_temp.expect_domain_denial(format('select public.execute_payment(%L)',payment),'Only Bank Accountant');
  end if;
  if u.role not in ('GLAccountant','CFO') then
   perform pg_temp.expect_domain_denial(format('select public.register_payment_accounting(%L)',payment),'Only GL Accountant');
  end if;
  if u.role in ('GLAccountant','ARAccountant','Viewer') then
   perform pg_temp.expect_domain_denial(format('select public.create_imprest_fund_v2(''دائمة'',''LOCAL-DOMAINS'',''Denied'',%L,1,1,0,''سليمة'')',banker),'NOT_AUTHORIZED');
  end if;
 end loop;

 perform set_config('request.jwt.claim.sub',banker::text,true);
 perform pg_temp.expect_domain_denial(format('select public.execute_payment(%L)',payment),'not approved');
 perform set_config('request.jwt.claim.sub',gl::text,true);
 perform pg_temp.expect_domain_denial(format('select public.register_payment_accounting(%L)',payment),'must be executed');
 perform set_config('request.jwt.claim.sub',sup::text,true);
 perform public.approve_payment_supervisor(payment);
 perform set_config('request.jwt.claim.sub',cfo::text,true);
 perform public.approve_payment_cfo(payment);
 perform set_config('request.jwt.claim.sub',banker::text,true);
 perform public.execute_payment(payment);
 if (select balance from public.bank_accounts where id=account)<>9874.75 then raise exception 'BANK_DEBIT_WRONG';end if;
 if (select reserved_balance from public.bank_liquidity where id=account)<>0 then raise exception 'EXECUTED_STILL_RESERVED';end if;
 perform pg_temp.expect_domain_denial(format('select public.execute_payment(%L)',payment),'not approved');
 if (select count(*) from public.payment_bank_balance_effects where payment_id=payment)<>1 then raise exception 'DOUBLE_BANK_DEBIT';end if;
 perform set_config('request.jwt.claim.sub',gl::text,true);
 perform public.register_payment_accounting(payment);
 perform set_config('request.jwt.claim.sub',sup::text,true);
 perform public.supervisor_finalize_registered_payment(payment,'Posted');
 if (select status from public.payments where id=payment)<>'مرحّل' then raise exception 'PAYMENT_NOT_FINALIZED';end if;
 if (select balance from public.bank_accounts where id=account)<>9874.75 then raise exception 'REGISTRATION_CHANGED_BANK_BALANCE';end if;

 perform set_config('request.jwt.claim.sub',cfo::text,true);
 select id into fund from public.create_imprest_fund_v2('دائمة','LOCAL-DOMAINS','Local site fund',banker,2000,800,0,'سليمة');
 funding=public.request_imprest_funding(fund,'TOP_UP',300,'Local funding regression',null,null,current_date+1,account);
 if (select balance from public.imprest_funds where id=fund)<>2000 then raise exception 'FUNDING_CREDITED_BEFORE_EXECUTION';end if;
 payment=(funding->>'payment_id')::uuid;
 perform set_config('request.jwt.claim.sub',sup::text,true);perform public.approve_payment_supervisor(payment);
 perform set_config('request.jwt.claim.sub',cfo::text,true);perform public.approve_payment_cfo(payment);
 perform set_config('request.jwt.claim.sub',banker::text,true);perform public.execute_payment(payment);
 if (select balance from public.imprest_funds where id=fund)<>2300 then raise exception 'EXECUTED_FUNDING_NOT_CREDITED';end if;
 if (select count(*) from public.imprest_ledger_entries where payment_id=payment and entry_type='TOP_UP')<>1 then raise exception 'FUNDING_LEDGER_DUPLICATE_OR_MISSING';end if;
 perform pg_temp.expect_domain_denial(format('select public.execute_payment(%L)',payment),'not approved');
 if (select balance from public.imprest_funds where id=fund)<>2300 then raise exception 'DOUBLE_FUNDING_CREDIT';end if;
 settlement=public.open_imprest_settlement_task(fund,250,2,current_date+1,'17:00','عادي','Synthetic regression');
 select task_id into linked_task from public.imprest_settlements where id=settlement;
 if linked_task is null or not exists(select 1 from public.tasks where id=linked_task and source_entity_type='imprest_settlement' and source_entity_id=settlement::text) then raise exception 'SETTLEMENT_TASK_LINK_MISSING';end if;
 select id into wi from public.work_items where source_entity_type='task' and source_entity_id=linked_task::text;
 r=public.try_perform_work_item_action_v5(wi,'START','{}');if r->>'ok'<>'true' then raise exception 'SETTLEMENT_START: %',r;end if;
 r=public.try_perform_work_item_action_v5(wi,'SUBMIT_FOR_REVIEW','{"result_description":"Invoices reconciled and documented"}');if r->>'ok'<>'true' then raise exception 'SETTLEMENT_SUBMIT: %',r;end if;
 r=public.try_perform_work_item_action_v5(wi,'APPROVE_COMPLETION','{"quality_score":95}');if r->>'ok'='true' then raise exception 'SETTLEMENT_SELF_APPROVAL';end if;
 perform set_config('request.jwt.claim.sub',sup::text,true);
 r=public.try_perform_work_item_action_v5(wi,'APPROVE_COMPLETION','{"quality_score":95,"note":"Verified synthetic evidence"}');if r->>'ok'<>'true' then raise exception 'SETTLEMENT_APPROVAL: %',r;end if;
 if (select status from public.imprest_settlements where id=settlement)<>'Approved' then raise exception 'SETTLEMENT_STATUS_NOT_SYNCED';end if;
 if (select count(*) from public.imprest_ledger_entries where settlement_id=settlement and entry_type='SETTLEMENT')<>1 then raise exception 'SETTLEMENT_LEDGER_MISSING';end if;

 perform set_config('request.jwt.claim.sub',cfo::text,true);
 if to_regprocedure('private.close_work_in_scope(text,text)') is not null and (now() at time zone 'Asia/Riyadh')::date<date '2026-11-01' then
  perform pg_temp.expect_domain_denial(format('select public.release_monthly_close_task(%L)',close_item),'MONTHLY_CLOSE_STARTS_NOVEMBER_2026');
  raise notice 'October close is correctly blocked until 1 November; baseline verifies release/completion linkage';
  return;
 end if;
 close_task=public.release_monthly_close_task(close_item);
 if public.release_monthly_close_task(close_item)<>close_task then raise exception 'CLOSE_RELEASE_NOT_IDEMPOTENT';end if;
 if (select count(*) from public.tasks where source_entity_type='monthly_close_task' and source_entity_id=close_item::text)<>1 then raise exception 'DUPLICATE_CLOSE_TASK';end if;
 select id into wi from public.work_items where source_entity_type='task' and source_entity_id=close_task::text;
 perform set_config('request.jwt.claim.sub',banker::text,true);
 r=public.try_perform_work_item_action_v5(wi,'START','{}');if r->>'ok'<>'true' then raise exception 'CLOSE_START: %',r;end if;
 r=public.try_perform_work_item_action_v5(wi,'SUBMIT_FOR_REVIEW','{"result_description":"Month end reconciled with source"}');if r->>'ok'<>'true' then raise exception 'CLOSE_SUBMIT: %',r;end if;
 perform set_config('request.jwt.claim.sub',sup::text,true);
 r=public.try_perform_work_item_action_v5(wi,'APPROVE_COMPLETION','{"quality_score":96}');if r->>'ok'<>'true' then raise exception 'CLOSE_APPROVE: %',r;end if;
 if (select progress from public.monthly_close_tasks where id=close_item)<>100 then raise exception 'CLOSE_PROGRESS_NOT_SYNCED';end if;
end$$;
select 'PASS: seven-role domain API denials, payment approval/execution/registration/posting, bank reservation and single debit, imprest funding/settlement ledger, close idempotent release and completion' as result;
