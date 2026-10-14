begin;

do $preflight$
declare
  v_existing integer;
  v_job integer;
begin
  select count(*) into v_existing
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public'
    and c.relname in (
      'reserve_shadow_observation_runs',
      'reserve_shadow_observations',
      'reserve_shadow_observation_history_v2',
      'reserve_shadow_latest_observation_v2'
    );

  if v_existing <> 0 then
    raise exception 'Reserve shadow observation preflight failed: % target relation(s) already exist', v_existing;
  end if;

  if exists(
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where (n.nspname='private' and p.proname='reserve_shadow_observation_tick_v2')
       or (n.nspname='public' and p.proname in (
         'get_reserve_shadow_monitor_status_v2',
         'get_reserve_shadow_observation_history_v2'
       ))
  ) then
    raise exception 'Reserve shadow observation preflight failed: target function already exists';
  end if;

  select count(*) into v_job
  from cron.job
  where jobname='sanam_reserve_shadow_observation_v2';

  if v_job <> 0 then
    raise exception 'Reserve shadow observation preflight failed: cron job already exists';
  end if;
end
$preflight$;

create table public.reserve_shadow_observation_runs (
  id uuid primary key default gen_random_uuid(),
  observed_at timestamptz not null default now(),
  status text not null default 'COMPLETE' check (status in ('COMPLETE')),
  account_count integer not null default 0 check (account_count >= 0),
  variance_count integer not null default 0 check (variance_count >= 0),
  control_exception_count integer not null default 0 check (control_exception_count >= 0),
  note text,
  created_at timestamptz not null default now()
);

create table public.reserve_shadow_observations (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.reserve_shadow_observation_runs(id)
    on update restrict on delete cascade,
  reconciliation_account_id uuid not null references public.reserve_reconciliation_accounts(id)
    on update restrict on delete restrict,
  bank_account_id uuid not null references public.bank_accounts(id)
    on update restrict on delete restrict,
  observed_at timestamptz not null,
  tolerance_amount numeric(18,2) not null default 0.01 check (tolerance_amount >= 0),
  v1_target numeric(18,2),
  v2_target numeric(18,2),
  target_delta numeric(18,2),
  v1_bank_balance numeric(18,2),
  v2_bank_balance numeric(18,2),
  bank_balance_delta numeric(18,2),
  v1_reserved_payments numeric(18,2),
  v2_reserved_payments numeric(18,2),
  reserved_payments_delta numeric(18,2),
  v1_outstanding_recovery numeric(18,2),
  v2_outstanding_recovery numeric(18,2),
  outstanding_recovery_delta numeric(18,2),
  v1_target_gap numeric(18,2),
  v2_target_gap numeric(18,2),
  target_gap_delta numeric(18,2),
  historical_variance numeric(18,2),
  v2_unreconciled_difference numeric(18,2),
  v2_open_exception_count integer not null default 0 check (v2_open_exception_count >= 0),
  v2_control_exception_count integer not null default 0 check (v2_control_exception_count >= 0),
  v2_integrity_issue_count integer not null default 0 check (v2_integrity_issue_count >= 0),
  comparison_status text,
  observation_status text not null check (observation_status in ('OK','VARIANCE','CONTROL_EXCEPTION')),
  exception_code text,
  exception_detail text,
  created_at timestamptz not null default now(),
  constraint reserve_shadow_observations_run_account_unique unique (run_id, reconciliation_account_id),
  constraint reserve_shadow_observations_exception_consistency check (
    (observation_status='OK' and exception_code is null)
    or
    (observation_status<>'OK' and nullif(trim(coalesce(exception_code,'')),'') is not null)
  )
);

create index idx_reserve_shadow_runs_observed_at
  on public.reserve_shadow_observation_runs(observed_at desc);
create index idx_reserve_shadow_observations_account_time
  on public.reserve_shadow_observations(reconciliation_account_id, observed_at desc);
create index idx_reserve_shadow_observations_bank_time
  on public.reserve_shadow_observations(bank_account_id, observed_at desc);
create index idx_reserve_shadow_observations_status_time
  on public.reserve_shadow_observations(observation_status, observed_at desc);

