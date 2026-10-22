alter table public.monthly_close_tasks
  add column if not exists due_date date,
  add column if not exists priority text,
  add column if not exists output text;