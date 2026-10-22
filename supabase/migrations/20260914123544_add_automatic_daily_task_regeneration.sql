create extension if not exists pg_cron;

create table if not exists private.daily_task_templates (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  reviewer_id uuid references public.profiles(id) on delete set null,
  priority text,
  default_status text,
  output text,
  created_by uuid references public.profiles(id) on delete set null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (name, owner_id)
);

insert into private.daily_task_templates
  (name, owner_id, reviewer_id, priority, default_status, output, created_by, active)
select distinct on (t.name,t.owner_id)
  t.name,t.owner_id,t.reviewer_id,t.priority,t.status,t.output,t.created_by,true
from public.tasks t
where t.frequency='يومي' and t.owner_id is not null
order by t.name,t.owner_id,t.due_date desc nulls last,t.updated_at desc
on conflict (name,owner_id) do update set
  reviewer_id=excluded.reviewer_id,
  priority=excluded.priority,
  default_status=excluded.default_status,
  output=excluded.output,
  created_by=excluded.created_by,
  active=true,
  updated_at=now();

create unique index if not exists tasks_daily_owner_name_due_uidx
on public.tasks(owner_id,name,due_date)
where frequency='يومي' and owner_id is not null and due_date is not null;

create or replace function private.generate_daily_tasks(p_target_date date default null)
returns integer
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_target_date date := coalesce(p_target_date,(now() at time zone 'Asia/Riyadh')::date);
  v_inserted integer := 0;
begin
  insert into public.tasks
    (name,frequency,owner_id,reviewer_id,due_date,priority,status,output,created_by)
  select
    d.name,
    'يومي',
    d.owner_id,
    d.reviewer_id,
    v_target_date,
    d.priority,
    d.default_status,
    d.output,
    d.created_by
  from private.daily_task_templates d
  join public.profiles p on p.id=d.owner_id and p.active=true
  where d.active=true
    and not exists (
      select 1
      from public.tasks t
      where t.frequency='يومي'
        and t.owner_id=d.owner_id
        and t.name=d.name
        and t.due_date=v_target_date
    );

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

revoke all on function private.generate_daily_tasks(date) from public, anon, authenticated;

select cron.unschedule(jobid)
from cron.job
where jobname='sanam_generate_daily_tasks';

select cron.schedule(
  'sanam_generate_daily_tasks',
  '5 21 * * *',
  $$select private.generate_daily_tasks();$$
);