alter table public.reserve_shadow_observation_runs enable row level security;
alter table public.reserve_shadow_observations enable row level security;

create policy reserve_shadow_observation_runs_deny_direct
on public.reserve_shadow_observation_runs
as restrictive for all to public
using (false) with check (false);

create policy reserve_shadow_observations_deny_direct
on public.reserve_shadow_observations
as restrictive for all to public
using (false) with check (false);

revoke all on table
  public.reserve_shadow_observation_runs,
  public.reserve_shadow_observations
from public, anon, authenticated, service_role;

grant select, insert, update, delete on table
  public.reserve_shadow_observation_runs,
  public.reserve_shadow_observations
to service_role;

create view public.reserve_shadow_observation_history_v2
with (security_invoker=true)
as
select
  o.id,
  o.run_id,
  o.reconciliation_account_id,
  o.bank_account_id,
  b.company,
  b.bank_name,
  b.account_name,
  b.account_type,
  o.observed_at,
  o.tolerance_amount,
  o.v1_target,
  o.v2_target,
  o.target_delta,
  o.v1_bank_balance,
  o.v2_bank_balance,
  o.bank_balance_delta,
  o.v1_reserved_payments,
  o.v2_reserved_payments,
  o.reserved_payments_delta,
  o.v1_outstanding_recovery,
  o.v2_outstanding_recovery,
  o.outstanding_recovery_delta,
  o.v1_target_gap,
  o.v2_target_gap,
  o.target_gap_delta,
  o.historical_variance,
  o.v2_unreconciled_difference,
  o.v2_open_exception_count,
  o.v2_control_exception_count,
  o.v2_integrity_issue_count,
  o.comparison_status,
  o.observation_status,
  o.exception_code,
  o.exception_detail,
  r.account_count as run_account_count,
  r.variance_count as run_variance_count,
  r.control_exception_count as run_control_exception_count,
  r.status as run_status
from public.reserve_shadow_observations o
join public.reserve_shadow_observation_runs r on r.id=o.run_id
join public.bank_accounts b on b.id=o.bank_account_id;

create view public.reserve_shadow_latest_observation_v2
with (security_invoker=true)
as
select distinct on (h.reconciliation_account_id)
  h.*
from public.reserve_shadow_observation_history_v2 h
order by h.reconciliation_account_id, h.observed_at desc, h.id desc;

revoke all on table
  public.reserve_shadow_observation_history_v2,
  public.reserve_shadow_latest_observation_v2
from public, anon, authenticated, service_role;

grant select on table
  public.reserve_shadow_observation_history_v2,
  public.reserve_shadow_latest_observation_v2
to service_role;

create function private.reserve_shadow_observation_tick_v2()
returns uuid
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $function$
declare
  v_run_id uuid;
  v_observed_at timestamptz := now();
  v_account_count integer := 0;
  v_variance_count integer := 0;
  v_control_count integer := 0;
