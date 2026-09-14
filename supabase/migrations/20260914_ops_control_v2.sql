-- Sanam Finance Portal - Operations Control V2
-- Adds workload/capacity, blocker/escalation, supervisor review, drill-down support and automation health.

alter table public.tasks add column if not exists blocker_note text;
alter table public.tasks add column if not exists blocker_since timestamptz;
alter table public.tasks add column if not exists review_requested_at timestamptz;
alter table public.tasks add column if not exists reviewed_at timestamptz;
alter table public.tasks add column if not exists reviewed_by uuid references public.profiles(id);
alter table public.tasks add column if not exists review_note text;

create table if not exists public.team_capacity_settings (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  capacity_tasks integer,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now(),
  constraint team_capacity_settings_capacity_check check (capacity_tasks is null or capacity_tasks between 1 and 50)
);
alter table public.team_capacity_settings enable row level security;

create or replace function public.set_team_capacity(p_user_id uuid, p_capacity_tasks integer)
returns void
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare v_role text:=private.current_role();
begin
  if v_role not in ('CFO','Supervisor') then raise exception 'Not authorized to manage team capacity'; end if;
  if p_capacity_tasks is not null and (p_capacity_tasks<1 or p_capacity_tasks>50) then raise exception 'Capacity must be between 1 and 50 tasks'; end if;
  if not exists(select 1 from public.profiles where id=p_user_id and active=true and role in ('Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')) then raise exception 'Finance team member not found'; end if;
  insert into public.team_capacity_settings(user_id,capacity_tasks,updated_by,updated_at)
  values(p_user_id,p_capacity_tasks,auth.uid(),now())
  on conflict(user_id) do update set capacity_tasks=excluded.capacity_tasks,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'SET_TEAM_CAPACITY','profile',p_user_id::text,jsonb_build_object('capacity_tasks',p_capacity_tasks));
end $$;
revoke all on function public.set_team_capacity(uuid,integer) from public;
grant execute on function public.set_team_capacity(uuid,integer) to authenticated;

create or replace function public.mark_task_blocker(p_task_id uuid,p_note text)
returns void
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare v_task public.tasks%rowtype;
begin
  select * into v_task from public.tasks where id=p_task_id for update;
  if not found then raise exception 'Task not found'; end if;
  if v_task.owner_id<>auth.uid() then raise exception 'Only task owner can mark a blocker'; end if;
  if v_task.status in ('مكتمل','بانتظار المراجعة') then raise exception 'Closed or submitted tasks cannot be blocked'; end if;
  if nullif(trim(coalesce(p_note,'')),'') is null then raise exception 'Blocker note is required'; end if;
  update public.tasks set blocker_note=trim(p_note),blocker_since=coalesce(blocker_since,now()),updated_at=now() where id=p_task_id;
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'MARK_TASK_BLOCKER','task',p_task_id::text,jsonb_build_object('note',trim(p_note)));
end $$;
revoke all on function public.mark_task_blocker(uuid,text) from public;
grant execute on function public.mark_task_blocker(uuid,text) to authenticated;

create or replace function public.clear_task_blocker(p_task_id uuid)
returns void
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare v_task public.tasks%rowtype; v_role text:=private.current_role();
begin
  select * into v_task from public.tasks where id=p_task_id for update;
  if not found then raise exception 'Task not found'; end if;
  if auth.uid()<>v_task.owner_id and v_role not in ('CFO','Supervisor') then raise exception 'Not authorized to clear blocker'; end if;
  update public.tasks set blocker_note=null,blocker_since=null,updated_at=now() where id=p_task_id;
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'CLEAR_TASK_BLOCKER','task',p_task_id::text,'{}'::jsonb);
end $$;
revoke all on function public.clear_task_blocker(uuid) from public;
grant execute on function public.clear_task_blocker(uuid) to authenticated;

