-- Finance operations control: daily supervision, task timing, mandatory delay justification,
-- live team performance metrics, and approved ownership matrix baseline.

alter table public.tasks add column if not exists due_time time without time zone;
alter table public.tasks add column if not exists opened_at timestamp with time zone;
alter table public.tasks add column if not exists opened_by uuid references public.profiles(id);
alter table public.tasks add column if not exists started_at timestamp with time zone;
alter table public.tasks add column if not exists completed_at timestamp with time zone;
alter table public.tasks add column if not exists delay_justification text;
alter table public.tasks add column if not exists justification_requested_at timestamp with time zone;
alter table public.tasks add column if not exists justification_requested_by uuid references public.profiles(id);
alter table public.tasks add column if not exists justification_request_note text;
alter table public.tasks add column if not exists justification_submitted_at timestamp with time zone;

create index if not exists tasks_due_monitoring_idx
  on public.tasks(due_date, due_time, status, owner_id);

create or replace function private.task_deadline(p_due_date date, p_due_time time without time zone)
returns timestamp with time zone
language sql
stable
set search_path = public, private, pg_temp
as $$
  select case
    when p_due_date is null then null
    else (p_due_date::timestamp + coalesce(p_due_time, time '23:59:59')) at time zone 'Asia/Riyadh'
  end
$$;

create or replace function public.supervisor_open_daily_plan(p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_role text := private.current_role();
  v_today date := (now() at time zone 'Asia/Riyadh')::date;
  v_item jsonb;
  v_id uuid;
  v_due_time time without time zone;
  v_count integer := 0;
  v_task public.tasks%rowtype;
begin
  if v_role <> 'Supervisor' then
    raise exception 'Only Supervisor can open the daily work plan';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then
    raise exception 'Daily plan must include at least one task';
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_id := (v_item->>'id')::uuid;
    if coalesce(v_item->>'due_time','') = '' then
      raise exception 'Due time is required for every released daily task';
    end if;
    v_due_time := (v_item->>'due_time')::time;

    select * into v_task from public.tasks where id=v_id for update;
    if not found then raise exception 'Task not found'; end if;
    if v_task.frequency <> 'يومي' or v_task.due_date <> v_today then
      raise exception 'Only today daily tasks can be released';
    end if;
    if v_task.status = 'مكتمل' then
      continue;
    end if;

    update public.tasks
      set due_time=v_due_time,
          opened_at=coalesce(opened_at,now()),
          opened_by=auth.uid(),
          updated_at=now()
    where id=v_id;

    insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
    values(auth.uid(),'OPEN_DAILY_TASK','task',v_id::text,
      jsonb_build_object('owner_id',v_task.owner_id,'due_date',v_today,'due_time',v_due_time));
    v_count := v_count+1;
  end loop;
  return v_count;
end;
$$;
revoke all on function public.supervisor_open_daily_plan(jsonb) from public;
grant execute on function public.supervisor_open_daily_plan(jsonb) to authenticated;

create or replace function public.start_finance_task(p_task_id uuid)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_task public.tasks%rowtype;
begin
  select * into v_task from public.tasks where id=p_task_id for update;
  if not found then raise exception 'Task not found'; end if;
  if v_task.owner_id <> auth.uid() then raise exception 'Only task owner can start the task'; end if;
  if v_task.frequency='يومي' and v_task.opened_at is null then
    raise exception 'Daily task has not been released by the Supervisor';
  end if;
  if v_task.status='مكتمل' then raise exception 'Completed task cannot be restarted'; end if;

  update public.tasks
    set status='قيد التنفيذ', started_at=coalesce(started_at,now()), updated_at=now()
  where id=p_task_id;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'START_TASK','task',p_task_id::text,jsonb_build_object('name',v_task.name));
end;
$$;
revoke all on function public.start_finance_task(uuid) from public;
grant execute on function public.start_finance_task(uuid) to authenticated;

create or replace function public.request_task_justification(p_task_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_role text := private.current_role();
  v_task public.tasks%rowtype;
begin
  if v_role <> 'Supervisor' then raise exception 'Only Supervisor can request task justification'; end if;
  select * into v_task from public.tasks where id=p_task_id for update;
  if not found then raise exception 'Task not found'; end if;
  if v_task.status='مكتمل' then raise exception 'Task is already completed'; end if;

  update public.tasks
    set justification_requested_at=now(), justification_requested_by=auth.uid(),
        justification_request_note=nullif(trim(coalesce(p_note,'')),''), updated_at=now()
  where id=p_task_id;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'REQUEST_TASK_JUSTIFICATION','task',p_task_id::text,
    jsonb_build_object('owner_id',v_task.owner_id,'note',nullif(trim(coalesce(p_note,'')),'')));
end;
$$;
revoke all on function public.request_task_justification(uuid,text) from public;
grant execute on function public.request_task_justification(uuid,text) to authenticated;

