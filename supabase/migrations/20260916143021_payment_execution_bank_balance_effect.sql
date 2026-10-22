-- Additive, idempotent execution-to-bank-balance effect.
-- Existing historical payments are not backfilled or recalculated.

create table if not exists public.payment_bank_balance_effects (
  payment_id uuid primary key references public.payments(id) on delete restrict,
  bank_account_id uuid not null references public.bank_accounts(id) on delete restrict,
  amount numeric(18,2) not null check (amount > 0),
  balance_before numeric(18,2) not null,
  balance_after numeric(18,2) not null,
  applied_at timestamptz not null default now(),
  applied_by uuid references public.profiles(id),
  source_status text not null default 'منفذ'
);

alter table public.payment_bank_balance_effects enable row level security;
drop policy if exists payment_bank_balance_effects_read on public.payment_bank_balance_effects;
create policy payment_bank_balance_effects_read on public.payment_bank_balance_effects
for select to authenticated
using(private.current_role() in ('CFO','Supervisor','BankAccountant'));
revoke all on public.payment_bank_balance_effects from anon;
revoke insert,update,delete,truncate,references,trigger on public.payment_bank_balance_effects from authenticated;
grant select on public.payment_bank_balance_effects to authenticated;

create or replace function private.capture_bank_activity() returns trigger
language plpgsql security definer set search_path='public','private','pg_temp'
as $$
declare v_role text:=private.current_role(); v_actor uuid:=auth.uid();
begin
 if current_setting('app.auto_payment_balance',true)='1' then
   return new;
 end if;
 if v_actor is not null and v_role='BankAccountant' and old.balance is distinct from new.balance then
   perform private.log_employee_activity(v_actor,'BANK_BALANCE_UPDATED','bank_account',new.id::text,
     'BANK_BALANCE_UPDATED:'||new.id::text||':'||txid_current()::text,null,
     jsonb_build_object('old_balance',old.balance,'new_balance',new.balance,'bank_name',new.bank_name,'account_name',new.account_name),now());
 end if;
 return new;
end $$;

create or replace function private.apply_executed_payment_bank_balance() returns trigger
language plpgsql security definer set search_path='public','private','pg_temp'
as $$
declare
  v_before numeric(18,2);
  v_after numeric(18,2);
begin
  if old.status is not distinct from new.status or new.status <> 'منفذ' then
    return new;
  end if;

  if new.bank_account_id is null then
    raise exception 'Executed payment requires a bank account';
  end if;
  if coalesce(new.amount,0) <= 0 then
    raise exception 'Executed payment amount must be greater than zero';
  end if;

  -- A payment can affect the bank balance only once even if its status is later overridden and returned to Executed.
  if exists(select 1 from public.payment_bank_balance_effects where payment_id=new.id) then
    return new;
  end if;

  select balance into v_before
  from public.bank_accounts
  where id=new.bank_account_id
  for update;
  if not found then
    raise exception 'Bank account not found for executed payment';
  end if;

  v_after:=v_before-new.amount;
  perform set_config('app.auto_payment_balance','1',true);
  update public.bank_accounts
     set balance=v_after,updated_at=now()
   where id=new.bank_account_id;

  insert into public.payment_bank_balance_effects(payment_id,bank_account_id,amount,balance_before,balance_after,applied_by,source_status)
  values(new.id,new.bank_account_id,new.amount,v_before,v_after,auth.uid(),'منفذ');

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'PAYMENT_BANK_BALANCE_APPLIED','payment',new.id::text,
    jsonb_build_object('bank_account_id',new.bank_account_id,'amount',new.amount,'balance_before',v_before,'balance_after',v_after,'status','منفذ'));

  return new;
end $$;

drop trigger if exists trg_apply_executed_payment_bank_balance on public.payments;
create trigger trg_apply_executed_payment_bank_balance
after update of status on public.payments
for each row execute function private.apply_executed_payment_bank_balance();
