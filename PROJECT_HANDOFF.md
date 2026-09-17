# Sanam Finance Portal — Project Handoff

Archive date: 2026-09-17

## Production baseline
- Repository: `mohammedmustafa8016-svg/sanam-finance-portal`
- Production branch: `main`
- Production baseline commit: `8a6fa42f1dccf157f6ea8069907aa5131209654a`
- Production URL: `https://sanam-finance-cloud-pilot-mohammedmustafa8016-6001.vercel.app`
- Vercel project: `sanam-finance-cloud-pilot`
- Supabase project: `Sanam Finance Portal`
- Supabase ref: `xpomwrpgxnjxabjnwnuz`

## Operating rule for future work
Treat this release as a protected baseline. New development must be additive. Do not delete or silently replace working features, workflows, permissions, historical data, filters, column customization, bilingual support, reports, or audit behavior. Regression-test all existing features before Production.

## Core capabilities delivered
- CFO financial & operations dashboard.
- Liquidity and bank account management.
- Protected reserve accounts: Working Capital Reserve / VAT Reserve / other restricted accounts.
- Target/reference balance, current balance, variance, recoverable and non-recoverable support draws, restoration tracking, reserve reports.
- Payments workflow with Supervisor/CFO approval, bank execution, GL registration, pending/posted handling, CFO status override and audit.
- Executed payments reduce bank balance automatically once, idempotently.
- Manual daily planning from reusable task templates; legacy automatic daily task generation disabled.
- Daily control, workload/capacity, blocker/escalation center, review-before-complete.
- Monthly close management.
- Imprest management.
- Team performance / KPI reporting with operational activity log and 48-hour payment accounting SLA.
- Finance policies register with versions and acknowledgements.
- Dynamic CFO access/visibility management.
- Universal table filtering with active-filter indicators.
- Universal column customization stored per user/device.
- Arabic/English support.
- Audit log.

## Key security / permission model
Balance/liquidity-sensitive pages and data are intended for CFO, Supervisor and Bank Accountant only. CFO manages page visibility using the permissions page. Finance workflows remain human-approved; no autonomous payment approval/execution/posting.

## Team roles
- `m.mustafa.acc@sanamint.sa` — Mohammed Mustafa — CFO
- `mohi@sanamint.sa` — محي الدين علي حسن — Supervisor
- `amrelshafeiy@sanamint.sa` — عمرو الشافعي — BankAccountant
- `fahadp@sanamint.sa` — فهد بشير — GLAccountant
- `m.elgendy@sanamint.sa` — محمد الجندي — ARAccountant
- `ashraf@sanamint.sa` — أشرف بابكر — APAccountant

## Daily planning
- `daily_plan_go_live_date = 2026-09-17`
- `auto_daily_generation_enabled = false`
- Legacy daily generation cron job is disabled.
- Daily tasks should be selected manually from templates or created ad hoc.

## Database recreation
All application schema changes used in the project are under `supabase/migrations/` in this archive. The archive does not contain a raw production database dump or user passwords. Production operational data remains in the live Supabase project referenced above.

## Deployment
The project is a static frontend deployed on Vercel, with Supabase as backend/auth/database. `vercel.json` and all migrations are included.

## Continuation in a new chat
Upload this archive and ask ChatGPT to continue from `PROJECT_HANDOFF.md`, treating the listed production commit and production database as the protected baseline.