create or replace function public.complete_finance_task(p_task_id uuid,p_justification text default null)
returns void
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare v_task public.tasks%rowtype; v_deadline timestamptz; v_requires_justification boolean; v_justification text;
begin
  select * into v_task from public.tasks where id=p_task_id for update;
  if not found then raise exception 'Task not found'; end if;
  if v_task.owner_id<>auth.uid() then raise exception 'Only task owner can complete the task'; end if;
  if v_task.frequency='يومي' and v_task.opened_at is null then raise exception 'Daily task has not been released by the Supervisor'; end if;
  if nullif(trim(coalesce(v_task.blocker_note,'')),'') is not null then raise exception 'TASK_BLOCKER_MUST_BE_CLEARED'; end if;
  if v_task.status='بانتظار المراجعة' then raise exception 'Task is already awaiting review'; end if;
  v_deadline:=private.task_deadline(v_task.due_date,v_task.due_time);
  v_requires_justification:=(v_deadline is not null and now()>v_deadline) or v_task.justification_requested_at is not null;
  v_justification:=coalesce(nullif(trim(coalesce(p_justification,'')),''),v_task.delay_justification);
  if v_requires_justification and v_justification is null then raise exception 'DELAY_JUSTIFICATION_REQUIRED'; end if;
  update public.tasks set status='بانتظار المراجعة',review_requested_at=now(),reviewed_at=null,reviewed_by=null,review_note=null,
    delay_justification=case when v_requires_justification then v_justification else delay_justification end,
    justification_submitted_at=case when v_requires_justification then coalesce(justification_submitted_at,now()) else justification_submitted_at end,
    updated_at=now() where id=p_task_id;
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'SUBMIT_TASK_FOR_REVIEW','task',p_task_id::text,jsonb_build_object('deadline',v_deadline,'late',v_deadline is not null and now()>v_deadline,'justification',case when v_requires_justification then v_justification else null end));
end $$;

create or replace function public.review_finance_task(p_task_id uuid,p_approve boolean,p_note text default null)
returns void
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare v_task public.tasks%rowtype; v_role text:=private.current_role();
begin
  select * into v_task from public.tasks where id=p_task_id for update;
  if not found then raise exception 'Task not found'; end if;
  if v_task.status<>'بانتظار المراجعة' then raise exception 'Task is not awaiting review'; end if;
  if not (auth.uid()=v_task.reviewer_id or v_role='CFO' or (v_role='Supervisor' and v_task.owner_id<>auth.uid())) then raise exception 'Not authorized to review this task'; end if;
  if p_approve then
    update public.tasks set status='مكتمل',completed_at=now(),reviewed_at=now(),reviewed_by=auth.uid(),review_note=nullif(trim(coalesce(p_note,'')),''),updated_at=now() where id=p_task_id;
  else
    update public.tasks set status='قيد التنفيذ',review_requested_at=null,reviewed_at=now(),reviewed_by=auth.uid(),review_note=nullif(trim(coalesce(p_note,'')),''),completed_at=null,updated_at=now() where id=p_task_id;
  end if;
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),case when p_approve then 'APPROVE_TASK_REVIEW' else 'RETURN_TASK_REVIEW' end,'task',p_task_id::text,jsonb_build_object('note',nullif(trim(coalesce(p_note,'')),'')));
end $$;
revoke all on function public.review_finance_task(uuid,boolean,text) from public;
grant execute on function public.review_finance_task(uuid,boolean,text) to authenticated;

