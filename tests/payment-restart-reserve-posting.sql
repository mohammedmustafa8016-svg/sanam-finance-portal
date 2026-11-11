do $$
declare
  cfo uuid;
  supervisor uuid;
  banker uuid;
  operating uuid;
  reserve uuid;
  payment_id uuid;
  draw uuid;
  receipt uuid;
  request_id uuid:=gen_random_uuid();
  allocations jsonb;
  payment public.payments%rowtype;
begin
  if exists(select 1 from public.profiles where email not like '%@local.invalid') then
    raise exception 'LOCAL_FIXTURE_REQUIRED';
  end if;
  select id into strict cfo from public.profiles where role='CFO' limit 1;
  select id into strict supervisor from public.profiles where role='Supervisor' limit 1;
  select id into strict banker from public.profiles where role='BankAccountant' limit 1;
  perform set_config('request.jwt.claim.sub',cfo::text,true);
  insert into public.bank_accounts(company,bank_name,account_name,balance,account_type)
  values('LOCAL-RESTART','Bank','Operating',10000,'Operational') returning id into operating;
  insert into public.bank_accounts(company,bank_name,account_name,balance,account_type)
  values('LOCAL-RESTART','Bank','Reserve',5000,'Working Capital Reserve') returning id into reserve;
  insert into public.payments(company,beneficiary,amount,due_date,bank_account_id,supervisor_status,cfo_status,status,requested_by)
  values('LOCAL-RESTART','Synthetic payment',1000,current_date,operating,'موافق','موافق','معتمد للدفع',banker)
  returning id into payment_id;
  perform set_config('request.jwt.claim.sub',banker::text,true);
  perform public.execute_payment(payment_id);
  begin
    perform public.cfo_override_payment_status(payment_id,'بانتظار مراجعة المشرف','Bank did not execute');
    raise exception 'BANK_ACCOUNTANT_RESTARTED_PAYMENT';
  exception when others then if sqlerrm<>'Only CFO can override payment status' then raise;end if;end;
  perform set_config('request.jwt.claim.sub',cfo::text,true);
  perform public.cfo_correct_executed_payment_amount(payment_id,1000,1200,'Correct recorded amount');
  payment:=public.cfo_override_payment_status_v2(payment_id,'بانتظار مراجعة المشرف','Bank did not execute',true);
  if payment.executed_at is not null or payment.executed_by is not null
     or payment.supervisor_status is distinct from 'معلق' or payment.cfo_status is distinct from 'معلق'
     or payment.status is distinct from 'بانتظار مراجعة المشرف' then
    raise exception 'PAYMENT_DID_NOT_RETURN_TO_SUPERVISOR';
  end if;
  perform public.cfo_override_payment_status(payment_id,'بانتظار مراجعة المشرف','Repeat confirmation');
  if (select balance from public.bank_accounts where id=operating) is distinct from 10000::numeric then
    raise exception 'PAYMENT_BANK_REVERSAL_INCORRECT';
  end if;
  perform set_config('request.jwt.claim.sub',supervisor::text,true);
  perform public.approve_payment_supervisor(payment_id);
  perform set_config('request.jwt.claim.sub',cfo::text,true);
  perform public.approve_payment_cfo(payment_id);
  perform set_config('request.jwt.claim.sub',banker::text,true);
  perform public.execute_payment(payment_id);
  if (select balance from public.bank_accounts where id=operating) is distinct from 8800::numeric then
    raise exception 'PAYMENT_NOT_REPOSTED_AFTER_RESTART';
  end if;

  draw:=public.record_reserve_movement(reserve,'Support Draw',1000,current_date,'Synthetic recoverable draw');
  allocations:=jsonb_build_array(jsonb_build_object('source_type','Support Draw','source_id',draw,'amount',250));
  receipt:=public.record_reserve_restoration_v4(reserve,250,current_date,null,allocations,request_id,'Internal',operating);
  if public.record_reserve_restoration_v4(reserve,250,current_date,null,allocations,request_id,'Internal',operating)
     is distinct from receipt then raise exception 'RESERVE_RETRY_CREATED_NEW_RECEIPT';end if;
  if (select balance from public.bank_accounts where id=reserve) is distinct from 5250::numeric
     or (select balance from public.bank_accounts where id=operating) is distinct from 8550::numeric
     or (select outstanding_amount from public.get_recoverable_reserve_uses(reserve) where source_id=draw)
        is distinct from 750::numeric then
    raise exception 'RESERVE_TRANSFER_OR_ALLOCATION_INCORRECT';
  end if;
  receipt:=public.record_reserve_movement(reserve,'Restoration',100,current_date,null,null,draw,null);
  perform set_config('request.jwt.claim.sub',cfo::text,true);
  perform public.cfo_reconcile_reserve_restoration(receipt,'External',null,'Verified bank statement');
  perform public.cfo_reconcile_reserve_restoration(receipt,'External',null,'Verified bank statement');
  if (select balance from public.bank_accounts where id=reserve) is distinct from 5350::numeric
     or (select balance from public.bank_accounts where id=operating) is distinct from 8550::numeric then
    raise exception 'RESERVE_HISTORICAL_RECONCILIATION_INCORRECT';
  end if;
end $$;
