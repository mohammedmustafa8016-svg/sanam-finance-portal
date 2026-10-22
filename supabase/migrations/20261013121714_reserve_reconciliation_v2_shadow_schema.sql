-- ============================================================================
-- SANAM Finance Portal
-- Reserve Reconciliation V2 - Shadow Schema (Reviewed / Dependency-Documented)
-- Original design date: 2026-10-11
-- Reviewed wording: 2026-10-12
--
-- PURPOSE
--   Create a new, additive Reserve Reconciliation V2 layer for protected/reserve
--   bank accounts while preserving the current production data model and logic.
--
-- CURRENT-SYSTEM NON-MODIFICATION SCOPE
--   This script does NOT:
--     * ALTER the structure of any pre-existing table.
--     * CREATE, REPLACE, ALTER, or DROP any pre-existing function.
--     * UPDATE, DELETE, or INSERT rows in any pre-existing business table.
--     * change existing RLS policies, grants, triggers, workflow rules, dashboard
--       logic, payment logic, bank-balance logic, or current reserve calculations.
--     * switch any existing screen, report, API, or monitor to V2.
--
--   This script DOES:
--     * create new V2-only tables, constraints, indexes, policies, and views;
--     * reference selected existing objects for referential integrity and
--       read-only calculations;
--     * therefore create PostgreSQL schema/referential dependencies WITHOUT
--       changing the definition, data, or application behavior of those objects.
--
-- EXISTING OBJECT DEPENDENCIES CREATED BY THIS SCRIPT
--
--   1) public.bank_accounts
--      Dependency type:
--        * Foreign key from reserve_reconciliation_accounts.bank_account_id.
--        * Read-only VIEW dependency from reserve_expected_balance_v2 and
--          reserve_reconciliation_summary_v2.
--      Effect on existing object:
--        * No ALTER is issued against public.bank_accounts.
--        * No row is inserted, updated, or deleted by this script.
--        * Because the V2 FK uses ON UPDATE RESTRICT / ON DELETE RESTRICT,
--          a referenced bank account cannot later be deleted or have its key
--          changed while dependent V2 rows exist.
--
--   2) public.payments
--      Dependency type:
--        * Read-only VIEW dependency from reserve_reconciliation_summary_v2
--          to calculate pending reserved payments.
--      Effect on existing object:
--        * No ALTER is issued against public.payments.
--        * No row is inserted, updated, or deleted by this script.
--        * PostgreSQL will retain a schema dependency on the referenced columns
--          while the V2 view exists.
--
--   3) public.profiles
--      Dependency type:
--        * Foreign keys from V2 audit/approval/user reference columns such as
--          created_by, approved_by, activated_by, allocated_by, and resolved_by.
--      Effect on existing object:
--        * No ALTER is issued against public.profiles.
--        * No row is inserted, updated, or deleted by this script.
--        * Most profile references use ON DELETE SET NULL, preserving V2 history
--          without blocking profile deletion solely for those references.
--
-- IMPORTANT DISTINCTION
--   "Additive / non-modifying" means this script does not change the current
--   tables, functions, data, workflows, or application logic. It does not mean
--   "zero dependency": the new V2 objects intentionally depend on the existing
--   bank_accounts, payments, and profiles objects as documented above.
--
-- ACCESS / SHADOW MODE
--   * New V2 base tables are RLS-enabled and denied to anon/authenticated by
--     default.
--   * V2 views are not granted to current portal users by this script.
--   * service_role receives only the explicit V2 privileges declared below.
--   * The current Reserve Monitor remains unchanged and is not switched to V2.
--
-- TRANSACTIONAL SAFETY
--   * All DDL is wrapped in one transaction.
--   * A preflight block raises an exception if a named V2 relation already
--     exists, preventing silent reuse or replacement of an incompatible object.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 0. Preflight: fail cleanly if any V2 object already exists.
--    This prevents silently altering/reusing an incompatible object.
-- ----------------------------------------------------------------------------

do $preflight$
declare
  v_name text;
begin
  foreach v_name in array array[
    'reserve_reconciliation_accounts',
    'reserve_target_ledger',
    'reserve_reconciliation_movements',
    'reserve_restoration_allocations',
    'reserve_balance_snapshots',
    'reserve_reconciliation_exceptions',
    'reserve_v2_opening_reconciliations',
    'reserve_target_position_v2',
    'reserve_draw_status_v2',
    'reserve_movement_ledger_v2',
    'reserve_balance_snapshot_analysis_v2',
    'reserve_expected_balance_v2',
    'reserve_reconciliation_integrity_v2',
    'reserve_reconciliation_summary_v2'
  ]
  loop
    if to_regclass('public.' || v_name) is not null then
      raise exception 'Reserve Reconciliation V2 object already exists: public.%', v_name;
    end if;
  end loop;
end
$preflight$;

-- ============================================================================
-- 1. RECONCILIATION ACCOUNT CONFIGURATION
-- ============================================================================
-- Existing-object dependency introduced here:
--   bank_account_id REFERENCES public.bank_accounts(id).
-- This creates referential dependency only; public.bank_accounts is not altered.

create table public.reserve_reconciliation_accounts (
  id uuid primary key default gen_random_uuid(),

  bank_account_id uuid not null
    references public.bank_accounts(id)
    on update restrict
    on delete restrict,

  reconciliation_enabled boolean not null default false,

  -- Baseline target at V2 activation. Subsequent changes belong in Target Ledger.
  base_target_amount numeric(18,2) not null default 0,

  -- Baseline bank balance at the opening date.
  opening_balance numeric(18,2) not null default 0,
  opening_date date not null,

  currency_code text not null default 'SAR',
  allocation_method text not null default 'FIFO',
  tolerance_amount numeric(18,2) not null default 0.01,

  status text not null default 'Draft',

  created_by uuid
    references public.profiles(id)
    on update restrict
    on delete set null,
  created_at timestamptz not null default now(),

  activated_by uuid
    references public.profiles(id)
    on update restrict
    on delete set null,
  activated_at timestamptz,

  updated_at timestamptz not null default now(),

  constraint reserve_reconciliation_accounts_bank_unique
    unique (bank_account_id),

  constraint reserve_reconciliation_accounts_base_target_nonnegative
    check (base_target_amount >= 0),

  constraint reserve_reconciliation_accounts_tolerance_nonnegative
    check (tolerance_amount >= 0),

  constraint reserve_reconciliation_accounts_currency_check
    check (currency_code ~ '^[A-Z]{3}$'),

  constraint reserve_reconciliation_accounts_allocation_method_check
    check (allocation_method in ('FIFO','LIFO','MANUAL')),

  constraint reserve_reconciliation_accounts_status_check
    check (status in ('Draft','Active','Suspended')),

  constraint reserve_reconciliation_accounts_activation_check
    check (
      status <> 'Active'
      or (
        reconciliation_enabled = true
        and activated_at is not null
      )
    )
);