create or replace function public.get_supervisor_control_center()
returns table(user_id uuid,full_name text,role text,current_task text,current_status text,next_due_at timestamptz,remaining_minutes integer,today_total integer,today_completed integer,overdue_count integer,blocker_count integer,pending_review_count integer,pending_justifications integer)
language sql stable security definer
set search_path=public,private,pg_temp
as $$
with ctx as (
 select (now() at time zone 'Asia/Riyadh')::date today, private.current_role() current_role
), people as (
 select p.id,p.full_name,p.role from public.profiles p,ctx c
 where p.active=true and p.role in ('Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant') and c.current_role in ('CFO','Supervisor')
), stats as (
 select pe.id,
 count(t.id) filter(where t.due_date=c.today)::int today_total,
 count(t.id) filter(where t.due_date=c.today and t.status='مكتمل')::int today_completed,
 count(t.id) filter(where t.status not in ('مكتمل','بانتظار المراجعة') and private.task_deadline(t.due_date,t.due_time)<now())::int overdue_count,
 count(t.id) filter(where nullif(trim(coalesce(t.blocker_note,'')),'') is not null and t.status<>'مكتمل')::int blocker_count,
 count(t.id) filter(where t.status='بانتظار المراجعة')::int pending_review_count,
 count(t.id) filter(where t.status not in ('مكتمل','بانتظار المراجعة') and ((private.task_deadline(t.due_date,t.due_time)<now()) or t.justification_requested_at is not null) and nullif(trim(coalesce(t.delay_justification,'')),'') is null)::int pending_justifications
 from people pe cross join ctx c left join public.tasks t on t.owner_id=pe.id group by pe.id
), current_one as (
 select pe.id,t.name,t.status,private.task_deadline(t.due_date,t.due_time) due_at,
 row_number() over(partition by pe.id order by case when nullif(trim(coalesce(t.blocker_note,'')),'') is not null then 0 when t.status='قيد التنفيذ' then 1 else 2 end,private.task_deadline(t.due_date,t.due_time) nulls last,t.created_at) rn
 from people pe cross join ctx c left join public.tasks t on t.owner_id=pe.id and t.due_date=c.today and t.status not in ('مكتمل','بانتظار المراجعة') and (t.frequency<>'يومي' or t.opened_at is not null)
)
select pe.id,pe.full_name,pe.role,co.name,co.status,co.due_at,
 case when co.due_at is null then null else floor(extract(epoch from(co.due_at-now()))/60)::int end,
 coalesce(s.today_total,0),coalesce(s.today_completed,0),coalesce(s.overdue_count,0),coalesce(s.blocker_count,0),coalesce(s.pending_review_count,0),coalesce(s.pending_justifications,0)
from people pe left join stats s on s.id=pe.id left join current_one co on co.id=pe.id and co.rn=1
order by case pe.role when 'Supervisor' then 1 when 'BankAccountant' then 2 when 'GLAccountant' then 3 when 'ARAccountant' then 4 when 'APAccountant' then 5 else 9 end,pe.full_name;
$$;
revoke all on function public.get_supervisor_control_center() from public;
grant execute on function public.get_supervisor_control_center() to authenticated;

create or replace function public.get_workload_capacity()
returns table(user_id uuid,full_name text,role text,capacity_tasks integer,planned_open integer,critical_open integer,high_open integer,overdue_open integer,pending_review integer,blockers integer,utilization_percent numeric)
language sql stable security definer
set search_path=public,private,pg_temp
as $$
with ctx as(select (now() at time zone 'Asia/Riyadh')::date today,private.current_role() current_role),
people as(select p.id,p.full_name,p.role from public.profiles p,ctx c where p.active=true and p.role in ('Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant') and c.current_role in ('CFO','Supervisor')),
stats as(select pe.id,
 count(t.id) filter(where t.due_date=c.today and t.status<>'مكتمل')::int planned_open,
 count(t.id) filter(where t.due_date=c.today and t.status<>'مكتمل' and t.priority='حرج')::int critical_open,
 count(t.id) filter(where t.due_date=c.today and t.status<>'مكتمل' and t.priority in ('عالي','عاجل'))::int high_open,
 count(t.id) filter(where t.status not in ('مكتمل','بانتظار المراجعة') and private.task_deadline(t.due_date,t.due_time)<now())::int overdue_open,
 count(t.id) filter(where t.status='بانتظار المراجعة')::int pending_review,
 count(t.id) filter(where t.status<>'مكتمل' and nullif(trim(coalesce(t.blocker_note,'')),'') is not null)::int blockers
 from people pe cross join ctx c left join public.tasks t on t.owner_id=pe.id group by pe.id)
select pe.id,pe.full_name,pe.role,cs.capacity_tasks,coalesce(s.planned_open,0),coalesce(s.critical_open,0),coalesce(s.high_open,0),coalesce(s.overdue_open,0),coalesce(s.pending_review,0),coalesce(s.blockers,0),
 case when cs.capacity_tasks is null or cs.capacity_tasks=0 then null else round(coalesce(s.planned_open,0)*100.0/cs.capacity_tasks,1) end
from people pe left join stats s on s.id=pe.id left join public.team_capacity_settings cs on cs.user_id=pe.id
order by case pe.role when 'Supervisor' then 1 when 'BankAccountant' then 2 when 'GLAccountant' then 3 when 'ARAccountant' then 4 when 'APAccountant' then 5 else 9 end,pe.full_name;
$$;
revoke all on function public.get_workload_capacity() from public;
grant execute on function public.get_workload_capacity() to authenticated;

