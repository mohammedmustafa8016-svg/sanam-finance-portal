-- Verify optimized Work Center preserves data, authorization, and security contracts.
\set ON_ERROR_STOP on

do $dashboard_compare$
declare
  v_cfo uuid:='00000000-0000-4000-8000-000000000001'::uuid;
  v_started timestamptz;
  v_elapsed numeric;
  v_payload jsonb;
  v_mismatch bigint;
begin
  perform set_config('request.jwt.claim.sub',v_cfo::text,true);
  v_started:=clock_timestamp();
  v_payload:=public.get_workcenter_dashboard_v5('team','{}'::jsonb);
  v_elapsed:=extract(epoch from(clock_timestamp()-v_started))*1000;

  with current_items as (
    select
      (x->>'work_item_id')::uuid work_item_id,
      x->>'status' status,
      x->>'bucket' bucket,
      coalesce((x->>'requires_my_decision')::boolean,false) requires_my_decision,
      coalesce(x->'available_actions','[]'::jsonb) available_actions
    from jsonb_array_elements(v_payload->'items') x
  ),
  mismatches as (
    select coalesce(b.work_item_id,c.work_item_id) work_item_id
    from private._workcenter_v5_baseline_test b
    full join current_items c using(work_item_id)
    where b.work_item_id is null
       or c.work_item_id is null
       or b.status is distinct from c.status
       or b.bucket is distinct from c.bucket
       or b.requires_my_decision is distinct from c.requires_my_decision
       or b.available_actions is distinct from c.available_actions
  )
  select count(*) into v_mismatch from mismatches;

  if v_mismatch <> 0 then
    raise exception 'WORKCENTER_V5_CONTRACT_MISMATCH: % item(s)',v_mismatch;
  end if;

  if v_elapsed > 2000 then
    raise exception 'WORKCENTER_V5_PERFORMANCE_GATE_FAILED: % ms',round(v_elapsed,1);
  end if;

  raise notice 'OPTIMIZED_WORKCENTER_V5_MS=%',round(v_elapsed,1);
  raise notice 'WORKCENTER_V5_CONTRACT_MISMATCHES=0';
end
$dashboard_compare$;

do $security_compare$
declare
  v_mismatch bigint;
begin
  select count(*)
  into v_mismatch
  from private._workcenter_v5_security_baseline_test b
  full join (
    select
      p.prosecdef,
      p.provolatile,
      p.proconfig,
      p.proacl
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='get_workcenter_dashboard_v5'
      and pg_get_function_identity_arguments(p.oid)='p_scope text, p_filters jsonb'
  ) c
    on b.prosecdef is not distinct from c.prosecdef
   and b.provolatile is not distinct from c.provolatile
   and b.proconfig is not distinct from c.proconfig
   and b.proacl is not distinct from c.proacl
  where b.prosecdef is null or c.prosecdef is null;

  if v_mismatch <> 0 then
    raise exception 'WORKCENTER_V5_SECURITY_CONTRACT_CHANGED';
  end if;

  raise notice 'WORKCENTER_V5_SECURITY_CONTRACT=UNCHANGED';
end
$security_compare$;

drop table private._workcenter_v5_security_baseline_test;
drop table private._workcenter_v5_baseline_test;
