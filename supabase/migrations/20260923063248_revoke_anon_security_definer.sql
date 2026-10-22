-- Minimal hardening: remove anonymous execution from exposed SECURITY DEFINER functions.
-- Function bodies, role checks, workflows, RLS, and authenticated/service-role behavior remain unchanged.

do $$
declare
  r record;
begin
  for r in
    select
      n.nspname as schema_name,
      p.proname as function_name,
      pg_get_function_identity_arguments(p.oid) as identity_args
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where p.prokind='f'
      and n.nspname='public'
      and p.prosecdef
      and has_function_privilege('anon',p.oid,'EXECUTE')
  loop
    -- Preserve the two application execution roles explicitly before removing PUBLIC/anon access.
    execute format(
      'grant execute on function %I.%I(%s) to authenticated, service_role',
      r.schema_name,r.function_name,r.identity_args
    );
    execute format(
      'revoke execute on function %I.%I(%s) from anon',
      r.schema_name,r.function_name,r.identity_args
    );
    execute format(
      'revoke execute on function %I.%I(%s) from public',
      r.schema_name,r.function_name,r.identity_args
    );
  end loop;
end
$$;
