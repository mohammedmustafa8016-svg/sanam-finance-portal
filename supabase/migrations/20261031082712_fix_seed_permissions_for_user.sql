-- Formalize the existing seed_permissions_for_user hotfix so clean rebuilds do not depend on manual patches.
-- This migration intentionally preserves the current production function body and execution grants.

create or replace function public.seed_permissions_for_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $function$
declare
  v_role text;
  v_key text;
begin
  select role into v_role
  from public.profiles
  where id = p_user_id;

  if v_role is null then
    return;
  end if;

  foreach v_key in array array[
    'page.dashboard',
    'page.banks',
    'page.payments',
    'page.posted',
    'page.tasks',
    'page.control',
    'page.escalations',
    'page.automation',
    'page.close',
    'page.imprest',
    'page.performance',
    'page.ownership',
    'page.exceptions',
    'page.audit',
    'page.permissions',
    'data.bank_balances'
  ]
  loop
    insert into public.user_permissions(
      user_id,
      permission_key,
      allowed,
      updated_at
    )
    values(
      p_user_id,
      v_key,
      private.default_permission_for_role(v_role, v_key),
      now()
    )
    on conflict(user_id, permission_key) do nothing;
  end loop;
end;
$function$;

revoke all on function public.seed_permissions_for_user(uuid) from public, anon;
grant execute on function public.seed_permissions_for_user(uuid) to authenticated, service_role;