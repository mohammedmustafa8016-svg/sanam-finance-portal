-- Read-only Work Center V5 performance gate.
-- Safe to run against an existing environment: no DDL/DML, no fixture writes.
-- Target: keep a full CFO team dashboard read below 2 seconds under the current workload.

do $$
declare
  cfo uuid;
  started_at timestamptz;
  elapsed_ms numeric;
  d jsonb;
begin
  select id into cfo
  from public.profiles
  where active and role='CFO'
  order by created_at nulls last
  limit 1;

  if cfo is null then
    raise exception 'NO_ACTIVE_CFO_PROFILE';
  end if;

  perform set_config('request.jwt.claim.sub',cfo::text,true);

  started_at:=clock_timestamp();
  d:=public.get_workcenter_dashboard_v5('team','{}'::jsonb);
  elapsed_ms:=extract(epoch from (clock_timestamp()-started_at))*1000;

  if d is null or jsonb_typeof(d)<>'object' then
    raise exception 'INVALID_DASHBOARD_PAYLOAD';
  end if;

  if not (d ? 'items' and d ? 'summary' and d ? 'team') then
    raise exception 'DASHBOARD_SHAPE_CHANGED';
  end if;

  if elapsed_ms>2000 then
    raise exception 'WORKCENTER_V5_PERFORMANCE_GATE_FAILED: % ms',round(elapsed_ms,1);
  end if;

  raise notice 'WORKCENTER_V5_PERFORMANCE: % ms',round(elapsed_ms,1);
end $$;

select 'PASS: Work Center V5 payload contract preserved and team dashboard completed under 2000 ms' as result;
