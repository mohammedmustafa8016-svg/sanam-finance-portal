-- Dedicated, audited correction; never re-executes a bank transfer.
create or replace function public.cfo_correct_executed_payment_amount(p_payment_id uuid,p_expected_amount numeric,p_new_amount numeric,p_reason text)
returns void language plpgsql security definer set search_path='' as $$
declare p public.payments%rowtype;b public.bank_accounts%rowtype;e public.payment_bank_balance_effects%rowtype;bank_id uuid;delta numeric;
begin
 if auth.uid() is null or private.current_role() is distinct from 'CFO' then raise exception 'CFO_REQUIRED';end if;
 if p_new_amount is null or p_new_amount::text in ('NaN','Infinity','-Infinity') or p_new_amount<=0 or p_new_amount>=10000000000000000 or p_new_amount<>round(p_new_amount,2) then raise exception 'PAYMENT_CORRECTION_INVALID_AMOUNT';end if;
 if length(trim(coalesce(p_reason,''))) not between 10 and 2000 then raise exception 'PAYMENT_CORRECTION_REASON_REQUIRED';end if;
 select bank_account_id into bank_id from public.payments where id=p_payment_id;
 select * into b from public.bank_accounts where id=bank_id for update;
 if not found then raise exception 'PAYMENT_CORRECTION_BANK_REQUIRED';end if;
 select * into p from public.payments where id=p_payment_id for update;
 if not found or p.bank_account_id is distinct from b.id or p.amount is distinct from p_expected_amount then raise exception 'PAYMENT_CORRECTION_STALE_REFRESH';end if;
 if p.executed_at is null or p.status<>'منفذ' or p.posted_at is not null or p.accounting_registered_at is not null then raise exception 'PAYMENT_CORRECTION_REQUIRES_UNREGISTERED_EXECUTED';end if;
 if exists(select 1 from public.imprest_funding_requests where payment_id=p.id) then raise exception 'PAYMENT_CORRECTION_LINKED_IMPREST_REQUIRES_RECONCILIATION';end if;
 if b.account_type<>'Operational' then raise exception 'PAYMENT_CORRECTION_RESERVE_REQUIRES_RECONCILIATION';end if;
 select * into e from public.payment_bank_balance_effects where payment_id=p.id for update;
 if not found or e.bank_account_id<>b.id then raise exception 'PAYMENT_CORRECTION_BALANCE_EFFECT_REQUIRED';end if;
 delta:=p_new_amount-p.amount;
 if delta=0 then return;end if;
 perform set_config('app.auto_payment_balance','1',true);
 update public.bank_accounts set balance=balance-delta,updated_at=now() where id=b.id;
 perform set_config('app.auto_payment_balance','0',true);
 update public.payments set amount=p_new_amount,updated_at=now() where id=p.id;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'EXECUTED_PAYMENT_AMOUNT_CORRECTED','payment',p.id::text,jsonb_build_object('old_amount',p.amount,'new_amount',p_new_amount,'difference',delta,'bank_account_id',b.id,'bank_balance_before',b.balance,'bank_balance_after',b.balance-delta,'reason',trim(p_reason),'original_execution_effect',e.amount));
end $$;
revoke all on function public.cfo_correct_executed_payment_amount(uuid,numeric,numeric,text) from public,anon;
grant execute on function public.cfo_correct_executed_payment_amount(uuid,numeric,numeric,text) to authenticated;
