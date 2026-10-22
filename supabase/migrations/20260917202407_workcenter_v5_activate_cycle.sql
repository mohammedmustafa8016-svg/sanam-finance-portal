-- Operational reset only. No task, payment, activity or performance record is deleted.
-- Run once after V5 validation and immediately before the frontend production release.
lock table public.work_items in share row exclusive mode;
insert into private.workcenter_cycles(label,started_at,active,baseline)
select 'دورة التشغيل الجديدة',clock_timestamp(),true,jsonb_build_object(
 'reason','User-approved Work Center test reset; historical data retained',
 'tasks',(select count(*) from public.tasks),
 'payments',(select count(*) from public.payments),
 'work_items',(select count(*) from public.work_items),
 'finance_activity_log',(select count(*) from public.finance_activity_log),
 'scored_tasks',(select count(*) from public.tasks where quality_score is not null)
)
where not exists(select 1 from private.workcenter_cycles where active);

