# Review and integration plan preserving the running deployment

This change prepares review and tests only. It does not promote a deployment,
connect to a hosted database, merge into main, reset a live database, or rewrite
hosted migration history. All data mutations in the regression jobs target
disposable loopback Supabase stacks.

## Review order

1. Review PR #42 (`fix-legacy-workflow-yaml-20261026` into
   `fix-seed-permissions-migration-20261026`). It fixes legacy YAML indentation
   and adds a validator that parses YAML and compiles embedded Python without
   running either historical patch/push workflow. Its application/schema
   contents are unchanged.
2. Once approved, integrate that CI-only change into the seed review branch and
   rerun its local gates. This document does not authorize or automate a merge.
3. Review PR #41 (`fix-seed-permissions-migration-20261026` into
   `migration-parity-rebuild`). Review migration 73, its preserved function
   behavior/ACLs, the local gate evidence, and the real browser task lifecycle.
4. Treat integration from parity into main as a separate reconciliation review.
   Do not retarget PR #41 directly to main or auto-deploy the parity history.

## Repository comparison

Snapshot inspected on 26 October 2026:

| Reference | Commit | Migration files |
|---|---|---:|
| main | `03277b03babfc06bf24b34446085e4e245371919` | 55 |
| migration-parity-rebuild | `4a3167a9d54fd3e2d6a50dbd286289ec142bb0f5` | 72 |
| seed review branch | parity plus the seed function migration | 73 |

Main is an ancestor of the parity branch. Of its 55 migration files, 47 have an
exact Git blob/content match in the parity sequence, generally under canonical
timestamp names. Eight main files have no exact whole-file content match, and
25 parity files have no exact main content match. Splits, consolidations or
semantic equivalence require review; these counts do not establish that any
feature was removed or that a hosted database is missing migrations.

The repository filenames are not proof of the running database's applied
migration history. A fresh-build success alone does not validate replaying
bootstrap/schema migrations against an existing populated database.

## Separate live-upgrade readiness review

Before any later production release:

1. Identify the exact deployed application revision and read the hosted
   migration ledger and the current seed function definition/ACLs in read-only
   mode. Compare these with the canonical manifest. No hosted metadata was
   read or altered by the work described here.
2. Verify the backup/PITR coverage and demonstrate restoration to a separate
   isolated staging database. This work does not claim that a current live
   backup has been created or verified.
3. On that restored staging copy, reconcile the eight unmatched main files and
   the additional canonical entries. Prepare a reviewed, forward-only upgrade
   plan for the actual applied state. Do not automatically run a fresh reset,
   all 73 migrations, or migration-history repair on the live database.
4. Record before/after row counts and integrity checks for profiles,
   permissions, tasks, payments, balances, notifications and audit history.
   Confirm existing permission overrides remain intact. Run Security, RLS and
   the populated browser lifecycle on staging.
5. Review the resulting SQL diff and explicit release/rollback procedure.
   Require separate approval for any live database write or promotion to the
   running deployment. Keep the previous application release available.

The seed migration uses CREATE OR REPLACE FUNCTION and EXECUTE grants; it does
not delete or reseed existing business rows. Its conflict handling preserves
manual permissions. That narrow behavior does not eliminate the need to
reconcile the broader parity history before a future main/production rollout.

## Browser lifecycle data preservation check

The added local browser scenario creates two synthetic tasks through the UI.
It starts and submits only the target task as BankAccountant, reviews it as
Supervisor with score 94, and deletes it as CFO with a typed confirmation and
reason. It verifies persisted task states, removal of target work items and
retention of the CFO audit snapshot. A separate existing synthetic task must
retain every task field unchanged after target deletion. All of this happens
on the local disposable stack, which is discarded after CI.
