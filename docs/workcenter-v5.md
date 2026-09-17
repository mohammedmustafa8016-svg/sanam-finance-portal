# Work Center V5

The Work Center now separates current operations from retained history. A private operating cycle defines which work items appear. Activating the cycle does not delete or update source tasks, payments, performance results or activity logs. Existing historical reports remain available and retain their current formulas.

## Queues and metrics

- Management defaults to team scope; employees only see their own authorized assignments/reviews.
- Execution: Ready, Assigned, Started or In Progress work that is not an approval stage.
- Reviews: submitted task results, extension requests and active supervisor/CFO payment approval stages.
- Attention: Blocked, Paused, Returned for Rework, or overdue open work.
- Completed: approved/completed work within the selected completion-date range and current cycle.
- Overdue is an overlapping flag, not an additional unit of work. Never add all dashboard cards to obtain a total.
- Quality = arithmetic average of non-null scores on completed tasks. Unscored finance stages are excluded, and sample count is shown. No sample returns null, not zero.
- On-time = 100 × completed timed items submitted by their current approved deadline / completed items with a deadline. Task submission time is used when available to avoid charging reviewer delay to the employee. Approved extensions affect this metric; it is not original-deadline compliance.
- One work-item ID is counted once within a cycle. Distinct payment stages remain distinct units of work; their counts are not unique-payment counts and must not be presented as an annual weighted performance score.
- Team credit uses completed_by after completion and assignee_id while open.

All queue counts, drilldowns and team metrics use one dashboard response. Date filters apply to completions; open work remains visible. Role checks run on the server, and current-cycle membership is checked before V5 actions.

## History boundary

Existing work starts outside the new cycle. New source tasks/payments enter when their stage becomes active. For an existing payment, a newly activated stage or newly completed stage can enter; an unchanged synchronization cannot resurrect old work. Old manual tasks remain in historical modules.

The activation migration records baseline counts and its timestamp. No delete operation is used. Printing does not remove any history. The annual-performance model is unchanged by this release; historical score recalculation requires a separate agreed model.

## Validation

Database tests run in transactions ending with ROLLBACK, before activation:

- workcenter-v5.sql: role isolation, start, comment, blocker, extension, submission, self-review denial, rework, resume, scoring and duplicate prevention.
- workcenter-v5-payment-cycle.sql: historical sync exclusion, newly active payment stage, newly completed stage and restricted grants.
- workcenter-v5-plan.sql: CFO/Supervisor workday start, task API, template creation/reuse and visibility.

Browser tests use local fixtures and block external requests. They validate navigation, counts, filters, drilldowns, board/drawer, role controls, submission, required scoring, error recovery, request races, Arabic/English and mobile layout. They do not represent a logged-in production-browser test.

Local preview: run `node tests/serve-preview.cjs`, then run the browser test with Playwright available and Chrome installed (paths can be supplied using PLAYWRIGHT_PATH and CHROME_PATH). Test files and migrations are excluded from static hosting by .vercelignore.

Production rollout: apply the schema migration, validate, activate the new cycle once, then promote the frontend. For a frontend rollback, restore the previous frontend commit; the new schema is additive and source records remain intact. Do not delete cycle history as a rollback shortcut.

