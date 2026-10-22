create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text unique not null,
  full_name text not null,
  role text not null check (role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')),
  active boolean not null default true,
  notifications_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.allowed_users (
  email text primary key,
  full_name text not null,
  role text not null check (role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

insert into public.allowed_users(email,full_name,role) values
('cfo@local.invalid','Local CFO','CFO'),
('supervisor@local.invalid','Local Supervisor','Supervisor'),
('bank.accountant@local.invalid','Local Bank Accountant','BankAccountant'),
('gl.accountant@local.invalid','Local GL Accountant','GLAccountant'),
('ar.accountant@local.invalid','Local AR Accountant','ARAccountant'),
('ap.accountant@local.invalid','Local AP Accountant','APAccountant')
on conflict (email) do update set full_name=excluded.full_name, role=excluded.role, active=true;

create table if not exists public.bank_accounts (
  id uuid primary key default gen_random_uuid(),
  company text not null,
  bank_name text not null,
  account_name text not null,
  account_no text,
  balance numeric(18,2) not null default 0,
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles(id)
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  due_date date not null,
  company text not null,
  beneficiary text not null,
  amount numeric(18,2) not null check (amount>=0),
  priority text not null default 'عادي',
  documents_status text not null default 'مكتملة',
  supervisor_status text not null default 'معلق',
  cfo_status text not null default 'معلق',
  status text not null default 'بانتظار مراجعة المشرف',
  bank_account_id uuid not null references public.bank_accounts(id),
  purpose text,
  requested_by uuid references public.profiles(id),
  supervisor_approved_by uuid references public.profiles(id),
  supervisor_approved_at timestamptz,
  cfo_approved_by uuid references public.profiles(id),
  cfo_approved_at timestamptz,
  executed_by uuid references public.profiles(id),
  executed_at timestamptz,
  posted_by uuid references public.profiles(id),
  posted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  frequency text,
  owner_id uuid references public.profiles(id),
  reviewer_id uuid references public.profiles(id),
  due_date date,
  priority text default 'عادي',
  status text default 'لم يبدأ',
  output text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.leave_delegations (
  id uuid primary key default gen_random_uuid(),
  absent_user_id uuid not null references public.profiles(id),
  substitute_user_id uuid not null references public.profiles(id),
  date_from date not null,
  date_to date not null check (date_to>=date_from),
  notes text,
  active boolean not null default true,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.exceptions (
  id uuid primary key default gen_random_uuid(),
  kind text not null default 'general',
  type text not null,
  severity text not null default 'متوسط',
  owner_id uuid references public.profiles(id),
  detail text,
  status text not null default 'مفتوح',
  leave_delegation_id uuid references public.leave_delegations(id) on delete set null,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid references public.profiles(id),
  action text not null,
  entity_type text not null,
  entity_id text,
  details jsonb,
  created_at timestamptz not null default now()
);

create or replace function public.current_role() returns text language sql stable security definer set search_path=public as $$
  select role from public.profiles where id=auth.uid() and active=true
$$;

create or replace function public.is_cfo() returns boolean language sql stable security definer set search_path=public as $$
  select coalesce(public.current_role()='CFO',false)
$$;

create or replace function public.is_supervisor_or_delegate() returns boolean language sql stable security definer set search_path=public as $$
  select coalesce(public.current_role()='Supervisor',false) or exists(
    select 1 from public.leave_delegations ld
    join public.profiles p on p.id=ld.absent_user_id
    where ld.substitute_user_id=auth.uid() and p.role='Supervisor' and ld.active=true and current_date between ld.date_from and ld.date_to
  )
$$;

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
declare a public.allowed_users%rowtype;
begin
  select * into a from public.allowed_users where lower(email)=lower(new.email) and active=true;
  if not found then raise exception 'User email is not authorized for Sanam Finance Portal'; end if;
  insert into public.profiles(id,email,full_name,role,active) values(new.id,lower(new.email),a.full_name,a.role,true)
  on conflict(id) do update set email=excluded.email,full_name=excluded.full_name,role=excluded.role,active=true,updated_at=now();
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

alter table public.profiles enable row level security;
alter table public.allowed_users enable row level security;
alter table public.bank_accounts enable row level security;
alter table public.payments enable row level security;
alter table public.tasks enable row level security;
alter table public.leave_delegations enable row level security;
alter table public.exceptions enable row level security;
alter table public.audit_log enable row level security;

create policy profiles_read on public.profiles for select to authenticated using (true);
create policy profiles_cfo_update on public.profiles for update to authenticated using (public.is_cfo()) with check (public.is_cfo());
create policy allowed_users_cfo_read on public.allowed_users for select to authenticated using (public.is_cfo());

create policy bank_accounts_read on public.bank_accounts for select to authenticated using (true);
create policy bank_accounts_manage on public.bank_accounts for all to authenticated using (public.current_role() in ('CFO','Supervisor','BankAccountant')) with check (public.current_role() in ('CFO','Supervisor','BankAccountant'));

create policy payments_read on public.payments for select to authenticated using (public.current_role() in ('CFO','Supervisor','BankAccountant','GLAccountant','APAccountant'));
create policy payments_insert on public.payments for insert to authenticated with check (public.current_role() in ('CFO','Supervisor','BankAccountant','APAccountant'));
create policy payments_update on public.payments for update to authenticated using (public.current_role() in ('CFO','Supervisor','BankAccountant','GLAccountant','APAccountant') or public.is_supervisor_or_delegate()) with check (public.current_role() in ('CFO','Supervisor','BankAccountant','GLAccountant','APAccountant') or public.is_supervisor_or_delegate());
create policy payments_delete_cfo on public.payments for delete to authenticated using (public.is_cfo());

create policy tasks_read on public.tasks for select to authenticated using (owner_id=auth.uid() or reviewer_id=auth.uid() or public.current_role() in ('CFO','Supervisor') or exists(select 1 from public.leave_delegations ld where ld.substitute_user_id=auth.uid() and ld.absent_user_id=tasks.owner_id and ld.active=true and current_date between ld.date_from and ld.date_to));
create policy tasks_manage on public.tasks for all to authenticated using (public.current_role() in ('CFO','Supervisor') or owner_id=auth.uid() or exists(select 1 from public.leave_delegations ld where ld.substitute_user_id=auth.uid() and ld.absent_user_id=tasks.owner_id and ld.active=true and current_date between ld.date_from and ld.date_to)) with check (public.current_role() in ('CFO','Supervisor') or owner_id=auth.uid() or exists(select 1 from public.leave_delegations ld where ld.substitute_user_id=auth.uid() and ld.absent_user_id=tasks.owner_id and ld.active=true and current_date between ld.date_from and ld.date_to));

create policy leave_read on public.leave_delegations for select to authenticated using (true);
create policy leave_cfo_manage on public.leave_delegations for all to authenticated using (public.is_cfo()) with check (public.is_cfo());
create policy exceptions_read on public.exceptions for select to authenticated using (true);
create policy exceptions_cfo_manage on public.exceptions for all to authenticated using (public.is_cfo()) with check (public.is_cfo());
create policy audit_read_cfo on public.audit_log for select to authenticated using (public.is_cfo());
create policy audit_insert on public.audit_log for insert to authenticated with check (actor_id=auth.uid());

create or replace view public.bank_liquidity as
select b.id,b.company,b.bank_name,b.account_name,b.account_no,b.balance,
       coalesce(sum(case when p.status not in ('مرفوض','موقوف','منفذ','مرحّل') then p.amount else 0 end),0)::numeric(18,2) as reserved_balance,
       (b.balance-coalesce(sum(case when p.status not in ('مرفوض','موقوف','منفذ','مرحّل') then p.amount else 0 end),0))::numeric(18,2) as available_balance,
       b.updated_at
from public.bank_accounts b left join public.payments p on p.bank_account_id=b.id
group by b.id;

grant select on public.bank_liquidity to authenticated;