begin
  if not pg_try_advisory_xact_lock(hashtext('sanam_reserve_shadow_observation_v2')) then
    return null;
  end if;

  insert into public.reserve_shadow_observation_runs(observed_at,status,note)
  values(
    v_observed_at,
    'COMPLETE',
    'Automatic Shadow Mode observation. V1 remains operational; this run records comparison state only and performs no V1/V2 operational mutation.'
  )
  returning id into v_run_id;

  insert into public.reserve_shadow_observations(
    run_id,reconciliation_account_id,bank_account_id,observed_at,tolerance_amount,
    v1_target,v2_target,target_delta,
    v1_bank_balance,v2_bank_balance,bank_balance_delta,
    v1_reserved_payments,v2_reserved_payments,reserved_payments_delta,
    v1_outstanding_recovery,v2_outstanding_recovery,outstanding_recovery_delta,
    v1_target_gap,v2_target_gap,target_gap_delta,
    historical_variance,v2_unreconciled_difference,
    v2_open_exception_count,v2_control_exception_count,v2_integrity_issue_count,
    comparison_status,observation_status,exception_code,exception_detail
  )
  select
    v_run_id,a.id,c.bank_account_id,v_observed_at,a.tolerance_amount,
    c.v1_reference_balance,c.v2_effective_target,c.target_delta_v2_minus_v1,
    c.v1_current_bank_balance,c.v2_current_bank_balance,c.bank_balance_delta_v2_minus_v1,
    c.v1_reserved_balance,c.v2_pending_reserved_payments,c.reserved_payments_delta_v2_minus_v1,
    c.v1_outstanding_restoration,c.v2_outstanding_recovery,c.outstanding_recovery_delta_v2_minus_v1,
    c.v1_target_gap,c.v2_target_gap,c.target_gap_delta_v2_minus_v1,
    c.opening_historical_variance,c.v2_unreconciled_difference,
    coalesce(c.v2_open_exception_count,0),coalesce(c.v2_control_exception_count,0),coalesce(c.v2_integrity_issue_count,0),
    c.shadow_comparison_status,
    case
      when abs(coalesce(c.v2_unreconciled_difference,0)) > a.tolerance_amount
        or coalesce(c.v2_open_exception_count,0) > 0
        or coalesce(c.v2_control_exception_count,0) > 0
        or coalesce(c.v2_integrity_issue_count,0) > 0
        then 'CONTROL_EXCEPTION'
      when abs(coalesce(c.target_delta_v2_minus_v1,0)) > a.tolerance_amount
        or abs(coalesce(c.bank_balance_delta_v2_minus_v1,0)) > a.tolerance_amount
        or abs(coalesce(c.reserved_payments_delta_v2_minus_v1,0)) > a.tolerance_amount
        or abs(coalesce(c.outstanding_recovery_delta_v2_minus_v1,0)) > a.tolerance_amount
        or abs(coalesce(c.target_gap_delta_v2_minus_v1,0)) > a.tolerance_amount
        then 'VARIANCE'
      else 'OK'
    end,
    case
      when abs(coalesce(c.v2_unreconciled_difference,0)) > a.tolerance_amount
        or coalesce(c.v2_open_exception_count,0) > 0
        or coalesce(c.v2_control_exception_count,0) > 0
        or coalesce(c.v2_integrity_issue_count,0) > 0
        then 'V2_CONTROL_EXCEPTION'
      when abs(coalesce(c.target_delta_v2_minus_v1,0)) > a.tolerance_amount
        or abs(coalesce(c.bank_balance_delta_v2_minus_v1,0)) > a.tolerance_amount
        or abs(coalesce(c.reserved_payments_delta_v2_minus_v1,0)) > a.tolerance_amount
        or abs(coalesce(c.outstanding_recovery_delta_v2_minus_v1,0)) > a.tolerance_amount
        or abs(coalesce(c.target_gap_delta_v2_minus_v1,0)) > a.tolerance_amount
        then 'V1_V2_VARIANCE'
      else null
    end,
    case
      when abs(coalesce(c.v2_unreconciled_difference,0)) > a.tolerance_amount
        or coalesce(c.v2_open_exception_count,0) > 0
        or coalesce(c.v2_control_exception_count,0) > 0
        or coalesce(c.v2_integrity_issue_count,0) > 0
        then concat(
          'Control exception observed. unreconciled=',coalesce(c.v2_unreconciled_difference,0),
          '; open_exceptions=',coalesce(c.v2_open_exception_count,0),
          '; control_exceptions=',coalesce(c.v2_control_exception_count,0),
          '; integrity_issues=',coalesce(c.v2_integrity_issue_count,0)
        )
      when abs(coalesce(c.target_delta_v2_minus_v1,0)) > a.tolerance_amount
        or abs(coalesce(c.bank_balance_delta_v2_minus_v1,0)) > a.tolerance_amount
        or abs(coalesce(c.reserved_payments_delta_v2_minus_v1,0)) > a.tolerance_amount
        or abs(coalesce(c.outstanding_recovery_delta_v2_minus_v1,0)) > a.tolerance_amount
        or abs(coalesce(c.target_gap_delta_v2_minus_v1,0)) > a.tolerance_amount
        then concat(
          'V1/V2 variance observed. target_delta=',coalesce(c.target_delta_v2_minus_v1,0),
          '; balance_delta=',coalesce(c.bank_balance_delta_v2_minus_v1,0),
          '; reserved_delta=',coalesce(c.reserved_payments_delta_v2_minus_v1,0),
          '; recovery_delta=',coalesce(c.outstanding_recovery_delta_v2_minus_v1,0),
          '; gap_delta=',coalesce(c.target_gap_delta_v2_minus_v1,0),
          '; tolerance=',a.tolerance_amount
        )
      else null
    end
  from public.reserve_reconciliation_accounts a
  join public.reserve_v1_v2_shadow_comparison c on c.bank_account_id=a.bank_account_id
  where a.status='Active'
    and a.reconciliation_enabled=true;

  select
    count(*),
    count(*) filter (where observation_status='VARIANCE'),
    count(*) filter (where observation_status='CONTROL_EXCEPTION')
  into v_account_count,v_variance_count,v_control_count
  from public.reserve_shadow_observations
  where run_id=v_run_id;

  update public.reserve_shadow_observation_runs
  set account_count=v_account_count,
      variance_count=v_variance_count,
      control_exception_count=v_control_count
  where id=v_run_id;

  return v_run_id;
