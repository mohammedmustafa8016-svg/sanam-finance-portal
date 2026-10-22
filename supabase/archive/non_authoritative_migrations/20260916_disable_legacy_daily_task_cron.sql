-- Final production guard: keep historical tasks/templates intact while disabling legacy automatic daily-task generation.
do $$
declare v_job_id bigint;
begin
  select jobid into v_job_id
  from cron.job
  where jobname='sanam_generate_daily_tasks' or command like '%private.generate_daily_tasks%'
  order by jobid
  limit 1;
  if v_job_id is not null then
    perform cron.alter_job(v_job_id, null, null, null, null, false);
  end if;
end $$;

insert into public.finance_settings(setting_key,setting_value,updated_at)
values('auto_daily_generation_enabled','false'::jsonb,now())
on conflict(setting_key) do update
set setting_value='false'::jsonb,updated_at=now();
