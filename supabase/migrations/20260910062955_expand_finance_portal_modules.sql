create table if not exists public.monthly_close_tasks (
  id uuid primary key default gen_random_uuid(),
  track text not null default 'عام', code text, name text not null,
  owner_id uuid references public.profiles(id), progress integer not null default 0 check (progress between 0 and 100),
  status text not null default 'لم يبدأ', created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.imprest_funds (
  id uuid primary key default gen_random_uuid(), type text not null, company text not null,
  name text not null, custodian_id uuid references public.profiles(id), balance numeric not null default 0,
  unsettled numeric not null default 0, aging integer not null default 0, status text not null default 'سليمة',
  created_by uuid references public.profiles(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.team_performance (
  id uuid primary key default gen_random_uuid(), user_id uuid unique references public.profiles(id) on delete cascade,
  timeliness integer not null default 0 check (timeliness between 0 and 100),
  completion integer not null default 0 check (completion between 0 and 100),
  quality integer not null default 0 check (quality between 0 and 100),
  close_score integer not null default 0 check (close_score between 0 and 100),
  exceptions_score integer not null default 0 check (exceptions_score between 0 and 100),
  updated_at timestamptz not null default now()
);
create table if not exists public.ownership_matrix (
  id uuid primary key default gen_random_uuid(), process text not null, activity text not null,
  frequency text, owner_name text not null, reviewer_name text, approver_name text, output text, control_note text,
  sort_order integer not null default 0, updated_at timestamptz not null default now()
);
alter table public.monthly_close_tasks enable row level security;
alter table public.imprest_funds enable row level security;
alter table public.team_performance enable row level security;
alter table public.ownership_matrix enable row level security;
create policy "close_select" on public.monthly_close_tasks for select to authenticated using (true);
create policy "close_manage" on public.monthly_close_tasks for all to authenticated using ((select role from public.profiles where id=auth.uid()) in ('CFO','Supervisor')) with check ((select role from public.profiles where id=auth.uid()) in ('CFO','Supervisor'));
create policy "imprest_select" on public.imprest_funds for select to authenticated using (true);
create policy "imprest_manage" on public.imprest_funds for all to authenticated using ((select role from public.profiles where id=auth.uid()) in ('CFO','Supervisor','BankAccountant','APAccountant')) with check ((select role from public.profiles where id=auth.uid()) in ('CFO','Supervisor','BankAccountant','APAccountant'));
create policy "performance_select" on public.team_performance for select to authenticated using (true);
create policy "performance_manage" on public.team_performance for all to authenticated using ((select role from public.profiles where id=auth.uid())='CFO') with check ((select role from public.profiles where id=auth.uid())='CFO');
create policy "ownership_select" on public.ownership_matrix for select to authenticated using (true);
create policy "ownership_manage" on public.ownership_matrix for all to authenticated using ((select role from public.profiles where id=auth.uid())='CFO') with check ((select role from public.profiles where id=auth.uid())='CFO');