create or replace function public.get_escalation_center()
returns table(task_id uuid,task_name text,owner_id uuid,owner_name text,priority text,status text,due_at timestamptz,issue text,severity text,age_minutes integer,blocker_note text,justification_note text)
language sql stable security definer
set search_path=public,private,pg_temp
as $$
with ctx as(select private.current_role() current_role), base as(
 select t.*,p.full_name owner_name,private.task_deadline(t.due_date,t.due_time) due_at
 from public.tasks t join public.profiles p on p.id=t.owner_id,ctx c
 where c.current_role in ('CFO','Supervisor') and t.status<>'مكتمل'
), flagged as(
 select b.*,
 concat_ws('، ',
  case when nullif(trim(coalesce(b.blocker_note,'')),'') is not null then 'تعثر' end,
  case when b.status not in ('مكتمل','بانتظار المراجعة') and b.due_at<now() then 'متأخر' end,
  case when b.status='بانتظار المراجعة' then 'بانتظار مراجعة' end,
  case when b.justification_requested_at is not null and nullif(trim(coalesce(b.delay_justification,'')),'') is null then 'تبرير مطلوب' end
 ) issue,
 case when b.priority='حرج' and (b.due_at<now() or b.blocker_since is not null) then 'حرج'
      when b.blocker_since is not null or (b.status not in ('مكتمل','بانتظار المراجعة') and b.due_at<now()) or b.justification_requested_at is not null then 'عالي'
      else 'متوسط' end severity,
 least(coalesce(b.blocker_since,now()),coalesce(b.justification_requested_at,now()),coalesce(b.review_requested_at,now()),coalesce(b.due_at,now())) issue_since
 from base b
 where nullif(trim(coalesce(b.blocker_note,'')),'') is not null
    or (b.status not in ('مكتمل','بانتظار المراجعة') and b.due_at<now())
    or b.status='بانتظار المراجعة'
    or (b.justification_requested_at is not null and nullif(trim(coalesce(b.delay_justification,'')),'') is null)
)
select id,name,owner_id,owner_name,priority,status,due_at,issue,severity,greatest(0,floor(extract(epoch from(now()-issue_since))/60)::int),blocker_note,justification_request_note
from flagged order by case severity when 'حرج' then 1 when 'عالي' then 2 else 3 end,due_at nulls last;
$$;
revoke all on function public.get_escalation_center() from public;
grant execute on function public.get_escalation_center() to authenticated;

create or replace function public.get_finance_team_performance()
returns table(user_id uuid,full_name text,role text,today_total integer,today_completed integer,today_overdue integer,pending_justifications integer,pending_review integer,month_total integer,month_completed integer,month_completion_rate numeric,tracked_on_time_rate numeric,close_total integer,close_completed integer,close_completion_rate numeric)
language sql stable security definer
set search_path=public,private,pg_temp
as $$
with ctx as(select (now() at time zone 'Asia/Riyadh')::date today,date_trunc('month',now() at time zone 'Asia/Riyadh')::date month_start,private.current_role() current_role,auth.uid() current_uid),
people as(select p.id,p.full_name,p.role from public.profiles p,ctx c where p.active=true and p.role in ('Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant') and (c.current_role in ('CFO','Supervisor') or p.id=c.current_uid)),
task_stats as(select pe.id,
 count(t.id) filter(where t.due_date=c.today)::int today_total,
 count(t.id) filter(where t.due_date=c.today and t.status='مكتمل')::int today_completed,
 count(t.id) filter(where t.status not in ('مكتمل','بانتظار المراجعة') and private.task_deadline(t.due_date,t.due_time)<now())::int today_overdue,
 count(t.id) filter(where t.status not in ('مكتمل','بانتظار المراجعة') and ((private.task_deadline(t.due_date,t.due_time)<now()) or t.justification_requested_at is not null) and nullif(trim(coalesce(t.delay_justification,'')),'') is null)::int pending_justifications,
 count(t.id) filter(where t.status='بانتظار المراجعة')::int pending_review,
 count(t.id) filter(where t.due_date between c.month_start and c.today)::int month_total,
 count(t.id) filter(where t.due_date between c.month_start and c.today and t.status='مكتمل')::int month_completed,
 count(t.id) filter(where t.due_date between c.month_start and c.today and t.status='مكتمل' and t.review_requested_at is not null)::int tracked_completed,
 count(t.id) filter(where t.due_date between c.month_start and c.today and t.status='مكتمل' and t.review_requested_at is not null and t.review_requested_at<=private.task_deadline(t.due_date,t.due_time))::int tracked_on_time
 from people pe cross join ctx c left join public.tasks t on t.owner_id=pe.id group by pe.id),
