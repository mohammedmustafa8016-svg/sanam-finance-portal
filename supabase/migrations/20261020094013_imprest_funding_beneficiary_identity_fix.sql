
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
    and p.proname='request_imprest_funding'
    and pg_get_function_identity_arguments(p.oid)='p_fund_id uuid, p_funding_type text, p_amount numeric, p_purpose text, p_project_cost_center text, p_expected_settlement_date date, p_due_date date, p_bank_account_id uuid, p_priority text, p_documents_status text'
  limit 1;

  if v_def is null then raise exception 'request_imprest_funding not found'; end if;

  v_new:=replace(
    v_def,
    'select coalesce(p.full_name,v_fund.name) into v_beneficiary
  from (select 1) x
  left join public.profiles p on p.id=v_fund.custodian_id;',
    'v_beneficiary:=v_fund.name;'
  );

  if v_new=v_def then
    raise exception 'imprest funding beneficiary identity patch made no change';
  end if;

  execute v_new;
end
$patch$;
