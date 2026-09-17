-- Sanam Finance Portal V3.3
-- Governed edit/delete for imprest fund accounts.

-- Preserve existing create capability for operational roles, but restrict changes/deletion to management.
drop policy if exists imprest_manage on public.imprest_funds;
drop policy if exists imprest_insert on public.imprest_funds;
drop policy if exists imprest_update on public.imprest_funds;
drop policy if exists imprest_delete on public.imprest_funds;

create policy imprest_insert on public.imprest_funds
for insert to authenticated
with check (private.current_role() in ('CFO','Supervisor','BankAccountant','APAccountant'));

create policy imprest_update on public.imprest_funds
for update to authenticated
using (private.current_role() in ('CFO','Supervisor'))
with check (private.current_role() in ('CFO','Supervisor'));

create policy imprest_delete on public.imprest_funds
for delete to authenticated
using (private.current_role() in ('CFO','Supervisor'));

create or replace function public.update_imprest_fund(
  p_fund_id uuid,
  p_type text,
  p_company text,
  p_name text,
  p_custodian_id uuid,
  p_balance numeric,
  p_unsettled numeric,
  p_aging integer,
  p_status text
) returns public.imprest_funds
language plpgsql security definer
set search_path='public','private','pg_temp'
as $$
declare
  v_old public.imprest_funds%rowtype;
  v_new public.imprest_funds%rowtype;
begin
  if private.current_role() not in ('CFO','Supervisor') then
    raise exception 'NOT_AUTHORIZED_TO_EDIT_IMPREST';
  end if;
  select * into v_old from public.imprest_funds where id=p_fund_id for update;
  if not found then raise exception 'IMPREST_NOT_FOUND'; end if;
  if nullif(trim(coalesce(p_company,'')),'') is null or nullif(trim(coalesce(p_name,'')),'') is null then
    raise exception 'IMPREST_COMPANY_AND_NAME_REQUIRED';
  end if;
  if coalesce(p_balance,0)<0 or coalesce(p_unsettled,0)<0 or coalesce(p_aging,0)<0 then
    raise exception 'IMPREST_VALUES_MUST_BE_NON_NEGATIVE';
  end if;

  update public.imprest_funds set
    type=coalesce(nullif(trim(p_type),''),type),
    company=trim(p_company),
    name=trim(p_name),
    custodian_id=p_custodian_id,
    balance=coalesce(p_balance,0),
    unsettled=coalesce(p_unsettled,0),
    aging=coalesce(p_aging,0),
    status=coalesce(nullif(trim(p_status),''),status),
    updated_at=now()
  where id=p_fund_id
  returning * into v_new;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'UPDATE_IMPREST_FUND','imprest_fund',p_fund_id::text,
    jsonb_build_object(
      'old',jsonb_build_object('type',v_old.type,'company',v_old.company,'name',v_old.name,'custodian_id',v_old.custodian_id,'balance',v_old.balance,'unsettled',v_old.unsettled,'aging',v_old.aging,'status',v_old.status),
      'new',jsonb_build_object('type',v_new.type,'company',v_new.company,'name',v_new.name,'custodian_id',v_new.custodian_id,'balance',v_new.balance,'unsettled',v_new.unsettled,'aging',v_new.aging,'status',v_new.status)
    ));
  return v_new;
end $$;

create or replace function public.delete_imprest_fund(p_fund_id uuid)
returns void
language plpgsql security definer
set search_path='public','private','pg_temp'
as $$
declare
  v_fund public.imprest_funds%rowtype;
  v_settlement_count integer;
begin
  if private.current_role() not in ('CFO','Supervisor') then
    raise exception 'NOT_AUTHORIZED_TO_DELETE_IMPREST';
  end if;
  select * into v_fund from public.imprest_funds where id=p_fund_id for update;
  if not found then raise exception 'IMPREST_NOT_FOUND'; end if;

  select count(*) into v_settlement_count from public.imprest_settlements where imprest_fund_id=p_fund_id;
  if v_settlement_count>0 then
    raise exception 'IMPREST_HAS_SETTLEMENT_HISTORY';
  end if;
  if coalesce(v_fund.balance,0)<>0 or coalesce(v_fund.unsettled,0)<>0 then
    raise exception 'IMPREST_HAS_OPEN_BALANCE';
  end if;

  delete from public.imprest_funds where id=p_fund_id;
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'DELETE_IMPREST_FUND','imprest_fund',p_fund_id::text,
    jsonb_build_object('type',v_fund.type,'company',v_fund.company,'name',v_fund.name,'custodian_id',v_fund.custodian_id,'balance',v_fund.balance,'unsettled',v_fund.unsettled,'aging',v_fund.aging,'status',v_fund.status));
end $$;

revoke all on function public.update_imprest_fund(uuid,text,text,text,uuid,numeric,numeric,integer,text) from public,anon;
revoke all on function public.delete_imprest_fund(uuid) from public,anon;
grant execute on function public.update_imprest_fund(uuid,text,text,text,uuid,numeric,numeric,integer,text) to authenticated;
grant execute on function public.delete_imprest_fund(uuid) to authenticated;
