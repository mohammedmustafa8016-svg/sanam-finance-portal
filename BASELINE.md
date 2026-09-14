# Sanam Finance Portal — Protected Baseline

This file defines functionality that must not be removed or changed incidentally by bug fixes.

## Core modules
- Dashboard
- Liquidity & Banks
- Payments & Approvals
- Posted Payments
- Tasks
- Monthly Close
- Imprest
- Team Performance
- Ownership Matrix
- Exceptions & Leave Delegation
- CFO Audit Log

## Roles
- CFO
- Supervisor
- BankAccountant
- GLAccountant
- ARAccountant
- APAccountant

## Payment workflow
1. Payment creation
2. Supervisor approval
3. CFO approval
4. Bank Accountant execution
5. GL Accountant posting
6. Posted items leave active follow-up and appear under Posted Payments

## Protected controls
- Supervisor approval can only be completed by Supervisor or an approved active delegate.
- CFO approval can only be completed by CFO.
- Execution can only be completed by Bank Accountant or CFO fallback currently implemented in backend.
- Posting can only be completed by GL Accountant or CFO fallback currently implemented in backend.
- Reserved bank balance is system-calculated from unexecuted payments and is not manually editable.
- Negative financial values display in bold red.
- CFO-only Audit Log.
- CFO-only creation of exceptions / leave delegations.

## Previously approved capabilities to be restored and regression-protected
- Full Arabic / English interface support.
- Professional payment report with date filtering and selectable columns.
- Export of the payment report.
- Report preparation for emailing; outbound email delivery remains dependent on SMTP/email integration.
- Role-based page visibility and granular workflow permissions.

## Change control
Production changes must preserve this baseline. Any change to an approved business rule, permission, workflow, page or report requires explicit CFO approval before production deployment.
