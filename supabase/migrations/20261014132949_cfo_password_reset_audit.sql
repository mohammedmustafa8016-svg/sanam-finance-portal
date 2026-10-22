
create function public.cfo_log_password_reset_request(p_email text)
returns jsonb
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $function$
declare
  v_email text := lower(trim(coalesce(p_email,'')));
  v_name text;
  v_profile_id uuid;
begin
  if private.current_role() <> 'CFO' then
    raise exception 'Only CFO can initiate user password reset';
  end if;

  if v_email='' or v_email !~* '^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$' then
    raise exception 'VALID_EMAIL_REQUIRED';
  end if;

  select full_name
    into v_name
  from public.allowed_users
  where lower(email)=v_email
    and active=true
  limit 1;

  if v_name is null then
    raise exception 'ACTIVE_PORTAL_USER_NOT_FOUND';
  end if;

  select id
    into v_profile_id
  from public.profiles
  where lower(email)=v_email
  limit 1;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(
    auth.uid(),
    'CFO_PASSWORD_RESET_REQUEST',
    case when v_profile_id is null then 'allowed_user' else 'profile' end,
    coalesce(v_profile_id::text,v_email),
    jsonb_build_object(
      'target_email',v_email,
      'target_name',v_name,
      'delivery_method','SUPABASE_AUTH_RECOVERY_EMAIL',
      'password_visible_to_cfo',false
    )
  );

  return jsonb_build_object(
    'email',v_email,
    'full_name',v_name,
    'profile_id',v_profile_id,
    'logged',true
  );
end;
$function$;

revoke all on function public.cfo_log_password_reset_request(text)
from public, anon, authenticated;

grant execute on function public.cfo_log_password_reset_request(text)
to authenticated;

comment on function public.cfo_log_password_reset_request(text) is
'CFO-only audit RPC for initiating a secure password-reset email. It never reads, sets, or returns a user password.';
