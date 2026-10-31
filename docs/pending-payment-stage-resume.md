# Pending-payment follow-up and stage-aware resumption

## Confirmed defect

Both the old UI action and `resolve_payment_pending_and_register` admitted only GLAccountant. This stranded a Supervisor/CFO hold raised after accounting registration. The old backend also allowed a GL user to clear that manager hold. Read-only production inspection found 15 active holds: six before registration and nine after registration, with both full and partial holds represented. No existing payment was resolved during diagnosis or deployment.

## Resulting sequence

1. Executed, not registered: GL can hold the payment, then document the solution and complete registration.
2. Registered, not posted: Supervisor/CFO can hold the payment, then document the solution and release the hold back to registered/final-review status. GL cannot clear this management hold.
3. Final posting remains the existing separate Supervisor/CFO action. Releasing a hold does not post or execute a payment.

Full and partial holds use the same stage rule. Resumption clears the held amount and restores registered_amount to the unchanged payment total. It preserves previous registration identity/time when present, all execution fields, original hold details and the resolution note. The previous held amount is recorded in audit before being cleared. This is not incremental partial posting or a new accounting transaction.

The new resume and follow-up APIs lock the payment row and require its exact updated_at. Stale data, double submissions, inactive users, missing permission, wrong role/stage, invalid amounts and posted/non-held records are rejected on the server. The previous GL API remains compatible for its pre-registration stage and routes through the new checks.

Supervisors/CFO can separately update the required action, active finance owner and follow-up date with a reason. This changes no payment amounts or state. The history API returns the latest 50 hold/resolution/follow-up events to authorized finance readers; no anonymous or Viewer access is granted. Resolved payments retain their history action on the executed list.

## Verification and release

- New fixture browser regression covers all seven roles, pre/post-registration actions, short-note rejection, stale data, exact microsecond version, double submission, history text escaping, follow-up, no automatic bank/posting request, English and mobile.
- New rollback-only SQL tests exercise real functions for both stages and full/partial holds, seven-role denials, preservation of bank/registration/execution, stale-version rejection, follow-up invariants, repeated hold cycles, historical evidence, explicit final posting, inactive and anonymous denial.
- The baseline comparison remains the previous 73 migrations. The new test is skipped only when its migration is absent; current clean rebuild includes all 76 migrations. Existing suites remain required.
- Apply only the forward function migration to the hosted databases after CI succeeds. This migration does not rewrite held payments. Verify unchanged business-table fingerprints and save the former function definition/ACL for rollback. Deploy the matching UI only after the backend exists.
- Do not solve the nine existing management holds automatically. Their documents and resolution notes must be reviewed by the responsible team member.