create or replace function public.submit_task_justification(p_task_id uuid, p_justification text)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_task public.tasks%rowtype;
begin
  if nullif(trim(coalesce(p_justification,'')),'') is null then
    raise exception 'Justification is required';
  end if;
  select * into v_task from public.tasks where id=p_task_id for update;
  if not found then raise exception 'Task not found'; end if;
  if v_task.owner_id <> auth.uid() then raise exception 'Only task owner can submit justification'; end if;

  update public.tasks
    set delay_justification=trim(p_justification), justification_submitted_at=now(), updated_at=now()
  where id=p_task_id;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'SUBMIT_TASK_JUSTIFICATION','task',p_task_id::text,
    jsonb_build_object('justification',trim(p_justification)));
end;
$$;
revoke all on function public.submit_task_justification(uuid,text) from public;
grant execute on function public.submit_task_justification(uuid,text) to authenticated;

create or replace function public.complete_finance_task(p_task_id uuid, p_justification text default null)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_task public.tasks%rowtype;
  v_deadline timestamp with time zone;
  v_requires_justification boolean;
  v_justification text;
begin
  select * into v_task from public.tasks where id=p_task_id for update;
  if not found then raise exception 'Task not found'; end if;
  if v_task.owner_id <> auth.uid() then raise exception 'Only task owner can complete the task'; end if;
  if v_task.frequency='يومي' and v_task.opened_at is null then
    raise exception 'Daily task has not been released by the Supervisor';
  end if;

  v_deadline := private.task_deadline(v_task.due_date,v_task.due_time);
  v_requires_justification :=
    (v_deadline is not null and now() > v_deadline)
    or v_task.justification_requested_at is not null;
  v_justification := coalesce(nullif(trim(coalesce(p_justification,'')),''),v_task.delay_justification);

  if v_requires_justification and v_justification is null then
    raise exception 'DELAY_JUSTIFICATION_REQUIRED';
  end if;

  update public.tasks
    set status='مكتمل',
        completed_at=coalesce(completed_at,now()),
        delay_justification=case when v_requires_justification then v_justification else delay_justification end,
        justification_submitted_at=case when v_requires_justification then coalesce(justification_submitted_at,now()) else justification_submitted_at end,
        updated_at=now()
  where id=p_task_id;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'COMPLETE_TASK','task',p_task_id::text,
    jsonb_build_object('deadline',v_deadline,'late',v_deadline is not null and now()>v_deadline,
      'justification',case when v_requires_justification then v_justification else null end));
end;
$$;
revoke all on function public.complete_finance_task(uuid,text) from public;
grant execute on function public.complete_finance_task(uuid,text) to authenticated;

