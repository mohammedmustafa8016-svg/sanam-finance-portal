-- Apply the Friday/Saturday task calendar to timing/overdue read models.
do $patch$
declare
  r record;
  v_def text;
  v_new text;
begin
  for r in
    select p.oid,n.nspname,p.proname
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname in ('public','private')
      and p.proname in (
        'resolve_workcenter_rule',
        'get_workcenter_dashboard_v5',
        'get_readonly_workcenter_dashboard_v1',
        'get_workcenter_items',
        'get_workcenter_items_v4',
        'get_finance_team_performance',
        'get_finance_team_kpi_report',
        'get_employee_performance_report_v4',
        'get_workflow_v3_performance',
        'get_team_operations_monitor_v4',
        'get_supervisor_control_center',
        'get_workload_capacity',
        'get_escalation_center',
        'get_readonly_dashboard_snapshot',
        'get_readonly_page_snapshot'
      )
  loop
    v_def:=pg_get_functiondef(r.oid);
    v_new:=v_def;

    v_new:=replace(v_new,'w.due_at<now()','private.task_effective_due_at(w.due_at)<now()');
    v_new:=replace(v_new,'b.due_at<now()','private.task_effective_due_at(b.due_at)<now()');
    v_new:=replace(v_new,'w.completed_at<=w.due_at','w.completed_at<=private.task_effective_due_at(w.due_at)');
    v_new:=replace(v_new,'w.completed_at>w.due_at','w.completed_at>private.task_effective_due_at(w.due_at)');
    v_new:=replace(v_new,'coalesce(review_requested_at,completed_at)<=due_at',
                         'coalesce(review_requested_at,completed_at)<=private.task_effective_due_at(due_at)');
    v_new:=replace(v_new,'t.due_date=c.today','private.task_effective_due_date(t.due_date)=c.today');
    v_new:=replace(v_new,'due_date=c.today','private.task_effective_due_date(due_date)=c.today');
    v_new:=replace(v_new,'due_date=v_today','private.task_effective_due_date(due_date)=v_today');
    v_new:=replace(v_new,'due_date<v_today','private.task_effective_due_date(due_date)<v_today');
    v_new:=replace(v_new,'floor(extract(epoch from (due_at-now()))/60)',
                         'private.task_business_minutes_between(now(),private.task_effective_due_at(due_at))');
    v_new:=replace(v_new,'floor(extract(epoch from(co.due_at-now()))/60)::int',
                         'private.task_business_minutes_between(now(),co.due_at)::int');
    v_new:=replace(v_new,'floor(extract(epoch from (b.due_at-now()))/60)::bigint',
                         'private.task_business_minutes_between(now(),private.task_effective_due_at(b.due_at))');
    v_new:=replace(v_new,'floor(extract(epoch from (b.due_at-coalesce(b.task_assigned_at,b.created_at)))/60)::bigint',
                         'private.task_business_minutes_between(coalesce(b.task_assigned_at,b.created_at),private.task_effective_due_at(b.due_at))');
    v_new:=replace(v_new,'floor(extract(epoch from (coalesce(b.completed_at,now())-b.started_at))/60)::bigint',
                         'private.task_business_minutes_between(b.started_at,coalesce(b.completed_at,now()))');
    v_new:=replace(v_new,'(b.due_at at time zone ''Asia/Riyadh'')::date=c.today',
                         '(private.task_effective_due_at(b.due_at) at time zone ''Asia/Riyadh'')::date=c.today');
    v_new:=replace(v_new,'greatest(0,floor(extract(epoch from(now()-issue_since))/60)::int)',
                         'greatest(0,private.task_business_minutes_between(issue_since,now())::int)');

    if v_new<>v_def then execute v_new; end if;
  end loop;
end
$patch$;
