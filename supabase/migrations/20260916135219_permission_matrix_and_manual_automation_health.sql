create or replace function private.default_permission_for_role(p_role text,p_key text) returns boolean
language sql immutable as $$
select case p_key
 when 'page.dashboard' then p_role in ('CFO','Supervisor','BankAccountant')
 when 'page.banks' then p_role in ('CFO','Supervisor','BankAccountant')
 when 'page.payments' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','APAccountant')
 when 'page.posted' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','APAccountant')
 when 'page.pending' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant')
 when 'page.tasks' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
 when 'page.control' then p_role in ('CFO','Supervisor')
 when 'page.workload' then p_role in ('CFO','Supervisor')
 when 'page.escalations' then p_role in ('CFO','Supervisor')
 when 'page.automation' then p_role='CFO'
 when 'page.close' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
 when 'page.imprest' then p_role in ('CFO','Supervisor','BankAccountant','APAccountant')
 when 'page.performance' then p_role in ('CFO','Supervisor','ARAccountant','APAccountant')
 when 'page.ownership' then p_role in ('CFO','Supervisor')
 when 'page.exceptions' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
 when 'page.audit' then p_role='CFO'
 when 'page.permissions' then p_role='CFO'
 when 'data.bank_balances' then p_role in ('CFO','Supervisor','BankAccountant')
 else false end;
$$;

create or replace function public.get_my_permissions() returns table(permission_key text,allowed boolean)
language sql stable security definer set search_path='public','private','pg_temp' as $$
with keys(permission_key) as (values
 ('page.dashboard'),('page.banks'),('page.payments'),('page.posted'),('page.pending'),('page.tasks'),('page.control'),('page.workload'),('page.escalations'),('page.automation'),('page.close'),('page.imprest'),('page.performance'),('page.ownership'),('page.exceptions'),('page.audit'),('page.permissions'),('data.bank_balances'))
select k.permission_key,public.has_user_permission(k.permission_key) from keys k;
$$;

do $$ declare k text; begin
 foreach k in array array['page.dashboard','page.banks','page.payments','page.posted','page.pending','page.tasks','page.control','page.workload','page.escalations','page.automation','page.close','page.imprest','page.performance','page.ownership','page.exceptions','page.audit','page.permissions','data.bank_balances'] loop
   insert into public.user_permissions(user_id,permission_key,allowed,updated_at)
   select p.id,k,private.default_permission_for_role(p.role,k),now() from public.profiles p where p.active=true
   on conflict(user_id,permission_key) do nothing;
 end loop;
end $$;

create or replace function public.get_automation_health()
returns table(system_name text,job_name text,active boolean,schedule text,last_run_at timestamptz,last_status text,next_run_at timestamptz,missing_count integer,detail text)
language sql stable security definer set search_path='public','private','cron','pg_temp' as $$
with ctx as(select private.current_role() current_role,(now() at time zone 'Asia/Riyadh') local_now,(now() at time zone 'Asia/Riyadh')::date local_date),jobs as(select j.jobid,j.jobname,j.active,j.schedule from cron.job j,ctx c where c.current_role='CFO' and j.jobname in ('sanam_generate_daily_tasks','sanam_generate_monthly_close_tasks')),latest as(select j.*,r.start_time,r.status,r.return_message from jobs j left join lateral(select d.start_time,d.status,d.return_message from cron.job_run_details d where d.jobid=j.jobid order by d.start_time desc limit 1) r on true),counts as(select (select count(*)::int from private.monthly_close_templates where active=true) close_expected,(select count(*)::int from public.monthly_close_tasks where close_period=(select max(close_period) from public.monthly_close_tasks)) close_actual)
select case l.jobname when 'sanam_generate_daily_tasks' then 'خطة اليوم اليدوية' else 'تجديد الإقفال الشهري' end,l.jobname,
case when l.jobname='sanam_generate_daily_tasks' then false else l.active end,l.schedule,l.start_time,l.status,
case when l.jobname='sanam_generate_daily_tasks' then null else (date_trunc('month',(select local_date from ctx)+interval '1 month')::date::timestamp+time '00:10') at time zone 'Asia/Riyadh' end,
case when l.jobname='sanam_generate_daily_tasks' then 0 else greatest(0,c.close_expected-c.close_actual) end,
case when l.jobname='sanam_generate_daily_tasks' then 'تم إيقاف التوليد التلقائي. يتم فتح مهام اليوم يدويًا من القوالب بواسطة المشرف أو المدير المالي.' else coalesce(l.return_message,case when l.start_time is null then 'لم يتم تسجيل تشغيل بعد' else '—' end) end
from latest l cross join counts c order by l.jobname;
$$;