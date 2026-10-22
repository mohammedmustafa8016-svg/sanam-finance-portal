
begin;

do $preflight$
declare
  v_count integer;
begin
  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname in (
      'get_reserve_reconciliation_summary_v2',
      'get_reserve_reconciliation_account_v2',
      'get_reserve_movement_ledger_v2',
      'get_reserve_open_draws_v2',
      'get_reserve_reconciliation_exceptions_v2',
      'compare_reserve_v1_v2'
    );

  if v_count <> 0 then
    raise exception 'Reserve Reconciliation V2 read RPC preflight failed: % target functions already exist', v_count;
  end if;
end
$preflight$;

create function public.get_reserve_reconciliation_summary_v2()
returns setof public.reserve_reconciliation_summary_v2
language plpgsql
stable
security definer
set search_path = 'public','private','pg_temp'
as $function$
begin
  if coalesce(private.current_role() not in ('CFO','Supervisor'), true) then
    raise exception 'Not authorized to view Reserve Reconciliation V2';
  end if;

  return query
  select s.*
  from public.reserve_reconciliation_summary_v2 s
  order by s.account_type, s.company, s.bank_name, s.account_name;
end;
$function$;

comment on function public.get_reserve_reconciliation_summary_v2() is
'Read-only governed Shadow Mode RPC for CFO/Supervisor. Returns Reserve Reconciliation V2 summary without modifying V1, V2, workflow, or UI.';

create function public.get_reserve_reconciliation_account_v2(p_bank_account_id uuid)
returns setof public.reserve_reconciliation_summary_v2
language plpgsql
stable
security definer
set search_path = 'public','private','pg_temp'
as $function$
begin
  if coalesce(private.current_role() not in ('CFO','Supervisor'), true) then
    raise exception 'Not authorized to view Reserve Reconciliation V2';
  end if;

  return query
  select s.*
  from public.reserve_reconciliation_summary_v2 s
  where s.bank_account_id = p_bank_account_id;
end;
$function$;

comment on function public.get_reserve_reconciliation_account_v2(uuid) is
'Read-only governed Shadow Mode RPC for CFO/Supervisor. Returns one V2 reserve account summary by existing bank_account_id.';

create function public.get_reserve_movement_ledger_v2(
  p_bank_account_id uuid default null,
  p_from date default null,
  p_to date default null
)
returns setof public.reserve_movement_ledger_v2
language plpgsql
stable
security definer
set search_path = 'public','private','pg_temp'
as $function$
begin
  if coalesce(private.current_role() not in ('CFO','Supervisor'), true) then
    raise exception 'Not authorized to view Reserve Reconciliation V2 movements';
  end if;

  return query
  select l.*
  from public.reserve_movement_ledger_v2 l
  join public.reserve_reconciliation_accounts a
    on a.id = l.reconciliation_account_id
  where (p_bank_account_id is null or a.bank_account_id = p_bank_account_id)
    and (p_from is null or l.movement_date >= p_from)
    and (p_to is null or l.movement_date <= p_to)
  order by l.movement_date desc, l.created_at desc, l.id;
end;
$function$;

comment on function public.get_reserve_movement_ledger_v2(uuid,date,date) is
'Read-only governed Shadow Mode RPC for CFO/Supervisor. Returns V2 movement ledger with optional bank/date filters.';

create function public.get_reserve_open_draws_v2(p_bank_account_id uuid default null)
returns setof public.reserve_draw_status_v2
language plpgsql
stable
security definer
set search_path = 'public','private','pg_temp'
as $function$
begin
  if coalesce(private.current_role() not in ('CFO','Supervisor'), true) then
    raise exception 'Not authorized to view Reserve Reconciliation V2 recovery items';
  end if;

  return query
  select d.*
  from public.reserve_draw_status_v2 d
  join public.reserve_reconciliation_accounts a
    on a.id = d.reconciliation_account_id
  where (p_bank_account_id is null or a.bank_account_id = p_bank_account_id)
    and d.outstanding_amount > 0
  order by d.movement_date, d.draw_movement_id;
end;
$function$;

comment on function public.get_reserve_open_draws_v2(uuid) is
'Read-only governed Shadow Mode RPC for CFO/Supervisor. Returns V2 recoverable draws with outstanding balances only.';

create function public.get_reserve_reconciliation_exceptions_v2(p_bank_account_id uuid default null)
returns setof public.reserve_reconciliation_exceptions
language plpgsql
stable
security definer
set search_path = 'public','private','pg_temp'
as $function$
begin
  if coalesce(private.current_role() not in ('CFO','Supervisor'), true) then
    raise exception 'Not authorized to view Reserve Reconciliation V2 exceptions';
  end if;

  return query
  select e.*
  from public.reserve_reconciliation_exceptions e
  join public.reserve_reconciliation_accounts a
    on a.id = e.reconciliation_account_id
  where (p_bank_account_id is null or a.bank_account_id = p_bank_account_id)
  order by e.detected_at desc, e.id;
end;
$function$;

comment on function public.get_reserve_reconciliation_exceptions_v2(uuid) is
'Read-only governed Shadow Mode RPC for CFO/Supervisor. Returns V2 reconciliation exceptions without any resolution action.';

create function public.compare_reserve_v1_v2(p_bank_account_id uuid default null)
returns setof public.reserve_v1_v2_shadow_comparison
language plpgsql
stable
security definer
set search_path = 'public','private','pg_temp'
as $function$
begin
  if coalesce(private.current_role() not in ('CFO','Supervisor'), true) then
    raise exception 'Not authorized to compare Reserve V1 and V2';
  end if;

  return query
  select c.*
  from public.reserve_v1_v2_shadow_comparison c
  where (p_bank_account_id is null or c.bank_account_id = p_bank_account_id)
  order by c.account_type, c.company, c.bank_name, c.account_name;
end;
$function$;

comment on function public.compare_reserve_v1_v2(uuid) is
'Read-only governed Shadow Mode comparison RPC for CFO/Supervisor. No V1/V2 data, current UI, or workflow is modified.';

revoke all on function public.get_reserve_reconciliation_summary_v2() from public, anon, authenticated;
revoke all on function public.get_reserve_reconciliation_account_v2(uuid) from public, anon, authenticated;
revoke all on function public.get_reserve_movement_ledger_v2(uuid,date,date) from public, anon, authenticated;
revoke all on function public.get_reserve_open_draws_v2(uuid) from public, anon, authenticated;
revoke all on function public.get_reserve_reconciliation_exceptions_v2(uuid) from public, anon, authenticated;
revoke all on function public.compare_reserve_v1_v2(uuid) from public, anon, authenticated;

grant execute on function public.get_reserve_reconciliation_summary_v2() to authenticated;
grant execute on function public.get_reserve_reconciliation_account_v2(uuid) to authenticated;
grant execute on function public.get_reserve_movement_ledger_v2(uuid,date,date) to authenticated;
grant execute on function public.get_reserve_open_draws_v2(uuid) to authenticated;
grant execute on function public.get_reserve_reconciliation_exceptions_v2(uuid) to authenticated;
grant execute on function public.compare_reserve_v1_v2(uuid) to authenticated;

commit;
