create table if not exists private.monthly_close_templates (
  id uuid primary key default gen_random_uuid(),
  track text not null,
  code text not null,
  name text not null,
  owner_id uuid references public.profiles(id),
  priority text,
  status text not null default 'لم يبدأ',
  output text,
  created_by uuid references public.profiles(id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(owner_id, track, code, name)
);

alter table public.monthly_close_tasks add column if not exists due_date date;
alter table public.monthly_close_tasks add column if not exists priority text;
alter table public.monthly_close_tasks add column if not exists output text;
alter table public.monthly_close_tasks add column if not exists close_period date;

insert into private.monthly_close_templates(track,code,name,owner_id,priority,status,output,created_by)
select m.track,m.code,m.name,m.owner_id,coalesce(m.priority,'عادي'),'لم يبدأ',m.output,m.created_by
from public.monthly_close_tasks m
where m.code ~ '^D\+[0-9]+$'
on conflict (owner_id,track,code,name) do update
set priority=excluded.priority,
    output=excluded.output,
    active=true,
    updated_at=now();

update public.monthly_close_tasks
set close_period = date '2026-09-01'
where close_period is null
  and due_date between date '2026-10-01' and date '2026-10-31'
  and code ~ '^D\+[0-9]+$';

create unique index if not exists monthly_close_tasks_cycle_unique
on public.monthly_close_tasks(close_period, owner_id, track, code, name)
where close_period is not null;

create or replace function private.generate_monthly_close_tasks(p_close_period date default null)
returns integer
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_period date;
  v_due_month date;
  v_inserted integer;
begin
  v_period := coalesce(date_trunc('month', p_close_period)::date,
                       (date_trunc('month', (now() at time zone 'Asia/Riyadh')) - interval '1 month')::date);
  v_due_month := (v_period + interval '1 month')::date;

  insert into public.monthly_close_tasks(
    track, code, name, owner_id, progress, status, created_by,
    due_date, priority, output, close_period
  )
  select
    t.track,
    t.code,
    t.name,
    t.owner_id,
    0,
    t.status,
    t.created_by,
    (v_due_month + ((substring(t.code from '[0-9]+'))::int - 1) * interval '1 day')::date,
    coalesce(t.priority,'عادي'),
    t.output,
    v_period
  from private.monthly_close_templates t
  where t.active = true
  on conflict (close_period, owner_id, track, code, name) where close_period is not null do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

revoke all on function private.generate_monthly_close_tasks(date) from public;
revoke all on function private.generate_monthly_close_tasks(date) from anon;
revoke all on function private.generate_monthly_close_tasks(date) from authenticated;

create or replace function private.monthly_close_scheduler_tick()
returns integer
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_local_date date := (now() at time zone 'Asia/Riyadh')::date;
begin
  if extract(day from v_local_date) <> 1 then
    return 0;
  end if;
  return private.generate_monthly_close_tasks((v_local_date - interval '1 month')::date);
end;
$$;

revoke all on function private.monthly_close_scheduler_tick() from public;
revoke all on function private.monthly_close_scheduler_tick() from anon;
revoke all on function private.monthly_close_scheduler_tick() from authenticated;

do $$
declare
  jid bigint;
begin
  select jobid into jid from cron.job where jobname='sanam_generate_monthly_close_tasks' limit 1;
  if jid is not null then
    perform cron.unschedule(jid);
  end if;
  perform cron.schedule(
    'sanam_generate_monthly_close_tasks',
    '10 21 28-31 * *',
    'select private.monthly_close_scheduler_tick();'
  );
end $$;