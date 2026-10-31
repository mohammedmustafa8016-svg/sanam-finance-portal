# Sanam development plan: implementation status

The user's approved plan treats Sanam as a financial operations and control layer over Business Central. Accounting entries, vendors, customers, posted documents and accounting balances remain owned by BC. Dashboard owns tasks, operational approvals, responsibility, SLA, exceptions and performance. Enter once, use everywhere.

Historical checkpoint: 29 October 2026. The table below records the state at the workspace-only PR. **Current implementation and open release prerequisites are in [remaining-phases-implementation.md](remaining-phases-implementation.md).** Passing a regression gate does not establish completion of this product plan.

| Phase | Evidence / remaining work |
| --- | --- |
| 0 Baseline & safety | Existing recovery plan; backup availability and isolated restore rehearsal are not verified by this change. |
| 1 Reliability | Work Center optimization exists separately in draft PR #40. This branch does not integrate or promote it. |
| 2 Regression safety | Existing bounded local gates; this change adds navigation tests for all seven roles. Full populated module coverage remains incomplete. |
| 3 Migration parity | Base branch contains 73 migrations and previous clean rebuild evidence. No migrations changed here. |
| 4 Navigation consolidation | Implemented for review: eight workspaces, existing pages as permission-filtered tabs, preserved direct navigation and handlers. |
| 5 UX redesign | Initial workspace shell only. Home intervention summary and deeper workflow experience remain to implement. |
| 6 BC read-only integration | Not implemented. User selected exported files as the initial source. A representative BC export is needed to verify columns, stable record identity, company mapping, reconciliation and duplicate detection before importing. API integration is deferred. |
| 7 Smart readiness controls | Not implemented. Start with deterministic document requirements, conditional checks and warnings; this is operational readiness, not accounting posting in Dashboard. |
| 8 Performance system | Existing reports retained. Delay attribution, dependency exclusions and explainable historical evaluation remain to implement and verify. |
| 9 Operational quality gate | Added isolated navigation CI. Restore rehearsal, populated staging gates, release monitoring and approved rollback remain outstanding. |

## Workspace composition

- Home: existing dashboard.
- Work Center: work center, tasks, operations control, workload, escalations.
- Payments: requests/approvals, executed, pending, posted.
- Treasury & Banks: banks/liquidity and reserve monitoring. Reserve V2 engine retained.
- Imprest: existing funds, funding, settlement and ledger workspace.
- Monthly Close: existing close progress.
- Performance & Reports: existing employee evaluation and reports.
- Administration & Governance: ownership, exceptions/policies, users/permissions, automation, audit.

Each tab uses existing `canPage` authorization and existing `openPage`. A workspace appears only when at least one of its existing pages is accessible. Access is recalculated after permission changes. Existing sections and navigation nodes remain present for compatibility, with the old navigation visually hidden only once the new module initializes. Read-only Viewer continues through the existing read-only data loader.

## Validation performed locally

Browser requests were fulfilled directly from local repository files through `tests/offline-browser-preload.cjs`; all non-loopback origins were blocked. The fixture client is substituted only in tests. No production API or database was contacted.

- New navigation test: eight spaces, payment tabs, last permitted tab, direct navigation, keyboard, all seven roles, Viewer, Arabic/English, mobile overflow and print: PASS.
- Existing Work Center browser regression: PASS.
- Existing notification/theme/browser regression: PASS.
- Existing CFO deletion browser regression: PASS.

These are fixture browser checks, not a new database Security/RLS audit or evidence of BC synchronization. A draft review is not a production release.
