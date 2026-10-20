
create or replace function private.imprest_opening_ledger_on_insert()
returns trigger
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $function$
declare
  v_delta numeric;
begin
  if coalesce(new.balance,0)>0 then
    insert into public.imprest_ledger_entries(
      imprest_fund_id,entry_type,direction,amount,currency_code,effective_at,
      source_key,description,created_by
    )
    values(
      new.id,'OPENING_BALANCE','INCREASE',new.balance,coalesce(new.currency_code,'SAR'),
      coalesce(new.created_at,now()),
      'OPENING:'||new.id::text,
      'Opening/base imprest funding captured when the fund was created.',
      new.created_by
    )
    on conflict(source_key) do nothing;
  end if;

  v_delta:=coalesce(new.unsettled,0)-coalesce(new.balance,0);
  if abs(v_delta)>0.005 then
    insert into public.imprest_ledger_entries(
      imprest_fund_id,entry_type,direction,amount,currency_code,effective_at,
      source_key,description,created_by
    )
    values(
      new.id,'OPENING_RECONCILIATION',
      case when v_delta>0 then 'INCREASE' else 'DECREASE' end,
      abs(v_delta),coalesce(new.currency_code,'SAR'),
      coalesce(new.created_at,now()),
      'OPENING_RECONCILIATION:'||new.id::text,
      'Opening reconciliation from funded balance to the operational unsettled amount.',
      new.created_by
    )
    on conflict(source_key) do nothing;
  end if;

  return new;
end
$function$;
