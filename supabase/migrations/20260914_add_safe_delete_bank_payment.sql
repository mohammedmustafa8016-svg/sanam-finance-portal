-- Controlled delete actions for CFO, Supervisor, and Bank Accountant.
-- Payment deletion is limited to unexecuted/unposted requests.
-- Bank accounts may be deleted only when no payment history references them.

create or replace function public.delete_requested_payment(p_payment_id uuid)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_role text;
  v_payment public.payments%rowtype;
begin
  v_role := private.current_role();
  if v_role is null or v_role not in ('CFO','Supervisor','BankAccountant') then
    raise exception 'Not authorized to delete requested payments';
  end if;

  select * into v_payment
  from public.payments
  where id = p_payment_id
  for update;

  if not found then
    raise exception 'Payment not found';
  end if;

  if v_payment.executed_at is not null
     or v_payment.posted_at is not null
     or v_payment.status = 'مرحّل' then
    raise exception 'Executed or posted payments cannot be deleted';
  end if;

  insert into public.audit_log(actor_id, action, entity_type, entity_id, details)
  values (
    auth.uid(),
    'DELETE_REQUESTED_PAYMENT',
    'payment',
    v_payment.id::text,
    jsonb_build_object(
      'company', v_payment.company,
      'beneficiary', v_payment.beneficiary,
      'amount', v_payment.amount,
      'status', v_payment.status,
      'bank_account_id', v_payment.bank_account_id
    )
  );

  delete from public.payments where id = p_payment_id;
end;
$$;

revoke all on function public.delete_requested_payment(uuid) from public;
grant execute on function public.delete_requested_payment(uuid) to authenticated;

create or replace function public.delete_bank_account(p_bank_account_id uuid)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_role text;
  v_bank public.bank_accounts%rowtype;
  v_payment_count integer;
begin
  v_role := private.current_role();
  if v_role is null or v_role not in ('CFO','Supervisor','BankAccountant') then
    raise exception 'Not authorized to delete bank accounts';
  end if;

  select * into v_bank
  from public.bank_accounts
  where id = p_bank_account_id
  for update;

  if not found then
    raise exception 'Bank account not found';
  end if;

  select count(*) into v_payment_count
  from public.payments
  where bank_account_id = p_bank_account_id;

  if v_payment_count > 0 then
    raise exception 'Bank account cannot be deleted while payment records reference it';
  end if;

  insert into public.audit_log(actor_id, action, entity_type, entity_id, details)
  values (
    auth.uid(),
    'DELETE_BANK_ACCOUNT',
    'bank_account',
    v_bank.id::text,
    jsonb_build_object(
      'company', v_bank.company,
      'bank_name', v_bank.bank_name,
      'account_name', v_bank.account_name,
      'balance', v_bank.balance
    )
  );

  delete from public.bank_accounts where id = p_bank_account_id;
end;
$$;

revoke all on function public.delete_bank_account(uuid) from public;
grant execute on function public.delete_bank_account(uuid) to authenticated;
