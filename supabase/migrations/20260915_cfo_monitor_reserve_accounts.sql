-- CFO Monitor / reserve account classification (additive, non-destructive)

alter table public.bank_accounts
  add column if not exists account_type text not null default 'Operational';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'bank_accounts_account_type_check'
      and conrelid = 'public.bank_accounts'::regclass
  ) then
    alter table public.bank_accounts
      add constraint bank_accounts_account_type_check
      check (account_type in ('Operational','Working Capital Reserve','VAT Reserve','Restricted / Other'));
  end if;
end $$;

create table if not exists public.bank_reserve_movements (
  id uuid primary key default gen_random_uuid(),
  bank_account_id uuid not null references public.bank_accounts(id) on delete restrict,
  movement_type text not null check (movement_type in ('Support Draw','Restoration')),
  amount numeric(18,2) not null check (amount > 0),
  movement_date date not null default current_date,
  note text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

alter table public.bank_reserve_movements enable row level security;

drop policy if exists reserve_movements_read on public.bank_reserve_movements;
create policy reserve_movements_read on public.bank_reserve_movements
for select to authenticated using (true);

drop policy if exists reserve_movements_manage on public.bank_reserve_movements;
create policy reserve_movements_manage on public.bank_reserve_movements
for all to authenticated
using (private."current_role"() = any(array['CFO'::text,'Supervisor'::text,'BankAccountant'::text]))
with check (private."current_role"() = any(array['CFO'::text,'Supervisor'::text,'BankAccountant'::text]));

create or replace function public.audit_bank_account_type_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.account_type is distinct from new.account_type then
    insert into public.audit_log(actor_id, action, entity_type, entity_id, details)
    values (
      auth.uid(),
      'BANK_ACCOUNT_TYPE_CHANGED',
      'bank_account',
      new.id::text,
      jsonb_build_object('from',old.account_type,'to',new.account_type,'bank_name',new.bank_name,'account_name',new.account_name)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_bank_account_type_audit on public.bank_accounts;
create trigger trg_bank_account_type_audit
after update of account_type on public.bank_accounts
for each row execute function public.audit_bank_account_type_change();

-- Preserve the existing bank_liquidity contract and append account_type at the end.
create or replace view public.bank_liquidity as
select
  b.id,
  b.company,
  b.bank_name,
  b.account_name,
  b.account_no,
  b.balance,
  coalesce(sum(case when p.status <> all(array['مرفوض'::text,'موقوف'::text,'منفذ'::text,'مرحّل'::text]) then p.amount else 0::numeric end),0::numeric)::numeric(18,2) as reserved_balance,
  (b.balance - coalesce(sum(case when p.status <> all(array['مرفوض'::text,'موقوف'::text,'منفذ'::text,'مرحّل'::text]) then p.amount else 0::numeric end),0::numeric))::numeric(18,2) as available_balance,
  b.updated_at,
  b.account_type
from public.bank_accounts b
left join public.payments p on p.bank_account_id=b.id
group by b.id;

create or replace function public.get_reserve_account_monitor()
returns table(
  bank_account_id uuid,
  company text,
  bank_name text,
  account_name text,
  account_no_last4 text,
  account_type text,
  balance numeric,
  reserved_balance numeric,
  available_balance numeric,
  executed_outflows numeric,
  manual_support_draws numeric,
  restorations numeric,
  outstanding_restoration numeric,
  last_movement_at timestamptz,
  last_movement_type text
)
language sql
stable
security definer
set search_path = public
as $$
with p as (
  select bank_account_id,
         coalesce(sum(amount) filter (where executed_at is not null),0)::numeric(18,2) executed_outflows
  from public.payments
  group by bank_account_id
), m as (
  select bank_account_id,
         coalesce(sum(amount) filter (where movement_type='Support Draw'),0)::numeric(18,2) manual_support_draws,
         coalesce(sum(amount) filter (where movement_type='Restoration'),0)::numeric(18,2) restorations,
         max(created_at) last_movement_at
  from public.bank_reserve_movements
  group by bank_account_id
), lm as (
  select distinct on (bank_account_id) bank_account_id, movement_type
  from public.bank_reserve_movements
  order by bank_account_id, created_at desc
)
select bl.id,
       bl.company,
       bl.bank_name,
       bl.account_name,
       case when coalesce(bl.account_no,'')='' then null else right(regexp_replace(bl.account_no,'\\s+','','g'),4) end,
       bl.account_type,
       bl.balance,
       bl.reserved_balance,
       bl.available_balance,
       coalesce(p.executed_outflows,0)::numeric,
       coalesce(m.manual_support_draws,0)::numeric,
       coalesce(m.restorations,0)::numeric,
       greatest(coalesce(p.executed_outflows,0)+coalesce(m.manual_support_draws,0)-coalesce(m.restorations,0),0)::numeric,
       m.last_movement_at,
       lm.movement_type
from public.bank_liquidity bl
left join p on p.bank_account_id=bl.id
left join m on m.bank_account_id=bl.id
left join lm on lm.bank_account_id=bl.id
where bl.account_type <> 'Operational'
order by case bl.account_type when 'Working Capital Reserve' then 1 when 'VAT Reserve' then 2 else 3 end, bl.company, bl.bank_name;
$$;

grant execute on function public.get_reserve_account_monitor() to authenticated;

create or replace function public.record_reserve_movement(
  p_bank_account_id uuid,
  p_movement_type text,
  p_amount numeric,
  p_movement_date date default current_date,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_id uuid;
  v_type text;
begin
  if private."current_role"() <> all(array['CFO'::text,'Supervisor'::text,'BankAccountant'::text]) then
    raise exception 'Not authorized to record reserve movements';
  end if;
  if p_movement_type not in ('Support Draw','Restoration') then
    raise exception 'Invalid reserve movement type';
  end if;
  if coalesce(p_amount,0) <= 0 then
    raise exception 'Amount must be greater than zero';
  end if;
  select account_type into v_type from public.bank_accounts where id=p_bank_account_id;
  if v_type is null then raise exception 'Bank account not found'; end if;
  if v_type='Operational' then raise exception 'Reserve movement can only be recorded for a protected account type'; end if;

  insert into public.bank_reserve_movements(bank_account_id,movement_type,amount,movement_date,note,created_by)
  values(p_bank_account_id,p_movement_type,p_amount,coalesce(p_movement_date,current_date),nullif(trim(coalesce(p_note,'')),''),auth.uid())
  returning id into v_id;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'RESERVE_MOVEMENT_RECORDED','bank_reserve_movement',v_id::text,
         jsonb_build_object('bank_account_id',p_bank_account_id,'movement_type',p_movement_type,'amount',p_amount,'movement_date',coalesce(p_movement_date,current_date)));
  return v_id;
end;
$$;

grant execute on function public.record_reserve_movement(uuid,text,numeric,date,text) to authenticated;
