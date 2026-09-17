# Notifications and portal theme

## Findings and changes

The previous notification dialog used the last 50 cached notifications; opening it did not refresh the list. Its unread count was therefore only a partial count, and the Work Center button had no unread badge. The open-task action ignored mark-read errors and silently stopped when the task was not in the local task array.

The inbox now queries a recipient-scoped RPC at open time, shows full unread counts independently of pagination, provides current-cycle/history and unread-only filters, and displays 30 items per page. Current-cycle notifications require both a timestamp after activation and current task membership (or no linked task). Everything else remains in previous history. No notifications are deleted. Reading is separate from task completion/approval. The header and Work Center badges refresh on data reload, every 30 seconds while visible, and when returning to the tab. Errors are explicit; they are not represented as an empty successful response.

Opening a linked task fetches it under the current user's RLS before marking the recipient's notification as read. Unavailable tasks produce a visible explanation. The original recipient-scoped mark-read function remains in use. Signing out/losing a session closes the inbox and discards its visible cached content.

Dark is the initial theme, with a persisted light/dark switch. Shared cards, tables, controls, dialogs, task drawers and notification surfaces use semantic colors. Financial KPI cards use a responsive grid so amounts do not wrap mid-number. Printing uses a light palette. Financial formulas and historical performance are unchanged.

## Validation

- notification-inbox-v6.sql: run inside BEGIN/ROLLBACK; verifies counts beyond 50, pagination, history separation, ownership and anonymous denial. Test notifications are rolled back.
- portal-experience-browser.cjs: local fixtures block external requests; checks counts, pagination, unread state, mark errors, linked-task access/missing task handling, refresh errors, theme persistence, languages, desktop/mobile and print colors.
- Existing Work Center browser regression suite passes.

The new authenticated SECURITY DEFINER read function is intentionally privileged to read the private cycle boundary; it checks active identity and constrains every notification to auth.uid(). Public and anonymous execution are revoked.

## Suggested next phase (not implemented)

An executive summary with source links, natural-language questions over approved metrics, and evidence-backed exception explanations could help managers. Compute monetary totals and ratios deterministically in the database; let the model explain the authorized results. Use a server-held API key, user-scoped queries and explicit provenance. Start read-only with no autonomous financial approvals. This release makes no AI calls and sends no finance data to an AI provider.

Reference patterns: https://carbondesignsystem.com/data-visualization/dashboards/ and https://learn.microsoft.com/en-us/power-bi/create-reports/copilot-pane-summarize-content.