comment on table public.reserve_reconciliation_accounts is
'Reserve Reconciliation V2 account configuration. One V2 reconciliation profile per existing bank account.';

comment on column public.reserve_reconciliation_accounts.base_target_amount is
'Baseline target at activation/opening. Future approved target changes belong in reserve_target_ledger.';

comment on column public.reserve_reconciliation_accounts.opening_balance is
'Opening reconciled bank balance for V2 baseline; does not overwrite bank_accounts.balance.';

-- ============================================================================
-- 2. TARGET LEDGER
-- ============================================================================

create table public.reserve_target_ledger (
  id uuid primary key default gen_random_uuid(),

  reconciliation_account_id uuid not null
    references public.reserve_reconciliation_accounts(id)
    on update restrict
    on delete restrict,

  effective_date date not null,

  entry_type text not null,
  amount numeric(18,2) not null,
  direction text not null,

  reason text not null,

  source_type text not null default 'MANUAL',
  source_id text,

  status text not null default 'Draft',

  approved_by uuid
    references public.profiles(id)
    on update restrict
    on delete set null,
  approved_at timestamptz,

  created_by uuid
    references public.profiles(id)
    on update restrict
    on delete set null,
  created_at timestamptz not null default now(),

  reversal_of_id uuid
    references public.reserve_target_ledger(id)
    on update restrict
    on delete restrict,

  constraint reserve_target_ledger_entry_type_check
    check (
      entry_type in (
        'BASE_TARGET',
        'TARGET_INCREASE',
        'TARGET_DECREASE',
        'PERMANENT_RELEASE',
        'OPENING_ADJUSTMENT',
        'CORRECTION'
      )
    ),

  constraint reserve_target_ledger_amount_positive
    check (amount > 0),

  constraint reserve_target_ledger_direction_check
    check (direction in ('INCREASE','DECREASE')),

  constraint reserve_target_ledger_direction_semantics_check
    check (
      (entry_type in ('BASE_TARGET','TARGET_INCREASE') and direction = 'INCREASE')
      or
      (entry_type in ('TARGET_DECREASE','PERMANENT_RELEASE') and direction = 'DECREASE')
      or
      (entry_type in ('OPENING_ADJUSTMENT','CORRECTION'))
    ),

  constraint reserve_target_ledger_reason_required
    check (length(trim(reason)) > 0),

  constraint reserve_target_ledger_status_check
    check (status in ('Draft','Approved','Reversed')),

  constraint reserve_target_ledger_approval_check
    check (
      status <> 'Approved'
      or approved_at is not null
    ),

  constraint reserve_target_ledger_no_self_reversal
    check (reversal_of_id is null or reversal_of_id <> id)
);

comment on table public.reserve_target_ledger is
'Immutable-style V2 target ledger. Recoverable draws and restorations must never alter the target through this ledger.';

-- ============================================================================
-- 3. NORMALIZED RESERVE MOVEMENT LEDGER
-- ============================================================================

create table public.reserve_reconciliation_movements (
  id uuid primary key default gen_random_uuid(),

  reconciliation_account_id uuid not null
    references public.reserve_reconciliation_accounts(id)
    on update restrict
    on delete restrict,

  movement_date date not null,
  movement_time timestamptz,

  movement_type text not null,
  direction text not null,
  amount numeric(18,2) not null,

  requires_restoration boolean not null default false,

  source_type text not null default 'MANUAL',
  source_id text,
  source_table text,
  external_reference text,

  description text,

  classification_status text not null default 'Pending',
  status text not null default 'Draft',

  approved_by uuid
    references public.profiles(id)
    on update restrict
    on delete set null,
  approved_at timestamptz,

  created_by uuid
    references public.profiles(id)
    on update restrict
    on delete set null,
  created_at timestamptz not null default now(),

  legacy_source boolean not null default false,
  legacy_source_id text,

  reversal_of_id uuid
    references public.reserve_reconciliation_movements(id)
    on update restrict
    on delete restrict,

  constraint reserve_reconciliation_movements_type_check
    check (
      movement_type in (
        'RECOVERABLE_DRAW',
        'RESTORATION',
        'PERMANENT_RELEASE',
        'EXTERNAL_CREDIT',
        'EXTERNAL_DEBIT',
        'PAYMENT',
        'TRANSFER_IN',
        'TRANSFER_OUT',
        'BANK_CHARGE',
        'CORRECTION',
        'OPENING_BALANCE'
      )
    ),

  constraint reserve_reconciliation_movements_direction_check
    check (direction in ('IN','OUT')),

  constraint reserve_reconciliation_movements_amount_positive
    check (amount > 0),

  constraint reserve_reconciliation_movements_classification_check
    check (classification_status in ('Auto','Pending','Approved')),

  constraint reserve_reconciliation_movements_status_check
    check (status in ('Draft','Approved','Reversed')),

  constraint reserve_reconciliation_movements_approval_check
    check (
      status <> 'Approved'
      or approved_at is not null
    ),

  constraint reserve_reconciliation_movements_direction_semantics_check
    check (
      (movement_type = 'RECOVERABLE_DRAW'
        and direction = 'OUT'
        and requires_restoration = true)
      or
      (movement_type = 'RESTORATION'
        and direction = 'IN'
        and requires_restoration = false)
      or
      (movement_type = 'PERMANENT_RELEASE'
        and direction = 'OUT'
        and requires_restoration = false)
      or
      (movement_type in ('EXTERNAL_CREDIT','TRANSFER_IN','OPENING_BALANCE')
        and direction = 'IN')
      or
      (movement_type in ('EXTERNAL_DEBIT','PAYMENT','TRANSFER_OUT','BANK_CHARGE')
        and direction = 'OUT')
      or
      (movement_type = 'CORRECTION')
    ),

  constraint reserve_reconciliation_movements_no_self_reversal
    check (reversal_of_id is null or reversal_of_id <> id)
);

