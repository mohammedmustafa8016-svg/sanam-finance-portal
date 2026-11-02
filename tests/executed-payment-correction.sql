do $$begin if exists(select 1 from public.profiles where email not like '%@local.invalid') then raise exception 'LOCAL_FIXTURE_REQUIRED';end if;end$$;
do $$declare cfo uuid;banker uuid;account uuid;payment uuid;balance_now numeric;u record;begin
 select id into cfo from public.profiles where role='CFO' limit 1;
 select id into banker from public.profiles where role='BankAccountant' limit 1;
 insert into public.bank_accounts(company,bank_name,account_name,balance,account_type) values('LOCAL-CORRECTION','Test','Operating',10000,'Operational') returning id into account;
 insert into public.payments(company,beneficiary,amount,due_date,bank_account_id,supervisor_status,cfo_status,status,requested_by) values('LOCAL-CORRECTION','Synthetic correction',1000,current_date,account,'موافق','موافق','معتمد للدفع',banker) returning id into payment;
 perform set_config('request.jwt.claim.sub',banker::text,true);
 perform public.execute_payment(payment);
 for u in select id from public.profiles where role<>'CFO' and active loop
  perform set_config('request.jwt.claim.sub',u.id::text,true);
  begin perform public.cfo_correct_executed_payment_amount(payment,1000,1200,'Synthetic correction reason');raise exception 'NON_CFO_CORRECTED';exception when others then if sqlerrm<>'CFO_REQUIRED' then raise;end if;end;
 end loop;
 perform set_config('request.jwt.claim.sub',cfo::text,true);
 perform public.cfo_correct_executed_payment_amount(payment,1000,1200,'Correct actual bank amount');
 select balance into balance_now from public.bank_accounts where id=account;
 if balance_now<>8800 then raise exception 'WRONG_INCREASE_EFFECT';end if;
 begin perform public.cfo_correct_executed_payment_amount(payment,1000,1200,'Retry same correction safely');raise exception 'STALE_WRITE_ACCEPTED';exception when others then if sqlerrm<>'PAYMENT_CORRECTION_STALE_REFRESH' then raise;end if;end;
 perform public.cfo_correct_executed_payment_amount(payment,1200,900,'Correct actual bank amount again');
 if (select balance from public.bank_accounts where id=account)<>9100 then raise exception 'WRONG_DECREASE_EFFECT';end if;
 if (select amount from public.payment_bank_balance_effects where payment_id=payment)<>1000 then raise exception 'ORIGINAL_EFFECT_CHANGED';end if;
 if (select count(*) from public.audit_log where action='EXECUTED_PAYMENT_AMOUNT_CORRECTED' and entity_id=payment::text)<>2 then raise exception 'MISSING_CORRECTION_AUDIT';end if;
 begin perform public.cfo_correct_executed_payment_amount(payment,900,0,'Invalid zero correction amount');raise exception 'ZERO_ACCEPTED';exception when others then if sqlerrm<>'PAYMENT_CORRECTION_INVALID_AMOUNT' then raise;end if;end;
 begin perform public.cfo_correct_executed_payment_amount(payment,900,800,'short');raise exception 'REASON_NOT_ENFORCED';exception when others then if sqlerrm<>'PAYMENT_CORRECTION_REASON_REQUIRED' then raise;end if;end;
 perform public.cfo_correct_executed_payment_amount(payment,900,20000,'Allow negative recorded bank balance');
 if (select balance from public.bank_accounts where id=account)<>-10000 then raise exception 'NEGATIVE_BALANCE_CORRECTION_FAILED';end if;
 if has_function_privilege('anon','public.cfo_correct_executed_payment_amount(uuid,numeric,numeric,text)','execute') then raise exception 'ANON_CORRECTION_ACCESS';end if;
end$$;
