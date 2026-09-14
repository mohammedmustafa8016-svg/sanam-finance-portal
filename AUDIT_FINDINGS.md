# Sanam Finance Portal — Audit Findings

Audit started 2026-09-14.

## Confirmed working / repaired
- Supabase RLS is enabled on all core public tables.
- Full payment state flow was executed inside a rollback-only transaction: Supervisor approval -> CFO approval -> Bank execution -> GL posting.
- Negative/unauthorized workflow tests passed: BankAccountant blocked from supervisor approval; Supervisor blocked from CFO approval and bank execution.
- `private.is_cfo()` and `private.is_supervisor_or_delegate()` were repaired to call `private.current_role()` rather than a non-existent `public.current_role()`.
- `create_leave_exception` RPC was restored and tested: CFO allowed; non-CFO denied.
- Duplicate add-button event listeners causing `[object PointerEvent]` UUID failures were removed.
- Negative amount formatter recursion was repaired; negative values retain bold red formatting.

## Confirmed regressions / gaps in current cloud UI
- Full Arabic / English switching is absent in current cloud UI.
- Payment reporting UI previously approved is absent.
- Payment report date filters / selectable columns / export are absent.
- Outbound report email integration is not operational.
- Audit Log UI currently references non-existent fields (`actor_email`, `entity`) instead of database fields (`actor_id`, `entity_type`); actor display requires a join to profiles.
- `ownership_matrix`, `team_performance`, `monthly_close_tasks`, `tasks`, `imprest_funds`, exceptions and leave tables currently have no operating data, so empty-state rendering works but populated behavior needs automated fixtures.
- Only CFO, Supervisor and BankAccountant have activated Auth/Profile accounts at audit time; GL, AR and AP are approved in `allowed_users` but have not activated accounts.

## Security / control item requiring CFO approval before behavior change
- The payments UPDATE RLS policy is broad enough to allow several finance roles to issue direct updates to payment rows. Workflow transitions are protected by RPCs in the UI, but the RLS policy itself should be hardened before a production-grade release. Tightening it may alter existing edit behavior, so it is not changed without approval.

## Release policy
No further feature or bug fix should be pushed directly to production. Changes must pass protected baseline regression tests on a development/preview branch first.
