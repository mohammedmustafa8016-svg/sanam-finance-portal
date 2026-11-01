-- Serialize the recovery target as well as its bank. Preserve existing CFO reclassification authority.
create or replace function public.record_reserve_restoration_v3(p_bank_account_id uuid,p_amount numeric,p_movement_date date,p_note text,p_allocations jsonb,p_request_id uuid)
returns uuid language plpgsql security definer set search_path=public,private,pg_temp as $$
declare bank public.bank_accounts%rowtype;existing public.bank_reserve_movements%rowtype;entry jsonb;item record;total numeric;receipt uuid;target uuid;kind text;part numeric;remaining numeric;
begin
 if coalesce(private.current_role(),'') not in ('Supervisor','BankAccountant') or not coalesce(public.has_user_permission('data.bank_balances'),false) then raise exception 'RESERVE_MOVEMENT_ROLE_REQUIRED';end if;
 if p_request_id is null or p_movement_date is null or p_amount is null or p_amount<=0 or p_amount::text in ('NaN','Infinity','-Infinity') or p_amount<>round(p_amount,2) then raise exception 'RESERVE_VALID_RECEIPT_REQUIRED';end if;
 if jsonb_typeof(p_allocations) is distinct from 'array' or jsonb_array_length(p_allocations) not between 1 and 100 then raise exception 'RESERVE_ALLOCATIONS_REQUIRED';end if;
 select * into bank from public.bank_accounts where id=p_bank_account_id for update;
 if not found or bank.account_type='Operational' then raise exception 'RESERVE_ACCOUNT_REQUIRED';end if;
 select * into existing from public.bank_reserve_movements where restoration_request_id=p_request_id;
 if found then
  if existing.created_by<>auth.uid() or existing.bank_account_id<>p_bank_account_id or existing.amount<>p_amount or existing.movement_date<>p_movement_date or coalesce(existing.note,'')<>coalesce(nullif(trim(p_note),''),'') then raise exception 'RESERVE_REQUEST_CONFLICT';end if;
  if (select coalesce(jsonb_agg(jsonb_build_object('source_type',case when a.payment_id is not null then 'Payment' else 'Support Draw' end,'source_id',coalesce(a.payment_id,a.draw_movement_id),'amount',a.amount) order by coalesce(a.payment_id,a.draw_movement_id)), '[]') from public.reserve_recovery_allocations_v3 a where a.restoration_movement_id=existing.id)
   is distinct from (select jsonb_agg(jsonb_build_object('source_type',e->>'source_type','source_id',(e->>'source_id')::uuid,'amount',(e->>'amount')::numeric) order by (e->>'source_id')::uuid) from jsonb_array_elements(p_allocations) e) then raise exception 'RESERVE_REQUEST_CONFLICT';end if;
  return existing.id;
 end if;
 select sum((e->>'amount')::numeric) into total from jsonb_array_elements(p_allocations) e;
 if total is distinct from p_amount then raise exception 'RESERVE_ALLOCATION_TOTAL_MISMATCH';end if;
 if exists(select 1 from jsonb_array_elements(p_allocations) e group by e->>'source_id' having count(*)>1) then raise exception 'RESERVE_DUPLICATE_TARGET';end if;
 for entry in select value from jsonb_array_elements(p_allocations) order by value->>'source_id' loop
  target:=(entry->>'source_id')::uuid;kind:=entry->>'source_type';part:=(entry->>'amount')::numeric;
  if target is null or kind not in ('Payment','Support Draw') or kind is null or part is null or part<=0 or part::text in ('NaN','Infinity','-Infinity') or part<>round(part,2) then raise exception 'RESERVE_INVALID_ALLOCATION';end if;
  if kind='Payment' then perform 1 from public.payments where id=target for update;else perform 1 from public.bank_reserve_movements where id=target for update;end if;
  select outstanding_amount into remaining from public.get_recoverable_reserve_uses(p_bank_account_id) where source_id=target and source_type=kind;
  if not found or part>remaining then raise exception 'RESERVE_ALLOCATION_EXCEEDS_OUTSTANDING';end if;
 end loop;
 insert into public.bank_reserve_movements(bank_account_id,movement_type,amount,movement_date,note,created_by,requires_restoration,restoration_request_id)
 values(p_bank_account_id,'Restoration',p_amount,p_movement_date,nullif(trim(p_note),''),auth.uid(),null,p_request_id) returning id into receipt;
 insert into public.reserve_recovery_allocations_v3(restoration_movement_id,draw_movement_id,payment_id,amount,allocated_by)
 select receipt,case when e->>'source_type'='Support Draw' then (e->>'source_id')::uuid end,case when e->>'source_type'='Payment' then (e->>'source_id')::uuid end,(e->>'amount')::numeric,auth.uid() from jsonb_array_elements(p_allocations) e;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'RESERVE_RESTORATION_ALLOCATED','bank_reserve_movement',receipt::text,jsonb_build_object('bank_account_id',p_bank_account_id,'amount',p_amount,'allocations',p_allocations,'request_id',p_request_id));
 return receipt;
end$$;

