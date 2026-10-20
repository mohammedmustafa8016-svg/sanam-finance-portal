
begin;

alter table public.imprest_funds
  add column if not exists currency_code text not null default 'SAR',
  add column if not exists duplicate_override boolean not null default false,
  add column if not exists duplicate_override_reason text,
  add column if not exists duplicate_override_by uuid references public.profiles(id) on update restrict on delete set null,
  add column if not exists duplicate_override_at timestamptz;

create table public.imprest_funding_requests (
  id uuid primary key default gen_random_uuid(),
  imprest_fund_id uuid not null references public.imprest_funds(id) on update restrict on delete restrict,
  funding_type text not null check (funding_type in ('TOP_UP','TEMPORARY_FUNDING')),
  amount numeric(18,2) not null check (amount > 0),
  currency_code text not null default 'SAR',
  purpose text not null,
  project_cost_center text,
  expected_settlement_date date,
  due_date date not null,
  bank_account_id uuid not null references public.bank_accounts(id) on update restrict on delete restrict,
  priority text not null default 'عادي',
  documents_status text not null default 'مكتملة',
  payment_id uuid unique references public.payments(id) on update restrict on delete set null,
  status text not null default 'PAYMENT_CREATED'
    check (status in ('PAYMENT_CREATED','FUNDED','CANCELLED','REVERSED')),
  requested_by uuid not null references public.profiles(id) on update restrict on delete restrict,
  requested_at timestamptz not null default now(),
  funded_by uuid references public.profiles(id) on update restrict on delete set null,
  funded_at timestamptz,
  reversed_by uuid references public.profiles(id) on update restrict on delete set null,
  reversed_at timestamptz,
  reversal_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.imprest_refunds (
  id uuid primary key default gen_random_uuid(),
  imprest_fund_id uuid not null references public.imprest_funds(id) on update restrict on delete restrict,
  amount numeric(18,2) not null check (amount > 0),
  refund_date date not null,
  bank_account_id uuid references public.bank_accounts(id) on update restrict on delete set null,
  reference text,
  note text,
  status text not null default 'POSTED' check (status in ('POSTED','REVERSED')),
  recorded_by uuid not null references public.profiles(id) on update restrict on delete restrict,
  recorded_at timestamptz not null default now(),
  reversed_by uuid references public.profiles(id) on update restrict on delete set null,
  reversed_at timestamptz,
  reversal_reason text
);

create table public.imprest_ledger_entries (
  id uuid primary key default gen_random_uuid(),
  imprest_fund_id uuid not null references public.imprest_funds(id) on update restrict on delete restrict,
  entry_type text not null check (
    entry_type in (
      'OPENING_BALANCE',
      'TOP_UP',
      'TEMPORARY_FUNDING',
      'SETTLEMENT',
      'REFUND',
      'MANUAL_ADJUSTMENT',
      'REVERSAL'
    )
  ),
  direction text not null check (direction in ('INCREASE','DECREASE')),
  amount numeric(18,2) not null check (amount > 0),
  currency_code text not null default 'SAR',
  effective_at timestamptz not null default now(),
  funding_request_id uuid references public.imprest_funding_requests(id) on update restrict on delete restrict,
  payment_id uuid references public.payments(id) on update restrict on delete set null,
  settlement_id uuid references public.imprest_settlements(id) on update restrict on delete set null,
  refund_id uuid references public.imprest_refunds(id) on update restrict on delete set null,
  reversal_of_entry_id uuid references public.imprest_ledger_entries(id) on update restrict on delete restrict,
  source_key text not null unique,
  description text,
  created_by uuid references public.profiles(id) on update restrict on delete set null,
  created_at timestamptz not null default now()
);

create index idx_imprest_funding_requests_fund_status
  on public.imprest_funding_requests(imprest_fund_id,status,created_at desc);
create index idx_imprest_funding_requests_payment
  on public.imprest_funding_requests(payment_id);
create index idx_imprest_ledger_fund_time
  on public.imprest_ledger_entries(imprest_fund_id,effective_at desc,id);
create index idx_imprest_ledger_funding_request
  on public.imprest_ledger_entries(funding_request_id);
create index idx_imprest_ledger_settlement
  on public.imprest_ledger_entries(settlement_id);
create index idx_imprest_refunds_fund_date
  on public.imprest_refunds(imprest_fund_id,refund_date desc);

alter table public.imprest_funding_requests enable row level security;
alter table public.imprest_refunds enable row level security;
alter table public.imprest_ledger_entries enable row level security;

create policy imprest_funding_requests_deny_direct
on public.imprest_funding_requests
as restrictive for all to public
using (false) with check (false);

create policy imprest_refunds_deny_direct
on public.imprest_refunds
as restrictive for all to public
using (false) with check (false);

create policy imprest_ledger_entries_deny_direct
on public.imprest_ledger_entries
as restrictive for all to public
using (false) with check (false);

revoke all on table
  public.imprest_funding_requests,
  public.imprest_refunds,
  public.imprest_ledger_entries
from public, anon, authenticated;

grant select,insert,update,delete on table
  public.imprest_funding_requests,
  public.imprest_refunds,
  public.imprest_ledger_entries
to service_role;

commit;
