-- Capture stable Work Center output from the current V5 implementation before patching.
\set ON_ERROR_STOP on

drop table if exists private._workcenter_v5_baseline_test;
create table private._workcenter_v5_baseline_test(
  work_item_id uuid primary key,
  status text,
  bucket text,
  requires_my_decision boolean,
  available_actions jsonb not null
);

do $$
declare
  v_cfo uuid:='00000000-0000-4000-8000-000000000001'::uuid;
  v_started timestamptz;
  v_elapsed numeric;
  v_payload jsonb;
begin
  perform set_config('request.jwt.claim.sub',v_cfo::text,true);
  v_started:=clock_timestamp();
  v_payload:=public.get_workcenter_dashboard_v5('team','{}'::jsonb);
  v_elapsed:=extract(epoch from(clock_timestamp()-v_started))*1000;

  insert into private._workcenter_v5_baseline_test(
    work_item_id,status,bucket,requires_my_decision,available_actions
  )
  select
    (x->>'work_item_id')::uuid,
    x->>'status',
    x->>'bucket',
    coalesce((x->>'requires_my_decision')::boolean,false),
    coalesce(x->'available_actions','[]'::jsonb)
  from jsonb_array_elements(v_payload->'items') x;

  if (select count(*) from private._workcenter_v5_baseline_test) < 1300 then
    raise exception 'Baseline dashboard returned insufficient items';
  end if;

  raise notice 'BASELINE_WORKCENTER_V5_MS=%',round(v_elapsed,1);
end $$;