comment on table public.reserve_reconciliation_movements is
'Normalized V2 reserve movement ledger. Economic movements are recorded separately from Target changes.';

-- ============================================================================
-- 4. RESTORATION-TO-DRAW ALLOCATIONS
-- ============================================================================

create table public.reserve_restoration_allocations (
  id uuid primary key default gen_random_uuid(),

  restoration_movement_id uuid not null
    references public.reserve_reconciliation_movements(id)
    on update restrict
    on delete restrict,

  draw_movement_id uuid not null
    references public.reserve_reconciliation_movements(id)
    on update restrict
    on delete restrict,

  allocated_amount numeric(18,2) not null,

  allocation_method text not null default 'FIFO',

  allocated_by uuid
    references public.profiles(id)
    on update restrict
    on delete set null,
  allocated_at timestamptz not null default now(),

  is_manual_override boolean not null default false,

  constraint reserve_restoration_allocations_amount_positive
    check (allocated_amount > 0),

  constraint reserve_restoration_allocations_method_check
    check (allocation_method in ('FIFO','LIFO','MANUAL')),

  constraint reserve_restoration_allocations_no_self_link
    check (restoration_movement_id <> draw_movement_id),

  constraint reserve_restoration_allocations_pair_unique
    unique (restoration_movement_id, draw_movement_id)
);

comment on table public.reserve_restoration_allocations is
'Allocation bridge between approved RESTORATION movements and approved RECOVERABLE_DRAW movements.';

-- ============================================================================
-- 5. BANK BALANCE SNAPSHOTS
-- ============================================================================

create table public.reserve_balance_snapshots (
  id uuid primary key default gen_random_uuid(),

  reconciliation_account_id uuid not null
    references public.reserve_reconciliation_accounts(id)
    on update restrict
    on delete restrict,

  snapshot_at timestamptz not null,
  bank_balance numeric(18,2) not null,

  source text not null,
  source_reference text,

  previous_snapshot_id uuid
    references public.reserve_balance_snapshots(id)
    on update restrict
    on delete restrict,

  note text,

  created_by uuid
    references public.profiles(id)
    on update restrict
    on delete set null,
  created_at timestamptz not null default now(),

  constraint reserve_balance_snapshots_source_check
    check (
      source in (
        'MANUAL_BALANCE_UPDATE',
        'BANK_IMPORT',
        'BUSINESS_CENTRAL',
        'OPENING_SNAPSHOT',
        'OTHER'
      )
    ),

  constraint reserve_balance_snapshots_no_self_previous
    check (previous_snapshot_id is null or previous_snapshot_id <> id),

  constraint reserve_balance_snapshots_account_time_unique
    unique (reconciliation_account_id, snapshot_at)
);

comment on table public.reserve_balance_snapshots is
'Point-in-time bank balance snapshots used to reconcile actual balance movement against the V2 movement ledger.';

-- ============================================================================
-- 6. RECONCILIATION EXCEPTIONS
-- ============================================================================

create table public.reserve_reconciliation_exceptions (
  id uuid primary key default gen_random_uuid(),

  reconciliation_account_id uuid not null
    references public.reserve_reconciliation_accounts(id)
    on update restrict
    on delete restrict,

  snapshot_id uuid
    references public.reserve_balance_snapshots(id)
    on update restrict
    on delete restrict,

  movement_id uuid
    references public.reserve_reconciliation_movements(id)
    on update restrict
    on delete restrict,

  exception_type text not null,
  amount numeric(18,2) not null default 0,

  detected_at timestamptz not null default now(),

  status text not null default 'OPEN',

  suggested_classification text,

  resolution_type text,
  resolution_movement_id uuid
    references public.reserve_reconciliation_movements(id)
    on update restrict
    on delete restrict,

  resolution_note text,

  resolved_by uuid
    references public.profiles(id)
    on update restrict
    on delete set null,
  resolved_at timestamptz,

  constraint reserve_reconciliation_exceptions_type_check
    check (
      exception_type in (
        'UNRECORDED_DEBIT',
        'UNRECORDED_CREDIT',
        'DUPLICATE_MOVEMENT',
        'TARGET_MOVEMENT_CONFLICT',
        'RESTORATION_OVERALLOCATION',
        'SOURCE_MISMATCH',
        'BALANCE_MISMATCH'
      )
    ),

  constraint reserve_reconciliation_exceptions_amount_nonnegative
    check (amount >= 0),

  constraint reserve_reconciliation_exceptions_status_check
    check (
      status in (
        'OPEN',
        'UNDER_REVIEW',
        'RESOLVED',
        'IGNORED_WITH_APPROVAL'
      )
    ),

  constraint reserve_reconciliation_exceptions_resolution_check
    check (
      status not in ('RESOLVED','IGNORED_WITH_APPROVAL')
      or (
        resolved_at is not null
        and resolved_by is not null
        and nullif(trim(coalesce(resolution_note,'')),'') is not null
      )
    )
);

comment on table public.reserve_reconciliation_exceptions is
'V2 exception queue. Unexplained bank deltas remain explicit exceptions instead of being silently included in Recovery.';

-- ============================================================================
-- 7. OPENING RECONCILIATION / HISTORICAL CUTOVER BASELINE
-- ============================================================================

create table public.reserve_v2_opening_reconciliations (
  id uuid primary key default gen_random_uuid(),

  reconciliation_account_id uuid not null
    references public.reserve_reconciliation_accounts(id)
    on update restrict
    on delete restrict,

  as_of_date date not null,

  current_balance numeric(18,2) not null,
  effective_target numeric(18,2) not null,
  outstanding_recovery numeric(18,2) not null,

  historical_variance numeric(18,2) not null default 0,

  explanation text not null,

  status text not null default 'Draft',

  created_by uuid
    references public.profiles(id)
    on update restrict
    on delete set null,
  created_at timestamptz not null default now(),

  approved_by uuid
    references public.profiles(id)
    on update restrict
    on delete set null,
  approved_at timestamptz,

  constraint reserve_v2_opening_effective_target_nonnegative
    check (effective_target >= 0),

  constraint reserve_v2_opening_recovery_nonnegative
    check (outstanding_recovery >= 0),

  constraint reserve_v2_opening_explanation_required
    check (length(trim(explanation)) > 0),

  constraint reserve_v2_opening_status_check
    check (status in ('Draft','Approved','Superseded')),

  constraint reserve_v2_opening_approval_check
    check (
      status <> 'Approved'
      or (
        approved_at is not null
        and approved_by is not null
      )
    )
);