CREATE OR REPLACE FUNCTION public.record_reserve_movement(p_bank_account_id uuid, p_movement_type text, p_amount numeric, p_movement_date date DEFAULT CURRENT_DATE, p_note text DEFAULT NULL::text, p_requires_restoration boolean DEFAULT true, p_restores_movement_id uuid DEFAULT NULL::uuid, p_restores_payment_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  v_id uuid;
  v_type text;
  v_target public.bank_reserve_movements%rowtype;
  v_payment public.payments%rowtype;
  v_restored numeric := 0;
  v_outstanding numeric := 0;
begin
  if coalesce(private.current_role(),'') not in ('Supervisor','BankAccountant') or not coalesce(public.has_user_permission('data.bank_balances'),false) then
    raise exception 'Not authorized to record reserve movements';
  end if;
  if p_movement_type not in ('Support Draw','Restoration') then
    raise exception 'Invalid reserve movement type';
  end if;
  if p_amount is null or p_amount<=0 or p_amount::text in ('NaN','Infinity','-Infinity') or p_amount<>round(p_amount,2) then
    raise exception 'Amount must be greater than zero';
  end if;

  select account_type into v_type from public.bank_accounts where id=p_bank_account_id for update;
  if v_type is null then raise exception 'Bank account not found'; end if;
  if v_type='Operational' then raise exception 'Reserve movement can only be recorded for a protected account type'; end if;

  if p_movement_type='Support Draw' then
    if p_restores_movement_id is not null or p_restores_payment_id is not null then
      raise exception 'Support draw cannot reference a restoration target';
    end if;
    insert into public.bank_reserve_movements(
      bank_account_id,movement_type,amount,movement_date,note,created_by,requires_restoration
    ) values(
      p_bank_account_id,'Support Draw',p_amount,coalesce(p_movement_date,current_date),
      nullif(trim(coalesce(p_note,'')),''),auth.uid(),coalesce(p_requires_restoration,true)
    ) returning id into v_id;
  else
    if ((p_restores_movement_id is not null)::int + (p_restores_payment_id is not null)::int) <> 1 then
      raise exception 'Restoration must reference exactly one recoverable reserve use';
    end if;

    if p_restores_movement_id is not null then
      select * into v_target
      from public.bank_reserve_movements
      where id=p_restores_movement_id
      for update;
      if not found or v_target.movement_type<>'Support Draw' or coalesce(v_target.requires_restoration,false)=false then
        raise exception 'Recoverable support draw not found';
      end if;
      if v_target.bank_account_id<>p_bank_account_id then
        raise exception 'Restoration target belongs to another bank account';
      end if;
      select coalesce(sum(amount),0) into v_restored
      from public.bank_reserve_movements
      where movement_type='Restoration' and restores_movement_id=p_restores_movement_id;
      select v_restored+coalesce(sum(amount),0) into v_restored from public.reserve_recovery_allocations_v3 where draw_movement_id=p_restores_movement_id;
      v_outstanding := greatest(v_target.amount-v_restored,0);
    else
      select * into v_payment from public.payments where id=p_restores_payment_id for update;
      if not found or v_payment.bank_account_id<>p_bank_account_id or v_payment.executed_at is null then
        raise exception 'Recoverable protected-account payment not found';
      end if;
      select coalesce(sum(amount),0) into v_restored
      from public.bank_reserve_movements
      where movement_type='Restoration' and restores_payment_id=p_restores_payment_id;
      select v_restored+coalesce(sum(amount),0) into v_restored from public.reserve_recovery_allocations_v3 where payment_id=p_restores_payment_id;
      v_outstanding := greatest(v_payment.amount-v_restored,0);
    end if;

    if p_amount > v_outstanding then
      raise exception 'Restoration amount exceeds outstanding recoverable amount';
    end if;

    insert into public.bank_reserve_movements(
      bank_account_id,movement_type,amount,movement_date,note,created_by,requires_restoration,
      restores_movement_id,restores_payment_id
    ) values(
      p_bank_account_id,'Restoration',p_amount,coalesce(p_movement_date,current_date),
      nullif(trim(coalesce(p_note,'')),''),auth.uid(),null,
      p_restores_movement_id,p_restores_payment_id
    ) returning id into v_id;
  end if;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'RESERVE_MOVEMENT_RECORDED','bank_reserve_movement',v_id::text,
    jsonb_build_object(
      'bank_account_id',p_bank_account_id,
      'movement_type',p_movement_type,
      'amount',p_amount,
      'movement_date',coalesce(p_movement_date,current_date),
      'requires_restoration',case when p_movement_type='Support Draw' then coalesce(p_requires_restoration,true) else null end,
      'restores_movement_id',p_restores_movement_id,
      'restores_payment_id',p_restores_payment_id
    ));
  return v_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.reclassify_reserve_support_draw(p_movement_id uuid, p_requires_restoration boolean, p_reason text)
 RETURNS bank_reserve_movements
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare v public.bank_reserve_movements; v_old boolean; v_restored numeric;
begin
  if not private.is_cfo() then raise exception 'Only CFO can reclassify reserve support draws'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Reclassification reason is required'; end if;
  select * into v from public.bank_reserve_movements where id=p_movement_id for update;
  if not found or v.movement_type<>'Support Draw' then raise exception 'Support draw not found'; end if;
  v_old:=coalesce(v.requires_restoration,true);
  if v_old=p_requires_restoration then return v; end if;
  select coalesce(sum(amount),0) into v_restored from public.bank_reserve_movements where movement_type='Restoration' and restores_movement_id=v.id;
  select v_restored+coalesce(sum(amount),0) into v_restored from public.reserve_recovery_allocations_v3 where draw_movement_id=v.id;
  update public.bank_reserve_movements set requires_restoration=p_requires_restoration where id=v.id returning * into v;
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'RESERVE_DRAW_RECLASSIFIED','bank_reserve_movement',v.id::text,jsonb_build_object('before_requires_restoration',v_old,'after_requires_restoration',p_requires_restoration,'reason',trim(p_reason),'linked_restorations',v_restored));
  return v;
end $function$;
