-- Local/disposable development seed.
-- Intentionally contains no Production users, emails, balances, payments, or business data.
-- Synthetic users exist only to exercise role-based functions in local CI.

insert into auth.users (id,email,raw_user_meta_data)
values
  ('00000000-0000-4000-8000-000000000001','cfo@local.invalid','{}'),
  ('00000000-0000-4000-8000-000000000002','supervisor@local.invalid','{}'),
  ('00000000-0000-4000-8000-000000000003','bank.accountant@local.invalid','{}'),
  ('00000000-0000-4000-8000-000000000004','gl.accountant@local.invalid','{}'),
  ('00000000-0000-4000-8000-000000000005','ar.accountant@local.invalid','{}'),
  ('00000000-0000-4000-8000-000000000006','ap.accountant@local.invalid','{}')
on conflict (id) do nothing;