comment on table public.reserve_v2_opening_reconciliations is
'Approved historical opening position for V2. Used to preserve legacy data unchanged while starting controlled reconciliation prospectively.';

-- ============================================================================
-- 8. INDEXES / DUPLICATE-PREVENTION
-- ============================================================================

create index idx_reserve_reconciliation_accounts_status
  on public.reserve_reconciliation_accounts(status, reconciliation_enabled);

create index idx_reserve_target_ledger_account_date
  on public.reserve_target_ledger(reconciliation_account_id, effective_date, created_at);

create index idx_reserve_target_ledger_account_status
  on public.reserve_target_ledger(reconciliation_account_id, status, entry_type);

create unique index uq_reserve_target_ledger_source
  on public.reserve_target_ledger(
    reconciliation_account_id,
    source_type,
    source_id
  )
  where source_id is not null;

create unique index uq_reserve_target_approved_base
  on public.reserve_target_ledger(reconciliation_account_id)
  where entry_type = 'BASE_TARGET'
    and status = 'Approved';

create index idx_reserve_movements_account_date
  on public.reserve_reconciliation_movements(
    reconciliation_account_id,
    movement_date,
    created_at
  );

create index idx_reserve_movements_account_type_status
  on public.reserve_reconciliation_movements(
    reconciliation_account_id,
    movement_type,
    status
  );

create index idx_reserve_movements_external_reference
  on public.reserve_reconciliation_movements(
    reconciliation_account_id,
    external_reference
  )
  where external_reference is not null;

create unique index uq_reserve_movements_source
  on public.reserve_reconciliation_movements(
    reconciliation_account_id,
    source_type,
    source_id
  )
  where source_id is not null;

create unique index uq_reserve_movements_legacy_source
  on public.reserve_reconciliation_movements(
    reconciliation_account_id,
    legacy_source_id
  )
  where legacy_source = true
    and legacy_source_id is not null;

create index idx_reserve_allocations_restoration
  on public.reserve_restoration_allocations(restoration_movement_id);

create index idx_reserve_allocations_draw
  on public.reserve_restoration_allocations(draw_movement_id);

create index idx_reserve_snapshots_account_time
  on public.reserve_balance_snapshots(
    reconciliation_account_id,
    snapshot_at desc
  );

create index idx_reserve_exceptions_account_status
  on public.reserve_reconciliation_exceptions(
    reconciliation_account_id,
    status,
    exception_type,
    detected_at desc
  );

create index idx_reserve_opening_account_date
  on public.reserve_v2_opening_reconciliations(
    reconciliation_account_id,
    as_of_date desc
  );

create unique index uq_reserve_opening_one_approved
  on public.reserve_v2_opening_reconciliations(reconciliation_account_id)
  where status = 'Approved';

-- ============================================================================
-- 9. RLS / DEFAULT DENY
--    No current portal user is granted direct access by this schema.
--    Future RPCs may be added separately after Shadow Mode acceptance.
-- ============================================================================

alter table public.reserve_reconciliation_accounts enable row level security;
alter table public.reserve_target_ledger enable row level security;
alter table public.reserve_reconciliation_movements enable row level security;
alter table public.reserve_restoration_allocations enable row level security;
alter table public.reserve_balance_snapshots enable row level security;
alter table public.reserve_reconciliation_exceptions enable row level security;
alter table public.reserve_v2_opening_reconciliations enable row level security;

create policy reserve_reconciliation_accounts_deny_direct
  on public.reserve_reconciliation_accounts
  as restrictive for all to public
  using (false) with check (false);

create policy reserve_target_ledger_deny_direct
  on public.reserve_target_ledger
  as restrictive for all to public
  using (false) with check (false);

create policy reserve_reconciliation_movements_deny_direct
  on public.reserve_reconciliation_movements
  as restrictive for all to public
  using (false) with check (false);

create policy reserve_restoration_allocations_deny_direct
  on public.reserve_restoration_allocations
  as restrictive for all to public
  using (false) with check (false);

create policy reserve_balance_snapshots_deny_direct
  on public.reserve_balance_snapshots
  as restrictive for all to public
  using (false) with check (false);

create policy reserve_reconciliation_exceptions_deny_direct
  on public.reserve_reconciliation_exceptions
  as restrictive for all to public
  using (false) with check (false);

create policy reserve_v2_opening_reconciliations_deny_direct
  on public.reserve_v2_opening_reconciliations
  as restrictive for all to public
  using (false) with check (false);

revoke all on table public.reserve_reconciliation_accounts from public, anon, authenticated;
revoke all on table public.reserve_target_ledger from public, anon, authenticated;
revoke all on table public.reserve_reconciliation_movements from public, anon, authenticated;
revoke all on table public.reserve_restoration_allocations from public, anon, authenticated;
revoke all on table public.reserve_balance_snapshots from public, anon, authenticated;
revoke all on table public.reserve_reconciliation_exceptions from public, anon, authenticated;
revoke all on table public.reserve_v2_opening_reconciliations from public, anon, authenticated;

grant select, insert, update, delete
  on table public.reserve_reconciliation_accounts,
           public.reserve_target_ledger,
           public.reserve_reconciliation_movements,
           public.reserve_restoration_allocations,
           public.reserve_balance_snapshots,
           public.reserve_reconciliation_exceptions,
           public.reserve_v2_opening_reconciliations
  to service_role;

-- ============================================================================
-- 10. VIEW: TARGET POSITION
-- ============================================================================
-- V2-only view. Reads only V2 tables and creates no dependency on current
-- production business tables beyond those already referenced by V2 FKs.

