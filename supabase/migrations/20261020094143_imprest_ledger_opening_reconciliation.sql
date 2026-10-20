
begin;

alter table public.imprest_ledger_entries
  drop constraint imprest_ledger_entries_entry_type_check;

alter table public.imprest_ledger_entries
  add constraint imprest_ledger_entries_entry_type_check
  check (
    entry_type in (
      'OPENING_BALANCE',
      'OPENING_RECONCILIATION',
      'TOP_UP',
      'TEMPORARY_FUNDING',
      'SETTLEMENT',
      'REFUND',
      'MANUAL_ADJUSTMENT',
      'REVERSAL'
    )
  );

insert into public.imprest_ledger_entries(
  imprest_fund_id,entry_type,direction,amount,currency_code,effective_at,
  source_key,description,created_by
)
select
  f.id,
  'OPENING_RECONCILIATION',
  case when coalesce(f.unsettled,0) < coalesce(f.balance,0) then 'DECREASE' else 'INCREASE' end,
  abs(coalesce(f.unsettled,0)-coalesce(f.balance,0)),
  coalesce(f.currency_code,'SAR'),
  now(),
  'OPENING_RECONCILIATION:'||f.id::text,
  'Cutover reconciliation from opening funded balance to the current operational unsettled amount. Existing imprest values were not changed.',
  f.created_by
from public.imprest_funds f
where abs(coalesce(f.unsettled,0)-coalesce(f.balance,0))>0.005
on conflict(source_key) do nothing;

do $patch$
declare
  v_def text;
  v_new text;
begin
  select pg_get_functiondef(p.oid)
    into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='reverse_imprest_ledger_entry'
    and pg_get_function_identity_arguments(p.oid)='p_entry_id uuid, p_reason text'
  limit 1;

  if v_def is null then raise exception 'reverse_imprest_ledger_entry not found'; end if;

  v_new:=replace(
    v_def,
    'if v_entry.entry_type in (''OPENING_BALANCE'',''SETTLEMENT'',''REVERSAL'') then',
    'if v_entry.entry_type in (''OPENING_BALANCE'',''OPENING_RECONCILIATION'',''SETTLEMENT'',''REVERSAL'') then'
  );

  if v_new=v_def then
    raise exception 'opening reconciliation reversal guard patch made no change';
  end if;

  execute v_new;
end
$patch$;

commit;
