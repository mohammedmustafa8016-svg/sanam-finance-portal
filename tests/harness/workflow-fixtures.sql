-- Existing Work Center tests assume the optional workflow and rule engines
-- are activated. Use their existing CFO APIs, only inside BEGIN/ROLLBACK.
select set_config('request.jwt.claim.sub',
  (select id::text from public.profiles where role='CFO' and active limit 1),true);
select public.set_workflow_v3_enabled(true,'Disposable regression test precondition');
select public.set_workcenter_rule_engine_enabled(true,'Disposable regression test precondition');
do $$ begin
 if not private.workflow_v3_enabled() or not private.workcenter_rule_engine_enabled() then
   raise exception 'HARNESS_WORKFLOW_PRECONDITION_MISSING';
 end if;
end $$;