create or replace function public.get_finance_team_performance()
returns table(
  user_id uuid,
  full_name text,
  role text,
  today_total integer,
  today_completed integer,
  today_overdue integer,
  pending_justifications integer,
  month_total integer,
  month_completed integer,
  month_completion_rate numeric,
  tracked_on_time_rate numeric,
  close_total integer,
  close_completed integer,
  close_completion_rate numeric
)
language sql
stable
security definer
set search_path = public, private, pg_temp
as $$
with ctx as (
  select (now() at time zone 'Asia/Riyadh')::date as today,
         date_trunc('month',now() at time zone 'Asia/Riyadh')::date as month_start,
         private.current_role() as current_role,
         auth.uid() as current_uid
), people as (
  select p.id,p.full_name,p.role
  from public.profiles p,ctx c
  where p.active=true
    and p.role in ('Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
    and (c.current_role in ('CFO','Supervisor') or p.id=c.current_uid)
), task_stats as (
  select pe.id,
    count(t.id) filter(where t.due_date=c.today)::int as today_total,
    count(t.id) filter(where t.due_date=c.today and (t.status='مكتمل' or t.completed_at is not null))::int as today_completed,
    count(t.id) filter(where (t.status<>'مكتمل' and t.completed_at is null)
      and private.task_deadline(t.due_date,t.due_time) < now())::int as today_overdue,
    count(t.id) filter(where (t.status<>'مكتمل' and t.completed_at is null)
      and ((private.task_deadline(t.due_date,t.due_time) < now()) or t.justification_requested_at is not null)
      and nullif(trim(coalesce(t.delay_justification,'')),'') is null)::int as pending_justifications,
    count(t.id) filter(where t.due_date between c.month_start and c.today)::int as month_total,
    count(t.id) filter(where t.due_date between c.month_start and c.today and (t.status='مكتمل' or t.completed_at is not null))::int as month_completed,
    count(t.id) filter(where t.due_date between c.month_start and c.today and t.completed_at is not null)::int as tracked_completed,
    count(t.id) filter(where t.due_date between c.month_start and c.today and t.completed_at is not null
      and t.completed_at <= private.task_deadline(t.due_date,t.due_time))::int as tracked_on_time
  from people pe cross join ctx c
  left join public.tasks t on t.owner_id=pe.id
  group by pe.id
), close_stats as (
  select pe.id,
    count(m.id)::int as close_total,
    count(m.id) filter(where m.status='مكتمل' or coalesce(m.progress,0)>=100)::int as close_completed
  from people pe cross join ctx c
  left join public.monthly_close_tasks m on m.owner_id=pe.id and m.close_period=c.month_start
  group by pe.id
)
select pe.id,pe.full_name,pe.role,
  coalesce(ts.today_total,0),coalesce(ts.today_completed,0),coalesce(ts.today_overdue,0),coalesce(ts.pending_justifications,0),
  coalesce(ts.month_total,0),coalesce(ts.month_completed,0),
  case when coalesce(ts.month_total,0)=0 then 0 else round(ts.month_completed*100.0/ts.month_total,1) end,
  case when coalesce(ts.tracked_completed,0)=0 then 0 else round(ts.tracked_on_time*100.0/ts.tracked_completed,1) end,
  coalesce(cs.close_total,0),coalesce(cs.close_completed,0),
  case when coalesce(cs.close_total,0)=0 then 0 else round(cs.close_completed*100.0/cs.close_total,1) end
from people pe
left join task_stats ts on ts.id=pe.id
left join close_stats cs on cs.id=pe.id
order by case pe.role when 'Supervisor' then 1 when 'BankAccountant' then 2 when 'GLAccountant' then 3 when 'ARAccountant' then 4 when 'APAccountant' then 5 else 9 end,pe.full_name;
$$;
revoke all on function public.get_finance_team_performance() from public;
grant execute on function public.get_finance_team_performance() to authenticated;

-- Daily supervisory planning task. No new employee or role is invented; existing approved profiles are used.
insert into private.daily_task_templates(name,owner_id,reviewer_id,priority,default_status,output,created_by,active)
select 'إعداد وتوجيه خطة عمل الفريق اليومية',s.id,c.id,'عالي','لم يبدأ',
       'تحديد مهام كل عضو لليوم، وضع موعد الاستحقاق، فتح المهام ومتابعة التعثر حتى الإقفال',c.id,true
from public.profiles s
join public.profiles c on c.role='CFO' and c.active=true
where s.role='Supervisor' and s.active=true
  and not exists(select 1 from private.daily_task_templates d where d.name='إعداد وتوجيه خطة عمل الفريق اليومية' and d.owner_id=s.id);

select private.generate_daily_tasks((now() at time zone 'Asia/Riyadh')::date);

-- Approved finance ownership baseline used by the control matrix.
insert into public.ownership_matrix(process,activity,frequency,owner_name,reviewer_name,approver_name,output,control_note,sort_order)
select * from (values
 ('البنوك','التسويات البنكية','شهري','عمرو الشافعي','محي الدين علي حسن','المدير المالي','تسوية بنكية مكتملة لكل حساب','إعداد ومراجعة منفصلان',10),
 ('القيود والتسويات','المصروفات المستحقة والمقدمة','شهري','فهد بشير','محي الدين علي حسن','المدير المالي للحالات الجوهرية','قيود تسوية مؤيدة بالمستندات','لا ترحيل دون مستند داعم',20),
 ('العهد','العهد العامة والتسويات النقدية','مستمر','عمرو الشافعي','محي الدين علي حسن','—','سجل عهد وتسويات محدث','فصل الصرف عن المراجعة',30),
 ('المشاريع','عهد ومصروفات المشاريع','مستمر','أشرف بابكر','محي الدين علي حسن','—','مستندات وتسويات المشاريع','ربط الصرف بالمشروع والمستند',40),
 ('القيود','الترحيل المحاسبي وقيود اليومية','يومي','فهد بشير','محي الدين علي حسن','—','قيود صحيحة ومؤيدة','منع التكرار والتوجيه الخاطئ',50),
 ('الأصول','الأصول الثابتة والإهلاك','شهري','محمد الجندي','محي الدين علي حسن','—','سجل أصول وقيد إهلاك','مطابقة الإضافات والاستبعادات',60),
 ('الضرائب','ضريبة القيمة المضافة - المدخلات','شهري','أشرف بابكر','محي الدين علي حسن','—','مراجعة مدخلات VAT','مطابقة الفواتير والمستندات',70),
 ('بين الشركات','التسويات بين الشركات','شهري','فهد بشير','محي الدين علي حسن','المدير المالي','مطابقة وتسوية الأرصدة','اعتماد المدير المالي قبل الإقفال',80),
 ('الإقفال','إدارة دورة الإقفال والمتابعة','شهري','محي الدين علي حسن','المدير المالي','المدير المالي','قائمة إقفال مكتملة ضمن D+','التأخير يرفع قبل الموعد ويبرر',90),
 ('الإقفال','قفل الفترة المحاسبية','شهري','محي الدين علي حسن','المدير المالي','المدير المالي','فترة مقفلة بعد اكتمال المراجعة','لا قيد بعد القفل دون موافقة',100)
) as v(process,activity,frequency,owner_name,reviewer_name,approver_name,output,control_note,sort_order)
where not exists(select 1 from public.ownership_matrix o where o.process=v.process and o.activity=v.activity);