create view public.reserve_target_position_v2
with (security_invoker = true)
as
with approved_opening as (
  select
    o.*,
    row_number() over (
      partition by o.reconciliation_account_id
      order by o.as_of_date desc, o.approved_at desc, o.created_at desc
    ) as rn
  from public.reserve_v2_opening_reconciliations o
  where o.status = 'Approved'
),
approved_base_entry as (
  select
    l.reconciliation_account_id,
    l.amount,
    l.effective_date,
    row_number() over (
      partition by l.reconciliation_account_id
      order by l.effective_date desc, l.approved_at desc, l.created_at desc
    ) as rn
  from public.reserve_target_ledger l
  where l.status = 'Approved'
    and l.entry_type = 'BASE_TARGET'
),
baseline as (
  select
    a.id as reconciliation_account_id,
    a.bank_account_id,
    a.currency_code,
    a.tolerance_amount,
    case
      when o.id is not null then o.effective_target
      when b.reconciliation_account_id is not null then b.amount
      else a.base_target_amount
    end as baseline_target,
    case
      when o.id is not null then o.as_of_date
      when b.reconciliation_account_id is not null then b.effective_date
      else a.opening_date
    end as baseline_date,
    (o.id is not null) as baseline_from_opening
  from public.reserve_reconciliation_accounts a
  left join approved_opening o
    on o.reconciliation_account_id = a.id
   and o.rn = 1
  left join approved_base_entry b
    on b.reconciliation_account_id = a.id
   and b.rn = 1
),
adjustments as (
  select
    b.reconciliation_account_id,
    coalesce(sum(
      case
        when l.direction = 'INCREASE' then l.amount
        when l.direction = 'DECREASE' then -l.amount
        else 0
      end
    ),0) as approved_adjustments,
    coalesce(sum(l.amount) filter (
      where l.entry_type = 'TARGET_INCREASE'
    ),0) as target_increases,
    coalesce(sum(l.amount) filter (
      where l.entry_type = 'TARGET_DECREASE'
    ),0) as target_decreases,
    coalesce(sum(l.amount) filter (
      where l.entry_type = 'PERMANENT_RELEASE'
    ),0) as permanent_releases
  from baseline b
  left join public.reserve_target_ledger l
    on l.reconciliation_account_id = b.reconciliation_account_id
   and l.status = 'Approved'
   and l.entry_type <> 'BASE_TARGET'
   and (
     (b.baseline_from_opening = true and l.effective_date > b.baseline_date)
     or
     (b.baseline_from_opening = false and l.effective_date >= b.baseline_date)
   )
  group by b.reconciliation_account_id
)
select
  b.reconciliation_account_id,
  b.bank_account_id,
  b.currency_code,
  b.tolerance_amount,
  b.baseline_target,
  b.baseline_date,
  coalesce(a.target_increases,0) as target_increases,
  coalesce(a.target_decreases,0) as target_decreases,
  coalesce(a.permanent_releases,0) as permanent_releases,
  coalesce(a.approved_adjustments,0) as net_target_adjustments,
  greatest(
    b.baseline_target + coalesce(a.approved_adjustments,0),
    0
  )::numeric(18,2) as effective_target
from baseline b
left join adjustments a
  on a.reconciliation_account_id = b.reconciliation_account_id;

comment on view public.reserve_target_position_v2 is
'Read-only V2 effective target calculation. Uses approved opening reconciliation when available; otherwise approved BASE_TARGET or account baseline.';

-- ============================================================================
-- 11. VIEW: DRAW / RESTORATION STATUS
-- ============================================================================

create view public.reserve_draw_status_v2
with (security_invoker = true)
as
with valid_allocations as (
  select
    a.draw_movement_id,
    sum(a.allocated_amount) as restored_amount
  from public.reserve_restoration_allocations a
  join public.reserve_reconciliation_movements r
    on r.id = a.restoration_movement_id
   and r.movement_type = 'RESTORATION'
   and r.status = 'Approved'
  join public.reserve_reconciliation_movements d
    on d.id = a.draw_movement_id
   and d.movement_type = 'RECOVERABLE_DRAW'
   and d.status = 'Approved'
  group by a.draw_movement_id
)
select
  d.id as draw_movement_id,
  d.reconciliation_account_id,
  d.movement_date,
  d.movement_time,
  d.amount as draw_amount,
  least(coalesce(a.restored_amount,0), d.amount)::numeric(18,2) as restored_amount,
  greatest(d.amount - coalesce(a.restored_amount,0),0)::numeric(18,2) as outstanding_amount,
  case
    when coalesce(a.restored_amount,0) <= 0 then 'Open'
    when coalesce(a.restored_amount,0) < d.amount then 'Partially Restored'
    else 'Fully Restored'
  end as restoration_status,
  d.source_type,
  d.source_id,
  d.external_reference,
  d.description
from public.reserve_reconciliation_movements d
left join valid_allocations a
  on a.draw_movement_id = d.id
where d.movement_type = 'RECOVERABLE_DRAW'
  and d.status = 'Approved';

comment on view public.reserve_draw_status_v2 is
'Approved recoverable draws with allocated restorations and calculated outstanding recovery.';

-- ============================================================================
-- 12. VIEW: MOVEMENT LEDGER WITH RECOVERY POSITION
-- ============================================================================

create view public.reserve_movement_ledger_v2
with (security_invoker = true)
as
with restoration_usage as (
  select
    a.restoration_movement_id,
    sum(a.allocated_amount) as allocated_amount
  from public.reserve_restoration_allocations a
  join public.reserve_reconciliation_movements r
    on r.id = a.restoration_movement_id
   and r.movement_type = 'RESTORATION'
   and r.status = 'Approved'
  join public.reserve_reconciliation_movements d
    on d.id = a.draw_movement_id
   and d.movement_type = 'RECOVERABLE_DRAW'
   and d.status = 'Approved'
  group by a.restoration_movement_id
)
select
  m.id,
  m.reconciliation_account_id,
  m.movement_date,
  m.movement_time,
  m.movement_type,
  m.direction,
  m.amount,
  m.requires_restoration,
  m.source_type,
  m.source_id,
  m.source_table,
  m.external_reference,
  m.description,
  m.classification_status,
  m.status,
  m.legacy_source,
  m.legacy_source_id,
  case
    when m.movement_type = 'RECOVERABLE_DRAW'
      then d.restored_amount
    else null
  end as restored_against_draw,
  case
    when m.movement_type = 'RECOVERABLE_DRAW'
      then d.outstanding_amount
    else null
  end as outstanding_draw_amount,
  case
    when m.movement_type = 'RESTORATION'
      then coalesce(r.allocated_amount,0)
    else null
  end as restoration_allocated_amount,
  case
    when m.movement_type = 'RESTORATION'
      then greatest(m.amount - coalesce(r.allocated_amount,0),0)
    else null
  end as restoration_unallocated_amount,
  m.created_at,
  m.approved_at
