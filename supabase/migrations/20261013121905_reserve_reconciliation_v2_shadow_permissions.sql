
-- Reserve Reconciliation V2 shadow permission normalization.
-- New V2 objects only. No existing production table/function/UI is modified.

revoke all on table
  public.reserve_reconciliation_accounts,
  public.reserve_target_ledger,
  public.reserve_reconciliation_movements,
  public.reserve_restoration_allocations,
  public.reserve_balance_snapshots,
  public.reserve_reconciliation_exceptions,
  public.reserve_v2_opening_reconciliations
from service_role;

grant select, insert, update, delete on table
  public.reserve_reconciliation_accounts,
  public.reserve_target_ledger,
  public.reserve_reconciliation_movements,
  public.reserve_restoration_allocations,
  public.reserve_balance_snapshots,
  public.reserve_reconciliation_exceptions,
  public.reserve_v2_opening_reconciliations
to service_role;

revoke all on table
  public.reserve_target_position_v2,
  public.reserve_draw_status_v2,
  public.reserve_movement_ledger_v2,
  public.reserve_balance_snapshot_analysis_v2,
  public.reserve_expected_balance_v2,
  public.reserve_reconciliation_integrity_v2,
  public.reserve_reconciliation_summary_v2
from service_role;

grant select on table
  public.reserve_target_position_v2,
  public.reserve_draw_status_v2,
  public.reserve_movement_ledger_v2,
  public.reserve_balance_snapshot_analysis_v2,
  public.reserve_expected_balance_v2,
  public.reserve_reconciliation_integrity_v2,
  public.reserve_reconciliation_summary_v2
to service_role;
