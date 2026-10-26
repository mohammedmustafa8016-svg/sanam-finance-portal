# Disposable local regression gates

The `Local Security RLS and UI gates` workflow runs only on
`fix-seed-permissions-migration-20261026`. Each matrix job starts its own local
Supabase stack and runs `supabase db reset --local --no-seed`.

`current` applies all 73 migrations. `baseline` omits only
`20261026095100_fix_seed_permissions_for_user.sql` and applies the previous 72.
Both run the identical harness and unchanged repository SQL/browser tests.
The baseline omission happens only in the disposable runner checkout.

## Reproduce

Use Linux, Docker, Node 22, Python 3 and Supabase CLI 2.122.0 in a disposable
checkout of this branch. Do not link a hosted Supabase project or supply remote
Supabase credentials.

```sh
npm ci --prefix tests/harness --ignore-scripts --no-audit --no-fund
tests/harness/node_modules/.bin/playwright install --with-deps chromium
supabase start
supabase db reset --local --no-seed
GATE_VARIANT=current python3 tests/harness/run-gates.py
supabase stop --no-backup
```

For a baseline comparison, use a second disposable checkout and omit only the
new migration before starting/resetting it. Set `GATE_VARIANT=baseline`.
The workflow does this automatically. Existing Actions runs can also be rerun.

## Isolation and fixture preconditions

- SQL is actually piped into `docker exec -i ... psql -X -v ON_ERROR_STOP=1`.
- The first assertion checks 73/72 migration history rows and empty Auth users,
  tasks and payments, before any test fixtures are created.
- Each SQL test and its synthetic users/data execute in a separate connection
  inside `BEGIN`/`ROLLBACK`. Assertions stop on SQL errors.
- Work Center SQL tests assume enabled Workflow V3 and rule engines. Their
  existing CFO activation APIs supply that precondition inside the rollback.
  Migrations intentionally leave those settings disabled by default.
- The three pre-activation V5 tests temporarily deactivate the existing cycle
  before they create their own test cycle. Historical tasks/payment stages
  required by those tests are synthetic fixtures, also rolled back.
- No function, policy, grant or schema is patched by the harness.
- Local UI integration creates synthetic users through local Auth Admin only.
  Its service key stays in the Node process; the browser receives only the
  local anon key. The entire stack is discarded after the job.

## Coverage and evidence

Security assertions cover RLS on exposed public tables, anonymous execution of
public SECURITY DEFINER functions, and the seed function's search path and ACLs.
Permissions assertions cover role defaults, preserving manual overrides and
direct authenticated RLS isolation. All five existing SQL tests also run.

All three existing browser scripts run unchanged with their local mock client.
They cover Work Center interactions, CFO delete controls, notifications,
themes, language and mobile behavior. These fixture tests do not access a DB.

A separate integration browser test uses the actual application, local Auth,
local PostgREST and the freshly rebuilt database. It checks CFO, Supervisor and
BankAccountant login, profile and permissions retrieval, empty-cycle Work
Center loading, employee task-button visibility, and page/API errors. All
external browser requests are blocked. Application source files are unchanged;
only the local HTTP response substitutes the Supabase URL/key and locally
installed browser client.

This is a bounded regression gate, not an exhaustive security audit or a
complete populated-database browser workflow test.

Each job uploads `local-gate-evidence-current` or `local-gate-evidence-baseline`
with migration manifests, reset logs, per-test logs, `results.json`,
`summary.md`, local integration details and screenshots. Every test runs even
if an earlier assertion fails, and the gate exits nonzero on any failure.