from public.reserve_reconciliation_movements m
left join public.reserve_draw_status_v2 d
  on d.draw_movement_id = m.id
left join restoration_usage r
  on r.restoration_movement_id = m.id;

comment on view public.reserve_movement_ledger_v2 is
'V2 movement ledger enriched with recoverable-draw and restoration-allocation balances.';

-- ============================================================================
-- 13. VIEW: SNAPSHOT RECONCILIATION ANALYSIS
-- ============================================================================

create view public.reserve_balance_snapshot_analysis_v2
with (security_invoker = true)
as
with ordered as (
  select
    s.*,
    lag(s.snapshot_at) over (
      partition by s.reconciliation_account_id
      order by s.snapshot_at
    ) as prior_snapshot_at,
    lag(s.bank_balance) over (
      partition by s.reconciliation_account_id
      order by s.snapshot_at
    ) as prior_snapshot_balance
  from public.reserve_balance_snapshots s
),
base as (
  select
    o.*,
    coalesce(
      o.prior_snapshot_at,
      (a.opening_date::timestamp at time zone 'Asia/Riyadh')
    ) as comparison_start_at,
    coalesce(
      o.prior_snapshot_balance,
      a.opening_balance
    ) as comparison_start_balance
  from ordered o
  join public.reserve_reconciliation_accounts a
    on a.id = o.reconciliation_account_id
),
ledger as (
  select
    b.id as snapshot_id,
    coalesce(sum(
      case
        when m.direction = 'IN' then m.amount
        when m.direction = 'OUT' then -m.amount
        else 0
      end
    ),0) as ledger_delta
  from base b
  left join public.reserve_reconciliation_movements m
    on m.reconciliation_account_id = b.reconciliation_account_id
   and m.status = 'Approved'
   and coalesce(
         m.movement_time,
         ((m.movement_date::timestamp + time '23:59:59') at time zone 'Asia/Riyadh')
       ) > b.comparison_start_at
   and coalesce(
         m.movement_time,
         ((m.movement_date::timestamp + time '23:59:59') at time zone 'Asia/Riyadh')
       ) <= b.snapshot_at
  group by b.id
)
select
  b.id as snapshot_id,
  b.reconciliation_account_id,
  b.snapshot_at,
  b.bank_balance,
  b.source,
  b.source_reference,
  b.comparison_start_at,
  b.comparison_start_balance,
  (b.bank_balance - b.comparison_start_balance)::numeric(18,2) as balance_delta,
  coalesce(l.ledger_delta,0)::numeric(18,2) as ledger_delta,
  (
    (b.bank_balance - b.comparison_start_balance)
    - coalesce(l.ledger_delta,0)
  )::numeric(18,2) as unreconciled_delta
from base b
left join ledger l
  on l.snapshot_id = b.id;

comment on view public.reserve_balance_snapshot_analysis_v2 is
'Compares each bank balance snapshot change with approved V2 ledger movement over the same period.';

-- ============================================================================
-- 14. VIEW: EXPECTED LEDGER BALANCE VS CURRENT BANK BALANCE
-- ============================================================================
-- Existing-object dependency introduced here:
--   READ-ONLY reference to public.bank_accounts.balance.
-- The view does not update bank_accounts; it only compares the existing balance
-- with the expected V2 ledger balance.

create view public.reserve_expected_balance_v2
with (security_invoker = true)
as
with approved_opening as (
  select
    o.*,
    row_number() over (
      partition by o.reconciliation_account_id
      order by o.as_of_date desc, o.approved_at desc, o.created_at desc
    ) as rn
  from public.reserve_v2_opening_reconciliations o
  where o.status = 'Approved'
),
baseline as (
  select
    a.id as reconciliation_account_id,
    a.bank_account_id,
    coalesce(o.current_balance, a.opening_balance) as baseline_balance,
    coalesce(o.as_of_date, a.opening_date) as baseline_date,
    (o.id is not null) as baseline_from_opening
  from public.reserve_reconciliation_accounts a
  left join approved_opening o
    on o.reconciliation_account_id = a.id
   and o.rn = 1
),
movement_delta as (
  select
    b.reconciliation_account_id,
    coalesce(sum(
      case
        when m.direction = 'IN' then m.amount
        when m.direction = 'OUT' then -m.amount
        else 0
      end
    ),0) as net_movement
  from baseline b
  left join public.reserve_reconciliation_movements m
    on m.reconciliation_account_id = b.reconciliation_account_id
   and m.status = 'Approved'
   and (
     (b.baseline_from_opening = true and m.movement_date > b.baseline_date)
     or
     (b.baseline_from_opening = false and m.movement_date >= b.baseline_date)
   )
  group by b.reconciliation_account_id
)
select
  b.reconciliation_account_id,
  b.bank_account_id,
  b.baseline_date,
  b.baseline_balance::numeric(18,2) as baseline_balance,
  coalesce(m.net_movement,0)::numeric(18,2) as net_approved_movement,
  (b.baseline_balance + coalesce(m.net_movement,0))::numeric(18,2) as expected_ledger_balance,
  coalesce(ba.balance,0)::numeric(18,2) as actual_bank_balance,
  (
    coalesce(ba.balance,0)
    - (b.baseline_balance + coalesce(m.net_movement,0))
  )::numeric(18,2) as unreconciled_difference
from baseline b
join public.bank_accounts ba
  on ba.id = b.bank_account_id
left join movement_delta m
  on m.reconciliation_account_id = b.reconciliation_account_id;

comment on view public.reserve_expected_balance_v2 is
'Expected bank balance from the approved V2 opening position plus approved movement ledger, compared with bank_accounts.balance read-only.';

-- ============================================================================
-- 15. VIEW: INTEGRITY / CONTROL EXCEPTIONS DETECTABLE WITHOUT TRIGGERS
-- ============================================================================

