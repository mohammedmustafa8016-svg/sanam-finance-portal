-- Synthetic test data only. The caller wraps this file and each SQL test in
-- BEGIN/ROLLBACK. Never change functions, policies, grants or migration history.
insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at,
  confirmation_token,recovery_token,email_change_token_new,email_change)
select ('00000000-0000-4000-8000-'||lpad(row_number() over(order by email)::text,12,'0'))::uuid,
  '00000000-0000-0000-0000-000000000000','authenticated','authenticated',email,
  crypt('LocalHarness2026!',gen_salt('bf')),now(),
  '{"provider":"email","providers":["email"]}'::jsonb,'{}',now(),now(),'','','',''
from public.allowed_users where email like '%@local.invalid';
do $$ begin
 if (select count(distinct role) from public.profiles where active) < 6 then
   raise exception 'HARNESS_FIXTURE_ROLES_MISSING';
 end if;
end $$;
