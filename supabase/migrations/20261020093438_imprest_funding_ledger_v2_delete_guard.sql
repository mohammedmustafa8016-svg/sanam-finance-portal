
create or replace function public.delete_imprest_fund(p_fund_id uuid)
returns void
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $function$
declare
  v_fund public.imprest_funds%rowtype;
  v_settlement_count integer;
  v_funding_history integer;
begin
  if private.current_role() not in ('CFO','Supervisor') then
    raise exception 'NOT_AUTHORIZED_TO_DELETE_IMPREST';
  end if;

  select * into v_fund
  from public.imprest_funds
  where id=p_fund_id
  for update;
  if not found then raise exception 'IMPREST_NOT_FOUND'; end if;

  select count(*) into v_settlement_count
  from public.imprest_settlements
  where imprest_fund_id=p_fund_id;

  if v_settlement_count>0 then
    raise exception 'IMPREST_HAS_SETTLEMENT_HISTORY';
  end if;

  if coalesce(v_fund.balance,0)<>0 or coalesce(v_fund.unsettled,0)<>0 then
    raise exception 'IMPREST_HAS_OPEN_BALANCE';
  end if;

  select
    (select count(*) from public.imprest_funding_requests where imprest_fund_id=p_fund_id)
    + (select count(*) from public.imprest_refunds where imprest_fund_id=p_fund_id)
    + (select count(*) from public.imprest_ledger_entries where imprest_fund_id=p_fund_id)
  into v_funding_history;

  if v_funding_history>0 then
    raise exception 'IMPREST_HAS_FUNDING_HISTORY';
  end if;

  delete from public.imprest_funds where id=p_fund_id;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(
    auth.uid(),'DELETE_IMPREST_FUND','imprest_fund',p_fund_id::text,
    jsonb_build_object(
      'type',v_fund.type,'company',v_fund.company,'name',v_fund.name,
      'custodian_id',v_fund.custodian_id,'balance',v_fund.balance,
      'unsettled',v_fund.unsettled,'aging',v_fund.aging,'status',v_fund.status
    )
  );
end
$function$;