create view public.reserve_reconciliation_integrity_v2
with (security_invoker = true)
as
with restoration_alloc as (
  select
    a.restoration_movement_id,
    sum(a.allocated_amount) as allocated_amount
  from public.reserve_restoration_allocations a
  group by a.restoration_movement_id
),
draw_alloc as (
  select
    a.draw_movement_id,
    sum(a.allocated_amount) as allocated_amount
  from public.reserve_restoration_allocations a
  group by a.draw_movement_id
)
select
  r.reconciliation_account_id,
  'RESTORATION_SOURCE_TYPE_MISMATCH'::text as issue_type,
  a.id::text as object_id,
  a.allocated_amount::numeric(18,2) as amount,
  'Allocation restoration_movement_id does not point to an approved RESTORATION movement.'::text as detail
from public.reserve_restoration_allocations a
join public.reserve_reconciliation_movements r
  on r.id = a.restoration_movement_id
where r.movement_type <> 'RESTORATION'
   or r.status <> 'Approved'

union all

select
  d.reconciliation_account_id,
  'DRAW_SOURCE_TYPE_MISMATCH'::text,
  a.id::text,
  a.allocated_amount::numeric(18,2),
  'Allocation draw_movement_id does not point to an approved RECOVERABLE_DRAW movement.'::text
from public.reserve_restoration_allocations a
join public.reserve_reconciliation_movements d
  on d.id = a.draw_movement_id
where d.movement_type <> 'RECOVERABLE_DRAW'
   or d.status <> 'Approved'

union all

select
  r.reconciliation_account_id,
  'RESTORATION_OVERALLOCATION'::text,
  r.id::text,
  greatest(coalesce(x.allocated_amount,0) - r.amount,0)::numeric(18,2),
  'Allocated amount exceeds the restoration movement amount.'::text
from public.reserve_reconciliation_movements r
join restoration_alloc x
  on x.restoration_movement_id = r.id
where r.movement_type = 'RESTORATION'
  and x.allocated_amount > r.amount

union all

select
  d.reconciliation_account_id,
  'DRAW_OVERRESTORED'::text,
  d.id::text,
  greatest(coalesce(x.allocated_amount,0) - d.amount,0)::numeric(18,2),
  'Allocated restorations exceed the recoverable draw amount.'::text
from public.reserve_reconciliation_movements d
join draw_alloc x
  on x.draw_movement_id = d.id
where d.movement_type = 'RECOVERABLE_DRAW'
  and x.allocated_amount > d.amount

union all

select
  m.reconciliation_account_id,
  'TARGET_MOVEMENT_CONFLICT'::text,
  m.id::text,
  m.amount::numeric(18,2),
  'Recoverable draw/restoration source is also present in Target Ledger. This indicates possible double-counting.'::text
from public.reserve_reconciliation_movements m
join public.reserve_target_ledger t
  on t.reconciliation_account_id = m.reconciliation_account_id
 and t.source_type = m.source_type
 and t.source_id = m.source_id
where m.source_id is not null
  and m.movement_type in ('RECOVERABLE_DRAW','RESTORATION')
  and m.status = 'Approved'
  and t.status = 'Approved';

comment on view public.reserve_reconciliation_integrity_v2 is
'Read-only control view for allocation and double-counting conditions that require cross-row validation.';

-- ============================================================================
-- 16. VIEW: CONSOLIDATED RECONCILIATION SUMMARY
-- ============================================================================
-- Existing-object dependencies introduced here:
--   * READ-ONLY reference to public.bank_accounts for account metadata/balance.
--   * READ-ONLY reference to public.payments for pending reserved payments.
-- These dependencies do not modify either existing table.

create view public.reserve_reconciliation_summary_v2
with (security_invoker = true)
as
with recovery as (
  select
    d.reconciliation_account_id,
    coalesce(sum(d.draw_amount),0) as recoverable_draws,
    coalesce(sum(d.restored_amount),0) as allocated_restorations,
    coalesce(sum(d.outstanding_amount),0) as outstanding_recovery
  from public.reserve_draw_status_v2 d
  group by d.reconciliation_account_id
),
pending_payments as (
  select
    a.id as reconciliation_account_id,
    coalesce(sum(p.amount),0) as pending_reserved_payments
  from public.reserve_reconciliation_accounts a
  left join public.payments p
    on p.bank_account_id = a.bank_account_id
   and p.executed_at is null
   and p.status not in ('مرفوض','موقوف','مرحّل')
  group by a.id
),
open_exceptions as (
  select
    e.reconciliation_account_id,
    count(*) as open_exception_count,
    count(*) filter (
      where e.exception_type in (
        'DUPLICATE_MOVEMENT',
        'TARGET_MOVEMENT_CONFLICT',
        'RESTORATION_OVERALLOCATION',
        'SOURCE_MISMATCH'
      )
    ) as control_exception_count,
    coalesce(sum(e.amount) filter (
      where e.exception_type = 'UNRECORDED_DEBIT'
    ),0) as unclassified_debit,
    coalesce(sum(e.amount) filter (
      where e.exception_type = 'UNRECORDED_CREDIT'
    ),0) as unclassified_credit
  from public.reserve_reconciliation_exceptions e
  where e.status in ('OPEN','UNDER_REVIEW')
  group by e.reconciliation_account_id
),
integrity as (
  select
    i.reconciliation_account_id,
    count(*) as integrity_issue_count
  from public.reserve_reconciliation_integrity_v2 i
  group by i.reconciliation_account_id
),
latest_snapshot as (
  select
    s.reconciliation_account_id,
    s.snapshot_at,
    row_number() over (
      partition by s.reconciliation_account_id
      order by s.snapshot_at desc
    ) as rn
  from public.reserve_balance_snapshots s
)
select
  a.id as reconciliation_account_id,
  a.bank_account_id,

  ba.company,
  ba.bank_name,
  ba.account_name,
  ba.account_type,

  a.currency_code,
  a.status as reconciliation_account_status,
  a.reconciliation_enabled,

  coalesce(t.baseline_target, a.base_target_amount)::numeric(18,2) as baseline_target,
  coalesce(t.target_increases,0)::numeric(18,2) as target_increases,
  coalesce(t.target_decreases,0)::numeric(18,2) as target_decreases,
  coalesce(t.permanent_releases,0)::numeric(18,2) as permanent_releases,
  coalesce(t.effective_target, a.base_target_amount)::numeric(18,2) as effective_target,

  coalesce(ba.balance,0)::numeric(18,2) as current_bank_balance,
  coalesce(pp.pending_reserved_payments,0)::numeric(18,2) as pending_reserved_payments,

  greatest(
    coalesce(ba.balance,0) - coalesce(pp.pending_reserved_payments,0),
    0
  )::numeric(18,2) as operational_available,

  coalesce(r.recoverable_draws,0)::numeric(18,2) as recoverable_draws,
  coalesce(r.allocated_restorations,0)::numeric(18,2) as allocated_restorations,
  coalesce(r.outstanding_recovery,0)::numeric(18,2) as outstanding_recovery,

  greatest(
    coalesce(t.effective_target, a.base_target_amount) - coalesce(ba.balance,0),
    0
  )::numeric(18,2) as target_gap,

  case
    when coalesce(t.effective_target, a.base_target_amount) = 0 then 0
    else round(
      coalesce(ba.balance,0)
      * 100.0
      / coalesce(t.effective_target, a.base_target_amount),
      1
    )
  end as coverage_percent,

  coalesce(eb.expected_ledger_balance, a.opening_balance)::numeric(18,2) as expected_ledger_balance,
  coalesce(eb.unreconciled_difference,0)::numeric(18,2) as unreconciled_difference,

  coalesce(oe.unclassified_debit,0)::numeric(18,2) as unclassified_debit,
  coalesce(oe.unclassified_credit,0)::numeric(18,2) as unclassified_credit,

  coalesce(oe.open_exception_count,0)::integer as open_exception_count,
  coalesce(oe.control_exception_count,0)::integer as control_exception_count,
  coalesce(i.integrity_issue_count,0)::integer as integrity_issue_count,

  ls.snapshot_at as latest_snapshot_at,

  case
    when a.status <> 'Active' or a.reconciliation_enabled = false
      then 'SHADOW_NOT_ACTIVE'
    when coalesce(oe.control_exception_count,0) > 0
      or coalesce(i.integrity_issue_count,0) > 0
      then 'CONTROL_EXCEPTION'
    when abs(coalesce(eb.unreconciled_difference,0)) = 0
      and coalesce(oe.open_exception_count,0) = 0
      then 'RECONCILED'
    when abs(coalesce(eb.unreconciled_difference,0)) <= a.tolerance_amount
      and coalesce(oe.open_exception_count,0) = 0
      then 'RECONCILED_WITH_TOLERANCE'
    else 'REVIEW_REQUIRED'
  end as reconciliation_status

