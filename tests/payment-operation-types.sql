do $$
declare banker uuid; account uuid; payment uuid; kind text; amount_value numeric; expected numeric:=10000;
begin
 if exists(select 1 from public.profiles where email not like '%@local.invalid') then raise exception 'LOCAL_FIXTURE_REQUIRED';end if;
 select id into strict banker from public.profiles where role='BankAccountant' limit 1;
 insert into public.bank_accounts(company,bank_name,account_name,balance,account_type)
 values('LOCAL-TYPES','Bank','Operating',expected,'Operational') returning id into account;
 perform set_config('request.jwt.claim.sub',banker::text,true);
 foreach kind in array array['Payment','Bank Action','Refund'] loop
   amount_value:=case when kind='Bank Action' then 0 else 500 end;
   insert into public.payments(company,beneficiary,amount,due_date,bank_account_id,supervisor_status,cfo_status,status,requested_by,operation_type)
   values('LOCAL-TYPES','Synthetic operation',amount_value,current_date,account,'موافق','موافق','معتمد للدفع',banker,kind)
   returning id into payment;
   if (select reserved_balance from public.bank_liquidity where id=account) is distinct from (case when kind='Payment' then 500 else 0 end)::numeric then
     raise exception 'INCORRECT_OPERATION_RESERVATION';
   end if;
   perform public.execute_payment(payment);
   expected:=expected+case kind when 'Refund' then 500 when 'Payment' then -500 else 0 end;
   if (select balance from public.bank_accounts where id=account) is distinct from expected then
     raise exception 'INCORRECT_OPERATION_BANK_EFFECT: %',kind;
   end if;
   if kind='Bank Action' and exists(select 1 from public.payment_bank_balance_effects where payment_id=payment) then
     raise exception 'BANK_ACTION_CREATED_BALANCE_EFFECT';
   end if;
 end loop;
end $$;
