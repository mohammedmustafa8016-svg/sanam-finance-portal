
begin;

do $preflight$
begin
  if to_regclass('public.reserve_v1_v2_shadow_comparison') is not null then
    raise exception 'Shadow comparison object already exists: public.reserve_v1_v2_shadow_comparison';
  end if;
end
$preflight$;

create view public.reserve_v1_v2_shadow_comparison
with (security_invoker = true)
as
with payment_uses as (
  select
    p.bank_account_id,
    p.id,
    p.amount,
    coalesce((
      select sum(r.amount)
      from public.bank_reserve_movements r
      where r.movement_type = 'Restoration'
        and r.restores_payment_id = p.id
    ),0) as restored
  from public.payments p
  join public.bank_accounts b
    on b.id = p.bank_account_id
  where p.executed_at is not null
    and b.account_type <> 'Operational'
),
manual_uses as (
  select
    m.bank_account_id,
    m.id,
    m.amount,
    m.requires_restoration,
    coalesce((
      select sum(r.amount)
      from public.bank_reserve_movements r
      where r.movement_type = 'Restoration'
        and r.restores_movement_id = m.id
    ),0) as restored
  from public.bank_reserve_movements m
  join public.bank_accounts b
    on b.id = m.bank_account_id
  where m.movement_type = 'Support Draw'
    and b.account_type <> 'Operational'
),
payment_agg as (
  select
    bank_account_id,
    coalesce(sum(amount),0)::numeric(18,2) as executed_outflows,
    coalesce(sum(greatest(amount-restored,0)),0)::numeric(18,2) as outstanding
  from payment_uses
  group by bank_account_id
),
manual_agg as (
  select
    bank_account_id,
    coalesce(sum(amount),0)::numeric(18,2) as manual_support_draws,
    coalesce(sum(greatest(amount-restored,0))
      filter (where requires_restoration = true),0)::numeric(18,2) as outstanding
  from manual_uses
  group by bank_account_id
),
restoration_agg as (
  select
    bank_account_id,
    coalesce(sum(amount),0)::numeric(18,2) as restorations
  from public.bank_reserve_movements
  where movement_type = 'Restoration'
  group by bank_account_id
),
v1 as (
  select
    bl.id as bank_account_id,
    bl.company,
    bl.bank_name,
    bl.account_name,
    bl.account_type,
    b.reference_balance::numeric(18,2) as reference_balance,
    bl.balance::numeric(18,2) as current_bank_balance,
    bl.reserved_balance::numeric(18,2) as reserved_balance,
    bl.available_balance::numeric(18,2) as available_balance,
    coalesce(p.executed_outflows,0)::numeric(18,2) as executed_outflows,
    coalesce(m.manual_support_draws,0)::numeric(18,2) as manual_support_draws,
    coalesce(r.restorations,0)::numeric(18,2) as restorations,
    (coalesce(p.outstanding,0)+coalesce(m.outstanding,0))::numeric(18,2) as outstanding_restoration,
    greatest(
      coalesce(b.reference_balance,bl.balance)-bl.balance,
      0
    )::numeric(18,2) as target_gap
  from public.bank_liquidity bl
  join public.bank_accounts b
    on b.id = bl.id
  left join payment_agg p
    on p.bank_account_id = bl.id
  left join manual_agg m
    on m.bank_account_id = bl.id
  left join restoration_agg r
    on r.bank_account_id = bl.id
  where bl.account_type <> 'Operational'
),
opening as (
  select
    o.reconciliation_account_id,
    o.as_of_date,
    o.historical_variance,
    row_number() over (
      partition by o.reconciliation_account_id
      order by o.as_of_date desc, o.approved_at desc, o.created_at desc
    ) as rn
  from public.reserve_v2_opening_reconciliations o
  where o.status = 'Approved'
),
v2 as (
  select
    s.*,
    o.as_of_date as opening_as_of_date,
    o.historical_variance
  from public.reserve_reconciliation_summary_v2 s
  left join opening o
    on o.reconciliation_account_id = s.reconciliation_account_id
   and o.rn = 1
)
select
  v1.bank_account_id,
  v1.company,
  v1.bank_name,
  v1.account_name,
  v1.account_type,

  v1.reference_balance as v1_reference_balance,
  v1.current_bank_balance as v1_current_bank_balance,
  v1.reserved_balance as v1_reserved_balance,
  v1.available_balance as v1_available_balance,
  v1.executed_outflows as v1_executed_outflows,
  v1.manual_support_draws as v1_manual_support_draws,
  v1.restorations as v1_restorations,
  v1.outstanding_restoration as v1_outstanding_restoration,
  v1.target_gap as v1_target_gap,

  v2.opening_as_of_date as v2_opening_as_of_date,
  v2.baseline_target as v2_baseline_target,
  v2.effective_target as v2_effective_target,
  v2.current_bank_balance as v2_current_bank_balance,
  v2.pending_reserved_payments as v2_pending_reserved_payments,
  v2.operational_available as v2_operational_available,
  v2.recoverable_draws as v2_recoverable_draws,
  v2.allocated_restorations as v2_allocated_restorations,
  v2.outstanding_recovery as v2_outstanding_recovery,
  v2.target_gap as v2_target_gap,
  v2.expected_ledger_balance as v2_expected_ledger_balance,
  v2.unreconciled_difference as v2_unreconciled_difference,
  v2.open_exception_count as v2_open_exception_count,
  v2.control_exception_count as v2_control_exception_count,
  v2.integrity_issue_count as v2_integrity_issue_count,
  v2.reconciliation_status as v2_reconciliation_status,

  v2.historical_variance::numeric(18,2) as opening_historical_variance,

  case
    when v1.reference_balance is null or v2.effective_target is null then null
    else (v2.effective_target-v1.reference_balance)::numeric(18,2)
  end as target_delta_v2_minus_v1,

  case
    when v2.current_bank_balance is null then null
    else (v2.current_bank_balance-v1.current_bank_balance)::numeric(18,2)
  end as bank_balance_delta_v2_minus_v1,

  case
    when v2.pending_reserved_payments is null then null
    else (v2.pending_reserved_payments-v1.reserved_balance)::numeric(18,2)
  end as reserved_payments_delta_v2_minus_v1,

  case
    when v2.operational_available is null then null
    else (v2.operational_available-v1.available_balance)::numeric(18,2)
  end as available_balance_delta_v2_minus_v1,

  case
    when v2.outstanding_recovery is null then null
    else (v2.outstanding_recovery-v1.outstanding_restoration)::numeric(18,2)
  end as outstanding_recovery_delta_v2_minus_v1,

  case
    when v2.target_gap is null then null
    else (v2.target_gap-v1.target_gap)::numeric(18,2)
  end as target_gap_delta_v2_minus_v1,

  case
    when v2.reconciliation_account_id is null
      then 'V2_NOT_CONFIGURED'
    when
      abs(coalesce(v2.current_bank_balance,0)-coalesce(v1.current_bank_balance,0)) > 0.01
      or abs(coalesce(v2.pending_reserved_payments,0)-coalesce(v1.reserved_balance,0)) > 0.01
      or abs(coalesce(v2.outstanding_recovery,0)-coalesce(v1.outstanding_restoration,0)) > 0.01
      or abs(coalesce(v2.target_gap,0)-coalesce(v1.target_gap,0)) > 0.01
      or (
        v1.reference_balance is not null
        and abs(coalesce(v2.effective_target,0)-v1.reference_balance) > 0.01
      )
      or abs(coalesce(v2.unreconciled_difference,0)) > 0.01
      or coalesce(v2.open_exception_count,0) > 0
      or coalesce(v2.control_exception_count,0) > 0
      or coalesce(v2.integrity_issue_count,0) > 0
      then 'REVIEW_REQUIRED'
    when abs(coalesce(v2.historical_variance,0)) > 0.01
      then 'BASELINE_MATCH_WITH_HISTORICAL_VARIANCE'
    else 'MATCH'
  end as shadow_comparison_status

from v1
left join v2
  on v2.bank_account_id = v1.bank_account_id;

comment on view public.reserve_v1_v2_shadow_comparison is
'Read-only Shadow Mode comparison between the current V1 reserve position and Reserve Reconciliation V2. It does not alter V1/V2 data, functions, workflows, or UI. Gross historical V1 draw/restoration totals are shown as context only; point-in-time comparable balances and gaps drive comparison status.';

revoke all on table public.reserve_v1_v2_shadow_comparison
from public, anon, authenticated, service_role;

grant select on table public.reserve_v1_v2_shadow_comparison
to service_role;

commit;