from public.reserve_reconciliation_accounts a
join public.bank_accounts ba
  on ba.id = a.bank_account_id
left join public.reserve_target_position_v2 t
  on t.reconciliation_account_id = a.id
left join recovery r
  on r.reconciliation_account_id = a.id
left join pending_payments pp
  on pp.reconciliation_account_id = a.id
left join public.reserve_expected_balance_v2 eb
  on eb.reconciliation_account_id = a.id
left join open_exceptions oe
  on oe.reconciliation_account_id = a.id
left join integrity i
  on i.reconciliation_account_id = a.id
left join latest_snapshot ls
  on ls.reconciliation_account_id = a.id
 and ls.rn = 1;

comment on view public.reserve_reconciliation_summary_v2 is
'Consolidated Shadow Mode summary tying Effective Target, actual bank balance, reserved payments, recovery ledger and unreconciled variance.';

-- ============================================================================
-- 17. VIEW ACCESS
--    Views remain inaccessible to current portal roles until governed V2 RPCs
--    are intentionally added in a separate migration.
-- ============================================================================

revoke all on table public.reserve_target_position_v2 from public, anon, authenticated;
revoke all on table public.reserve_draw_status_v2 from public, anon, authenticated;
revoke all on table public.reserve_movement_ledger_v2 from public, anon, authenticated;
revoke all on table public.reserve_balance_snapshot_analysis_v2 from public, anon, authenticated;
revoke all on table public.reserve_expected_balance_v2 from public, anon, authenticated;
revoke all on table public.reserve_reconciliation_integrity_v2 from public, anon, authenticated;
revoke all on table public.reserve_reconciliation_summary_v2 from public, anon, authenticated;

grant select on table public.reserve_target_position_v2,
                      public.reserve_draw_status_v2,
                      public.reserve_movement_ledger_v2,
                      public.reserve_balance_snapshot_analysis_v2,
                      public.reserve_expected_balance_v2,
                      public.reserve_reconciliation_integrity_v2,
                      public.reserve_reconciliation_summary_v2
to service_role;

commit;

-- ============================================================================
-- END
--
-- REVIEW NOTE
--   Executable SQL in this reviewed copy is intentionally unchanged from the
--   original file. Only comments/documentation were expanded to state the
--   bank_accounts / payments / profiles dependencies precisely.
--
-- NEXT SAFE PHASE (NOT INCLUDED HERE)
--   1. Seed V2 configuration in Shadow Mode.
--   2. Create approved Opening Reconciliation records.
--   3. Create governed SECURITY DEFINER read RPCs for CFO/Supervisor.
--   4. Compare V1 and V2 without switching the current dashboard.
--   5. Add controlled write APIs only after acceptance.
-- ============================================================================


-- ============================================================================
-- FINAL DEPENDENCY / NON-MODIFICATION NOTE
--
-- This V2 script is additive-only with respect to the current production model.
-- It does not ALTER bank_accounts, payments, or profiles; it does not INSERT,
-- UPDATE, or DELETE their data; and it does not CREATE, REPLACE, ALTER, or DROP
-- any existing Function.
--
-- Documented dependencies:
--   * public.bank_accounts:
--       - referenced by V2 Foreign Keys;
--       - read by V2 Views for bank metadata and balances.
--   * public.payments:
--       - read by V2 Views for pending-reserved-payment calculations.
--   * public.profiles:
--       - referenced by V2 audit/approval user Foreign Keys.
--
-- These dependencies may create normal PostgreSQL referential/schema dependency
-- behavior (for example, preventing deletion of referenced rows/columns while
-- dependent V2 objects exist), but they do not change the existing table
-- definitions, business data, workflows, or application logic.
-- ============================================================================