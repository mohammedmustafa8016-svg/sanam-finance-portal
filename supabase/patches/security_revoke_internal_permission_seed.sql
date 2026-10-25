-- Development-only security hardening candidate.
-- Internal migration/bootstrap helper; no frontend/runtime client dependency.
-- Keep backend/service access while removing ordinary authenticated execution.

revoke execute on function public.seed_permissions_for_user(uuid) from public;
revoke execute on function public.seed_permissions_for_user(uuid) from anon;
revoke execute on function public.seed_permissions_for_user(uuid) from authenticated;
grant execute on function public.seed_permissions_for_user(uuid) to service_role;
