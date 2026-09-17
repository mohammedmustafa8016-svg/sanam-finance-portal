# CFO task deletion

Only an authenticated active CFO can permanently delete a task. The server checks the role using the profile-backed current_role() function. UI visibility is not treated as authorization.

Deletion is available from task actions, the task workspace and Work Center details for task-based items. It works for every task status. The user must type the exact task name and enter a reason of at least 10 characters. The action executes atomically.

Before deletion, audit_log receives the task record, reason, actor, deletion time, related counts, comments, activity, extension requests and work-item snapshots. The operational task, its Work Center membership/items, comments, notifications, extension requests and activity are then deleted through explicit cleanup and existing cascades. An imprest settlement keeps its financial record while its task_id becomes null under the existing foreign key. Payment workflows are outside this task-only operation.

The audit snapshot is retained and is not restored automatically. An audit-guided manual recovery would require a separate controlled procedure.

Validation uses transaction rollback fixtures for tasks in Ready/not-started, In Progress and Completed states. It verifies CFO-only access, exact confirmation, minimum reason, Work Center cleanup, cascades, audit completeness and anonymous denial. Browser coverage verifies visibility for CFO, absence for Supervisor, client validation and refresh after success.

