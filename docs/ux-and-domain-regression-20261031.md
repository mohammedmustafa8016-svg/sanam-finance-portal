# Domain experience and regression completion

The eight-workspace navigation is now extended through the existing domain screens. Treasury, payment stages, close, imprest, performance and governance receive a shared visual hierarchy, contextual guidance, and source-derived counts where meaningful. Existing actions and server authorization remain authoritative.

`workspace-experience.js` and its stylesheet are an independent presentation module. They do not change financial state, add a ledger, duplicate linked tasks, or make readiness an approval requirement. Monthly close and imprest settlement already link to real tasks; their existing handlers are retained.

Each domain table has a bounded search of its loaded, visible business cells, an accessible result count, a no-match recovery message, and up to eight explicitly saved search views. Views are per user, table and device, not shared server presets. Search never reveals rows suppressed by the native filters, ignores action labels and hidden columns, and survives a normal table refresh. User changes clear the current search. A failed browser-storage write reports failure. The original totals and exports follow their original filters; the UI says so explicitly.

The design uses the existing light/dark tokens, RTL/LTR layout, navy and gold hierarchy, responsive controls, keyboard focus and print exclusions. Wide financial tables scroll inside their container. Destructive controls and confirmation flows are preserved.

## Verification

The new browser regression uses the actual page, renderers and existing add forms with synthetic data. It checks all seven page-access roles; user-specific saved views; hidden-column search isolation; native filter coexistence; rerender recovery; escaped business text; both languages; six domains in both themes on mobile; and print. The existing five browser suites remain required.

`finance-domains-lifecycle.sql` adds rollback-only tests against the complete disposable Supabase build: seven-role sensitive API denial cases; payment approval/execution/registration/final posting; bank reservation and exactly-once debit; funding credited only after execution; imprest settlement-to-task linkage, independent review and ledger; and monthly close idempotent release and completion. The fixture adds a real Viewer test identity. A synthetic-email guard prevents this test from running against a populated team database.

The full baseline and current clean rebuilds must pass before this change is integrated into main. No migration is added. The previous production deployment remains the UI rollback target.

## Remaining scope

This closes a concrete domain-screen redesign and expands real database regression. It does not certify complete security coverage for every legacy RPC, backup/PITR restoration, sustained production latency, BC mapping with company exports, external monitoring, or server-enforced readiness policy. It also does not claim every old inline function has been extracted from index.html.

The release pipeline still needs a true deployment prerequisite; tests running on main are not themselves a deployment lock. These items remain tracked separately from this UI release.