close_stats as(select pe.id,count(m.id)::int close_total,count(m.id) filter(where m.status='مكتمل' or coalesce(m.progress,0)>=100)::int close_completed from people pe cross join ctx c left join public.monthly_close_tasks m on m.owner_id=pe.id and m.close_period=c.month_start group by pe.id)
select pe.id,pe.full_name,pe.role,coalesce(ts.today_total,0),coalesce(ts.today_completed,0),coalesce(ts.today_overdue,0),coalesce(ts.pending_justifications,0),coalesce(ts.pending_review,0),coalesce(ts.month_total,0),coalesce(ts.month_completed,0),
 case when coalesce(ts.month_total,0)=0 then 0 else round(ts.month_completed*100.0/ts.month_total,1) end,
 case when coalesce(ts.tracked_completed,0)=0 then 0 else round(ts.tracked_on_time*100.0/ts.tracked_completed,1) end,
 coalesce(cs.close_total,0),coalesce(cs.close_completed,0),case when coalesce(cs.close_total,0)=0 then 0 else round(cs.close_completed*100.0/cs.close_total,1) end
from people pe left join task_stats ts on ts.id=pe.id left join close_stats cs on cs.id=pe.id
order by case pe.role when 'Supervisor' then 1 when 'BankAccountant' then 2 when 'GLAccountant' then 3 when 'ARAccountant' then 4 when 'APAccountant' then 5 else 9 end,pe.full_name;
$$;

create or replace function public.get_automation_health()
returns table(system_name text,job_name text,active boolean,schedule text,last_run_at timestamptz,last_status text,next_run_at timestamptz,missing_count integer,detail text)
language sql stable security definer
set search_path=public,private,cron,pg_temp
as $$
with ctx as(
 select private.current_role() current_role,(now() at time zone 'Asia/Riyadh') local_now,(now() at time zone 'Asia/Riyadh')::date local_date
), jobs as(
 select j.jobid,j.jobname,j.active,j.schedule from cron.job j,ctx c where c.current_role in ('CFO','Supervisor') and j.jobname in ('sanam_generate_daily_tasks','sanam_generate_monthly_close_tasks')
), latest as(
 select j.*,r.start_time,r.status,r.return_message from jobs j left join lateral(select d.start_time,d.status,d.return_message from cron.job_run_details d where d.jobid=j.jobid order by d.start_time desc limit 1) r on true
), counts as(
 select
 (select count(*)::int from private.daily_task_templates where active=true) daily_expected,
 (select count(*)::int from public.tasks t join private.daily_task_templates d on d.active=true and d.owner_id=t.owner_id and d.name=t.name where t.frequency='يومي' and t.due_date=(select local_date from ctx)) daily_actual,
 (select count(*)::int from private.monthly_close_templates where active=true) close_expected,
 (select count(*)::int from public.monthly_close_tasks where close_period=(select max(close_period) from public.monthly_close_tasks)) close_actual
)
select case l.jobname when 'sanam_generate_daily_tasks' then 'تجديد المهام اليومية' else 'تجديد الإقفال الشهري' end,
 l.jobname,l.active,l.schedule,l.start_time,l.status,
 case when l.jobname='sanam_generate_daily_tasks' then
   ((case when (select local_now::time from ctx)<time '00:05' then (select local_date from ctx) else (select local_date+1 from ctx) end)::timestamp+time '00:05') at time zone 'Asia/Riyadh'
 else (date_trunc('month',(select local_date from ctx)+interval '1 month')::date::timestamp+time '00:10') at time zone 'Asia/Riyadh' end,
 case when l.jobname='sanam_generate_daily_tasks' then greatest(0,c.daily_expected-c.daily_actual) else greatest(0,c.close_expected-c.close_actual) end,
 coalesce(l.return_message,case when l.start_time is null then 'لم يتم تسجيل تشغيل بعد' else '—' end)
from latest l cross join counts c order by l.jobname;
$$;
revoke all on function public.get_automation_health() from public;
grant execute on function public.get_automation_health() to authenticated;