end;
$function$;

revoke all on function private.reserve_shadow_observation_tick_v2()
from public, anon, authenticated;

create function public.get_reserve_shadow_monitor_status_v2()
returns setof public.reserve_shadow_latest_observation_v2
language plpgsql
stable
security definer
set search_path='public','private','pg_temp'
as $function$
begin
  if coalesce(private.current_role() not in ('CFO','Supervisor'), true) then
    raise exception 'Not authorized to view Reserve V2 shadow monitoring';
  end if;

  return query
  select l.*
  from public.reserve_shadow_latest_observation_v2 l
  order by l.account_type,l.company,l.bank_name,l.account_name;
end;
$function$;

create function public.get_reserve_shadow_observation_history_v2(
  p_bank_account_id uuid default null,
  p_limit integer default 100
)
returns setof public.reserve_shadow_observation_history_v2
language plpgsql
stable
security definer
set search_path='public','private','pg_temp'
as $function$
begin
  if coalesce(private.current_role() not in ('CFO','Supervisor'), true) then
    raise exception 'Not authorized to view Reserve V2 shadow monitoring history';
  end if;

  if p_limit is null or p_limit < 1 or p_limit > 500 then
    raise exception 'p_limit must be between 1 and 500';
  end if;

  return query
  select h.*
  from public.reserve_shadow_observation_history_v2 h
  where p_bank_account_id is null or h.bank_account_id=p_bank_account_id
  order by h.observed_at desc,h.account_type,h.company
  limit p_limit;
end;
$function$;

revoke all on function public.get_reserve_shadow_monitor_status_v2()
from public, anon, authenticated;
revoke all on function public.get_reserve_shadow_observation_history_v2(uuid,integer)
from public, anon, authenticated;

grant execute on function public.get_reserve_shadow_monitor_status_v2()
to authenticated;
grant execute on function public.get_reserve_shadow_observation_history_v2(uuid,integer)
to authenticated;

comment on table public.reserve_shadow_observation_runs is
'Additive Shadow Mode monitoring runs only. Does not replace or mutate Reserve V1 operational logic.';
comment on table public.reserve_shadow_observations is
'Point-in-time V1 versus V2 observation records. Historical variance alone is not classified as an active exception.';
comment on function private.reserve_shadow_observation_tick_v2() is
'Automatic read-observe-record tick. Reads V1/V2 comparison and writes only to additive shadow observation tables.';
comment on function public.get_reserve_shadow_monitor_status_v2() is
'Read-only CFO/Supervisor RPC exposing latest automatic Reserve V2 shadow observations.';
comment on function public.get_reserve_shadow_observation_history_v2(uuid,integer) is
'Read-only CFO/Supervisor RPC exposing Reserve V2 shadow observation history.';

select private.reserve_shadow_observation_tick_v2();

select cron.schedule(
  'sanam_reserve_shadow_observation_v2',
  '*/15 * * * *',
  'select private.reserve_shadow_observation_tick_v2();'
);

commit;
