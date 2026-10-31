-- Official security hardening migration.
-- seed_permissions_for_user(uuid) is an internal bootstrap helper and must not be
-- callable by ordinary Data API users. Runtime/frontend code does not depend on it.

revoke execute on function public.seed_permissions_for_user(uuid) from public;
revoke execute on function public.seed_permissions_for_user(uuid) from anon;
revoke execute on function public.seed_permissions_for_user(uuid) from authenticated;
grant execute on function public.seed_permissions_for_user(uuid) to service_role;
