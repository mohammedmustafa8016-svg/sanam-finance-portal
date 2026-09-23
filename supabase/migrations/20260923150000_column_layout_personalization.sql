-- Optional role-level default column layouts.
-- Additive only: personal layouts continue to live in localStorage and take precedence.
-- No existing page, workflow, KPI, or permission behavior is changed unless the CFO explicitly saves a role default.

create table if not exists public.column_layout_defaults (
  role text not null,
  table_key text not null,
  config jsonb not null default '{}'::jsonb,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now(),
  primary key(role,table_key),
  constraint column_layout_defaults_role_check check (
    role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant','Viewer')
  ),
  constraint column_layout_defaults_table_key_check check (length(trim(table_key)) between 1 and 160),
  constraint column_layout_defaults_config_check check (jsonb_typeof(config)='object')
);

alter table public.column_layout_defaults enable row level security;

revoke all on table public.column_layout_defaults from public;
revoke all on table public.column_layout_defaults from anon;
revoke all on table public.column_layout_defaults from authenticated;

drop policy if exists column_layout_defaults_deny_direct_access on public.column_layout_defaults;
create policy column_layout_defaults_deny_direct_access
on public.column_layout_defaults
as restrictive
for all
to public
using (false)
with check (false);

create or replace function public.get_my_column_layout_defaults()
returns table(
  table_key text,
  config jsonb,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path to 'public','private','pg_temp'
as $function$
declare
  v_role text:=private.current_role();
begin
  if auth.uid() is null then raise exception 'AUTHENTICATION_REQUIRED'; end if;
  if v_role is null then raise exception 'ACTIVE_PROFILE_REQUIRED'; end if;

  return query
  select d.table_key,d.config,d.updated_at
  from public.column_layout_defaults d
  where d.role=v_role
  order by d.table_key;
end
$function$;

create or replace function public.set_column_layout_default(
  p_role text,
  p_table_key text,
  p_config jsonb
)
returns void
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
begin
  if private.current_role()<>'CFO' then
    raise exception 'CFO_REQUIRED';
  end if;

  if p_role not in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant','Viewer') then
    raise exception 'INVALID_ROLE';
  end if;

  if nullif(trim(coalesce(p_table_key,'')),'') is null or length(trim(p_table_key))>160 then
    raise exception 'INVALID_TABLE_KEY';
  end if;

  if p_config is null or jsonb_typeof(p_config)<>'object' then
    raise exception 'INVALID_LAYOUT_CONFIG';
  end if;

  insert into public.column_layout_defaults(role,table_key,config,updated_by,updated_at)
  values(p_role,trim(p_table_key),p_config,auth.uid(),now())
  on conflict(role,table_key)
  do update set
    config=excluded.config,
    updated_by=excluded.updated_by,
    updated_at=excluded.updated_at;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(
    auth.uid(),'COLUMN_LAYOUT_DEFAULT_SET','column_layout_default',
    p_role||':'||trim(p_table_key),
    jsonb_build_object('role',p_role,'table_key',trim(p_table_key))
  );
end
$function$;

create or replace function public.clear_column_layout_default(
  p_role text,
  p_table_key text
)
returns void
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
begin
  if private.current_role()<>'CFO' then
    raise exception 'CFO_REQUIRED';
  end if;

  delete from public.column_layout_defaults
  where role=p_role and table_key=trim(coalesce(p_table_key,''));

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(
    auth.uid(),'COLUMN_LAYOUT_DEFAULT_CLEARED','column_layout_default',
    coalesce(p_role,'')||':'||trim(coalesce(p_table_key,'')),
    jsonb_build_object('role',p_role,'table_key',trim(coalesce(p_table_key,'')))
  );
end
$function$;

revoke all on function public.get_my_column_layout_defaults() from public,anon;
grant execute on function public.get_my_column_layout_defaults() to authenticated,service_role;

revoke all on function public.set_column_layout_default(text,text,jsonb) from public,anon;
grant execute on function public.set_column_layout_default(text,text,jsonb) to authenticated,service_role;

revoke all on function public.clear_column_layout_default(text,text) from public,anon;
grant execute on function public.clear_column_layout_default(text,text) to authenticated,service_role;
