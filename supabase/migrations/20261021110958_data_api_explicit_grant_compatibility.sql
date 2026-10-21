-- Supabase Data API explicit-grant compatibility layer.
-- Purpose: keep fresh rebuilds / preview branches / db reset functional after the
-- 2026-10-30 Supabase change that stops auto-granting Data API table privileges.
--
-- SAFETY:
-- * GRANT-only migration: no REVOKE, no RLS changes, no policy changes, no data changes.
-- * Production effective permissions remain unchanged because these privileges are
--   already present in the current production database.
-- * anon receives no new privileges.
-- * authenticated receives only the direct table privileges required by the current UI.
-- * service_role receives ordinary CRUD access for backend/API compatibility.

-- Direct client reads.
grant select on table
  public.profiles,
  public.tasks,
  public.leave_delegations,
  public.ownership_matrix,
  public.audit_log
to authenticated;

-- Direct client read + create.
grant select, insert on table
  public.payments,
  public.exceptions,
  public.monthly_close_tasks,
  public.imprest_funds
to authenticated;

-- Bank account creation/editing is direct in the current UI; reads use governed RPCs.
grant insert, update on table
  public.bank_accounts
to authenticated;

-- Backend compatibility for the same directly-used tables.
grant select, insert, update, delete on table
  public.profiles,
  public.payments,
  public.tasks,
  public.exceptions,
  public.leave_delegations,
  public.monthly_close_tasks,
  public.imprest_funds,
  public.ownership_matrix,
  public.bank_accounts,
  public.audit_log
to service_role;
