# Remaining phases — 31 October 2026

This branch implements reviewable increments of the user's approved Sanam plan. It is **not a certified production release**. The user authorized completing the work and applying the tested upgrade to the team deployment; no additional general permission is required. Missing access and missing verification are technical prerequisites, not a request to reconfirm the scope.

## Implemented

- Eight existing workspaces from PR #43 are retained with their page authorization.
- Home now presents permission-filtered approval, overdue work, review, close, reserve and imprest follow-ups with direct navigation. It derives indicators from the existing loaded data, not an independent accounting ledger. Viewer does not receive the new operational feed.
- Work Center's duplicate refresh is removed; a browser assertion checks one refresh per action. The set-based dashboard candidate from PR #40 is formalized as a migration. Its production performance has not been remeasured in this session.
- CSV UTF-8 imports provide explicit column/number-format mapping, strict ISO dates, preview/confirmation, limits, stable BC identity and company/type scoping. PostgreSQL validates again and applies each batch atomically. Reimports insert, update or leave unchanged; every changed source record retains its before/after payload in audit. No inferred currency conversion or date interpretation occurs.
- Mirrored bank balances, payables and posted documents are read-only references. They do not overwrite operational balances. An authorized employee can create a SAR payment request from a payable by selecting the execution account and priority; accounting data is read from the server copy of BC, not retyped. Source identity and company/document/beneficiary prevent duplicate linked requests. A later import never silently changes an existing payment request. Non-SAR requests require a currency-aware workflow and are refused.
- Twelve initial expense policies support required document references, conditional requirements, warnings and readiness blockers. CFO can change requirements, severity and an optional amount threshold, with version conflict protection and audit. The server derives threshold conditions. Duplicate supplier invoice references and expired-contract flags block readiness. Document references are user attestations, not automatic inspection of physical attachments. This is operational readiness; it does not replace existing payment approval or BC accounting posting controls.
- A saved readiness result is recomputed against the current policy and current payment. Editing inputs clears the displayed result. The UI clearly distinguishes preview from an audit save.
- Delay attribution requests require an explicit interval, explanation and evidence reference. Independent CFO/Supervisor review is mandatory; requester and employee cannot approve their own attribution. Decisions are immutable. Approved overlapping non-employee intervals are unioned before adding elapsed time to the current due date. Existing extensions are already reflected in the due date and are not subtracted again. Pending reviews yield provisional timing, not automatic credit. Original timing, rework and quality remain available. Missing quality is not zero. Attribution history survives deletion of a work item.
- The employee report exposes the method, excluded duration, original/adjusted deadline and provisional outcomes. Printing removes interactive controls and retains the explanation. The existing date range supports monthly, quarterly and annual requests without inventing a composite score.
- Application health records only generic error codes and page identifiers, with client and server rate limits. It does not send raw messages, stack traces, file contents, URLs or credentials. The authorized health view shows error aggregates, pending delay decisions and latest import timestamps. This does not replace provider/server monitoring.
- Deployment runtime configuration requires explicit isolated Supabase settings for previews and refuses production fallback and server/secret keys in a browser config. Production retains the existing endpoint until explicitly configured. The three existing private helper search paths identified by the preview security advisor are pinned without changing their function bodies.

## Local evidence

PASS: `tests/operations-core.cjs`.

PASS: `tests/governed-controls-database.cjs` using pinned PGlite 0.3.14, a real embedded PostgreSQL instance with a minimal existing-schema contract fixture. It validates migration DDL, permissions, atomic/idempotent import, source-linked requests, readiness, policy revisions, independent delay review, interval union, deletion history and inactive/unauthorized caller rejection. The fixture's V4 report is a stub; this is not a replacement for the full Supabase integration test.

PASS: five fixture browser suites: operations platform, workspace navigation, Work Center, notification/theme and CFO deletion. All external browser requests were blocked. No production requests or data writes occurred in those tests.

PASS: JavaScript/Python syntax, workflow YAML parsing and whitespace checks. Desktop/mobile screenshots inspected.

## Prepared, not yet run

`remaining-phases-gates.yml` runs the new contract/browser tests, then complete disposable Supabase rebuilds for current (75 migrations) and baseline (previous 73) plus existing real Auth/PostgREST browser lifecycle. The new `governed-operations-controls.sql` exercises the actual new functions on the local Supabase stack. Existing SQL tests, role checks and a Work Center <2s gate run there too.

At preparation time these CI jobs had **not run**; their latest results must be checked on the review commit. Docker is not available on the local machine. GitHub connector access recovered after initial failures, so the branch can be uploaded through the connector. Vercel lists the projects but rejects team-scoped reads with 403 pending team consent. Supabase exposes only the separate `lpanqnuwmeusmygzhcxm` preview (73 migrations, one profile, zero payments/tasks); access to the running `xpomwrpgxnjxabjnwnuz` database was denied. This is why live metadata parity and deployment success are not claimed.

## Release prerequisites still open

1. Obtain current/baseline CI artifacts from the review branch. Grant Vercel team access and Supabase access to the actual running database.
2. Verify the actual deployed revision and hosted migration ledger in read-only mode. Main remains at `03277b03babfc06bf24b34446085e4e245371919`; the last independently checked PR #43 was still open. Do not assume the parity branch is deployed.
3. Verify backup coverage and restore a current backup into isolated staging. A local Git bundle is only source recovery, not a database backup.
4. Apply only the reviewed forward upgrade to that staging copy. Reconcile the actual hosted ledger; do not replay the renamed parity bootstrap chain against existing data and do not reset the live database.
5. Compare before/after row counts, totals and permission overrides; run populated payments, banks, reserve, imprest, close, performance and full Security/RLS role regression. Use a representative real BC export to verify field mapping and totals, including the first source-to-request reconciliation.
6. Stage the production build, test that exact build against the verified upgrade, then promote it. Keep the previous application deployment available. Database rollback must preserve all newly created imports, links, assessments and attribution history; do not drop the new tables as a routine rollback.
7. Observe API errors, Work Center latency, approval throughput and import/review errors after promotion. Existing automation health remains available; external deployment monitoring configuration could not be inspected.

## Hosted isolated preview upgrade — 31 October 2026

After explicit autonomous execution authorization, both migrations were applied to the existing isolated preview `lpanqnuwmeusmygzhcxm`. Its ledger now contains 75 entries (Supabase-generated hosted version timestamps differ from canonical repository filenames; no history rewrite was performed). The existing profile count stayed 1, payments/tasks stayed 0, and rollback-only authenticated smoke tests left zero imported records/batches or audit rows behind. Twelve readiness policies and all new RPCs exist, all six new tables have RLS, and client execution of internal permission seeding is denied. Hosted authenticated RPC checks passed for policies, idempotent import, source reading, the real performance report and operational health. The mutable helper search-path warnings disappeared.

`release/preview-environment.json` declares only the known isolated preview URL and its public publishable key so Git previews can build without a production database fallback. It is used only when `VERCEL_ENV=preview`; production ignores it. It contains no service-role or secret key. The Git integration deployment and technical access to the running environment still require verification.

No production deployment, production migration, production backup creation or production restore rehearsal is claimed by this change.
