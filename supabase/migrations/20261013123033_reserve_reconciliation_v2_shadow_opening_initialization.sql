
-- Reserve Reconciliation V2 - Shadow Opening Initialization
-- Writes only to new V2 tables. Existing V1 tables/functions/UI remain unchanged.

do $precheck$
declare
  v_existing bigint;
  v_accounts bigint;
  v_cfo bigint;
begin
  select
    (select count(*) from public.reserve_reconciliation_accounts)
    + (select count(*) from public.reserve_v2_opening_reconciliations)
    + (select count(*) from public.reserve_reconciliation_movements)
    + (select count(*) from public.reserve_balance_snapshots)
    + (select count(*) from public.reserve_target_ledger)
    + (select count(*) from public.reserve_reconciliation_exceptions)
  into v_existing;

  if v_existing <> 0 then
    raise exception 'V2 shadow opening initialization requires empty V2 state; found % rows', v_existing;
  end if;

  select count(*)
  into v_accounts
  from public.bank_accounts b
  join public.bank_liquidity bl on bl.id=b.id
  where b.account_type <> 'Operational';

  select count(*)
  into v_cfo
  from public.profiles
  where role='CFO' and active=true;

  -- A pristine fresh rebuild has no operational bank accounts or auth-backed profiles yet.
  -- In that exact state the shadow-opening DML below naturally inserts zero rows.
  if v_accounts = 0 and v_cfo = 0 then
    return;
  end if;

  if v_accounts <> 2 then
    raise exception 'Expected exactly 2 non-operational reserve accounts; found %', v_accounts;
  end if;

  if v_cfo <> 1 then
    raise exception 'Expected exactly 1 active CFO profile; found %', v_cfo;
  end if;
end
$precheck$;

insert into public.reserve_reconciliation_accounts (
  bank_account_id,
  reconciliation_enabled,
  base_target_amount,
  opening_balance,
  opening_date,
  currency_code,
  allocation_method,
  tolerance_amount,
  status,
  created_by,
  created_at,
  activated_by,
  activated_at,
  updated_at
)
select
  b.id,
  true,
  coalesce(b.reference_balance, bl.balance, 0)::numeric(18,2),
  coalesce(bl.balance,0)::numeric(18,2),
  (now() at time zone 'Asia/Riyadh')::date,
  'SAR',
  'FIFO',
  0.01,
  'Active',
  cfo.id,
  now(),
  cfo.id,
  now(),
  now()
from public.bank_accounts b
join public.bank_liquidity bl on bl.id=b.id
cross join lateral (
  select id
  from public.profiles
  where role='CFO' and active=true
  limit 1
) cfo
where b.account_type <> 'Operational';

with payment_outstanding as (
  select
    p.bank_account_id,
    coalesce(sum(
      greatest(
        p.amount - coalesce((
          select sum(r.amount)
          from public.bank_reserve_movements r
          where r.movement_type='Restoration'
            and r.restores_payment_id=p.id
        ),0),
        0
      )
    ),0)::numeric(18,2) as outstanding
  from public.payments p
  join public.bank_accounts b on b.id=p.bank_account_id
  where p.executed_at is not null
    and b.account_type <> 'Operational'
  group by p.bank_account_id
),
manual_outstanding as (
  select
    m.bank_account_id,
    coalesce(sum(
      greatest(
        m.amount - coalesce((
          select sum(r.amount)
          from public.bank_reserve_movements r
          where r.movement_type='Restoration'
            and r.restores_movement_id=m.id
        ),0),
        0
      )
    ) filter (where m.requires_restoration=true),0)::numeric(18,2) as outstanding
  from public.bank_reserve_movements m
  join public.bank_accounts b on b.id=m.bank_account_id
  where m.movement_type='Support Draw'
    and b.account_type <> 'Operational'
  group by m.bank_account_id
)
insert into public.reserve_v2_opening_reconciliations (
  reconciliation_account_id,
  as_of_date,
  current_balance,
  effective_target,
  outstanding_recovery,
  historical_variance,
  explanation,
  status,
  created_by,
  created_at,
  approved_by,
  approved_at
)
select
  a.id,
  a.opening_date,
  a.opening_balance,
  a.base_target_amount,
  (coalesce(po.outstanding,0)+coalesce(mo.outstanding,0))::numeric(18,2),
  (
    (coalesce(po.outstanding,0)+coalesce(mo.outstanding,0))
    - greatest(a.base_target_amount-a.opening_balance,0)
  )::numeric(18,2),
  'V2 Shadow opening baseline carried forward from the existing V1 position. No V1 historical row, bank balance, target, payment, reserve movement, workflow, function, or UI state is modified. Historical variance records the difference between recoverable outstanding and target gap at the cutover point.',
  'Approved',
  a.created_by,
  now(),
  a.activated_by,
  now()
from public.reserve_reconciliation_accounts a
left join payment_outstanding po on po.bank_account_id=a.bank_account_id
left join manual_outstanding mo on mo.bank_account_id=a.bank_account_id;

insert into public.reserve_balance_snapshots (
  reconciliation_account_id,
  snapshot_at,
  bank_balance,
  source,
  source_reference,
  previous_snapshot_id,
  note,
  created_by,
  created_at
)
select
  o.reconciliation_account_id,
  o.approved_at,
  o.current_balance,
  'OPENING_SNAPSHOT',
  'V2_SHADOW_OPENING:' || o.id::text,
  null,
  'Opening snapshot copied from the current bank balance for V2 Shadow Mode only; no bank_accounts balance was changed.',
  o.approved_by,
  o.approved_at
from public.reserve_v2_opening_reconciliations o
where o.status='Approved';

insert into public.reserve_reconciliation_movements (
  reconciliation_account_id,
  movement_date,
  movement_time,
  movement_type,
  direction,
  amount,
  requires_restoration,
  source_type,
  source_id,
  source_table,
  external_reference,
  description,
  classification_status,
  status,
  approved_by,
  approved_at,
  created_by,
  created_at,
  legacy_source,
  legacy_source_id
)
select
  o.reconciliation_account_id,
  o.as_of_date,
  o.approved_at,
  'RECOVERABLE_DRAW',
  'OUT',
  o.outstanding_recovery,
  true,
  'OPENING_RECONCILIATION',
  o.id::text,
  'reserve_v2_opening_reconciliations',
  'V2-SHADOW-OPENING-' || right(o.id::text,8),
  'Opening carried-forward recoverable balance from V1. This is a V2 baseline representation only and does not create a new bank outflow.',
  'Approved',
  'Approved',
  o.approved_by,
  o.approved_at,
  o.created_by,
  o.created_at,
  true,
  'V1_OUTSTANDING:' || a.bank_account_id::text
from public.reserve_v2_opening_reconciliations o
join public.reserve_reconciliation_accounts a
  on a.id=o.reconciliation_account_id
where o.status='Approved'
  and o.outstanding_recovery > 0;

do $postcheck$
declare
  v_accounts bigint;
  v_openings bigint;
  v_snapshots bigint;
  v_movements bigint;
  v_source_accounts bigint;
  v_source_cfo bigint;
begin
  select count(*) into v_accounts from public.reserve_reconciliation_accounts;
  select count(*) into v_openings from public.reserve_v2_opening_reconciliations;
  select count(*) into v_snapshots from public.reserve_balance_snapshots;
  select count(*) into v_movements from public.reserve_reconciliation_movements;
  select count(*) into v_source_accounts
  from public.bank_accounts
  where account_type <> 'Operational';
  select count(*) into v_source_cfo
  from public.profiles
  where role='CFO' and active=true;

  if v_source_accounts = 0 and v_source_cfo = 0 then
    if v_accounts <> 0 or v_openings <> 0 or v_snapshots <> 0 or v_movements <> 0 then
      raise exception
        'Unexpected V2 rows in pristine rebuild: accounts %, openings %, snapshots %, movements %',
        v_accounts, v_openings, v_snapshots, v_movements;
    end if;
    return;
  end if;

  if v_accounts <> 2 or v_openings <> 2 or v_snapshots <> 2 or v_movements <> 2 then
    raise exception
      'Unexpected V2 opening counts: accounts %, openings %, snapshots %, movements %',
      v_accounts, v_openings, v_snapshots, v_movements;
  end if;
end
$postcheck$;
