alter table public.payment_bank_balance_effects add column reversed_at timestamptz;

-- A separate posting record leaves the original reserve recovery and allocations intact.
create table private.reserve_restoration_balance_postings (
  movement_id uuid primary key references public.bank_reserve_movements(id),
  mode text not null check (mode in ('External','Internal','Already reflected')),
  source_bank_account_id uuid references public.bank_accounts(id),
  reason text not null,
  posted_by uuid not null references public.profiles(id),
  posted_at timestamptz not null default now(),
  check ((mode='Internal') = (source_bank_account_id is not null))
);
revoke all on private.reserve_restoration_balance_postings from public,anon,authenticated;

create function private.apply_reserve_restoration_balance() returns trigger
language plpgsql security definer set search_path='' as $$
declare
  receipt public.bank_reserve_movements%rowtype;
  prior_flag text:=current_setting('app.auto_payment_balance',true);
  balance_before numeric;
  source_before numeric;
begin
  select * into strict receipt from public.bank_reserve_movements where id=new.movement_id;
  if receipt.movement_type is distinct from 'Restoration' then
    raise exception 'RESERVE_RESTORATION_REQUIRED';
  end if;
  if new.source_bank_account_id=receipt.bank_account_id then
    raise exception 'RESERVE_TRANSFER_ACCOUNTS_MUST_DIFFER';
  end if;

  if new.mode<>'Already reflected' then
    perform 1 from public.bank_accounts
    where id in (receipt.bank_account_id,new.source_bank_account_id)
    order by id for update;
    select balance into strict balance_before from public.bank_accounts where id=receipt.bank_account_id;

    perform set_config('app.auto_payment_balance','1',true);
    update public.bank_accounts set balance=balance+receipt.amount,updated_at=now()
    where id=receipt.bank_account_id;

    if new.mode='Internal' then
      select balance into strict source_before from public.bank_accounts where id=new.source_bank_account_id;
      update public.bank_accounts set balance=balance-receipt.amount,updated_at=now()
      where id=new.source_bank_account_id;
    end if;
    perform set_config('app.auto_payment_balance',coalesce(prior_flag,''),true);
  end if;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(new.posted_by,'RESERVE_RESTORATION_BALANCE_POSTED','bank_reserve_movement',receipt.id::text,
    jsonb_build_object('mode',new.mode,'reason',new.reason,'amount',receipt.amount,
      'bank_account_id',receipt.bank_account_id,'source_bank_account_id',new.source_bank_account_id,
      'balance_before',balance_before,'balance_after',balance_before+receipt.amount,
      'source_balance_before',source_before,'source_balance_after',source_before-receipt.amount));
  return new;
end $$;
revoke all on function private.apply_reserve_restoration_balance() from public,anon,authenticated;
create trigger apply_reserve_restoration_balance after insert on private.reserve_restoration_balance_postings
for each row execute function private.apply_reserve_restoration_balance();

create function private.post_reserve_restoration_balance(
  p_movement_id uuid,p_mode text,p_source_bank_account_id uuid,p_reason text
) returns void language plpgsql security invoker set search_path='' as $$
declare posted private.reserve_restoration_balance_postings%rowtype;
begin
  if p_mode is null or p_mode not in ('External','Internal','Already reflected')
     or ((p_mode='Internal') <> (p_source_bank_account_id is not null))
     or nullif(btrim(p_reason),'') is null then
    raise exception 'RESERVE_POSTING_DETAILS_REQUIRED';
  end if;

  insert into private.reserve_restoration_balance_postings(movement_id,mode,source_bank_account_id,reason,posted_by)
  values(p_movement_id,p_mode,p_source_bank_account_id,btrim(p_reason),auth.uid())
  on conflict(movement_id) do nothing;
  if not found then
    select * into strict posted from private.reserve_restoration_balance_postings where movement_id=p_movement_id;
    if posted.mode is distinct from p_mode or posted.source_bank_account_id is distinct from p_source_bank_account_id then
      raise exception 'RESERVE_RESTORATION_ALREADY_RECONCILED';
    end if;
  end if;
end $$;
revoke all on function private.post_reserve_restoration_balance(uuid,text,uuid,text) from public,anon,authenticated;

create function public.record_reserve_restoration_v4(
  p_bank_account_id uuid,p_amount numeric,p_movement_date date,p_note text,
  p_allocations jsonb,p_request_id uuid,p_mode text,p_source_bank_account_id uuid
) returns uuid language plpgsql security definer set search_path='' as $$
declare receipt_id uuid;
begin
  if auth.uid() is null or coalesce(private.current_role(),'') not in ('Supervisor','BankAccountant')
     or not coalesce(public.has_user_permission('data.bank_balances'),false) then
    raise exception 'RESERVE_MOVEMENT_ROLE_REQUIRED';
  end if;
  if p_source_bank_account_id=p_bank_account_id then
    raise exception 'RESERVE_TRANSFER_ACCOUNTS_MUST_DIFFER';
  end if;
  perform 1 from public.bank_accounts where id in (p_bank_account_id,p_source_bank_account_id)
  order by id for update;

  receipt_id:=public.record_reserve_restoration_v3(
    p_bank_account_id,p_amount,p_movement_date,p_note,p_allocations,p_request_id
  );
  perform private.post_reserve_restoration_balance(
    receipt_id,p_mode,p_source_bank_account_id,'Recorded with reserve restoration'
  );
  return receipt_id;
end $$;
revoke all on function public.record_reserve_restoration_v4(uuid,numeric,date,text,jsonb,uuid,text,uuid) from public,anon;
grant execute on function public.record_reserve_restoration_v4(uuid,numeric,date,text,jsonb,uuid,text,uuid) to authenticated;

create function public.cfo_reconcile_reserve_restoration(
  p_movement_id uuid,p_mode text,p_source_bank_account_id uuid,p_reason text
) returns void language plpgsql security definer set search_path='' as $$
declare destination uuid;
begin
  if auth.uid() is null or private.current_role() is distinct from 'CFO' then
    raise exception 'CFO_REQUIRED';
  end if;
  select bank_account_id into destination from public.bank_reserve_movements
  where id=p_movement_id and movement_type='Restoration';
  if not found then raise exception 'RESERVE_RESTORATION_REQUIRED';end if;
  perform 1 from public.bank_accounts where id in (destination,p_source_bank_account_id)
  order by id for update;
  perform private.post_reserve_restoration_balance(p_movement_id,p_mode,p_source_bank_account_id,p_reason);
end $$;
revoke all on function public.cfo_reconcile_reserve_restoration(uuid,text,uuid,text) from public,anon;
grant execute on function public.cfo_reconcile_reserve_restoration(uuid,text,uuid,text) to authenticated;

create or replace function private.apply_executed_payment_bank_balance() returns trigger
language plpgsql security definer set search_path='public','private','pg_temp'
as $$
declare
  v_before numeric(18,2);
  v_after numeric(18,2);
  prior_flag text:=current_setting('app.auto_payment_balance',true);
begin
  if old.status is not distinct from new.status or new.status <> 'منفذ' then
    return new;
  end if;

  if new.bank_account_id is null then
    raise exception 'Executed payment requires a bank account';
  end if;
  if coalesce(new.amount,0) <= 0 then
    raise exception 'Executed payment amount must be greater than zero';
  end if;

  -- Only a formally reversed bank effect can be applied in a later approval cycle.
  if exists(select 1 from public.payment_bank_balance_effects where payment_id=new.id and reversed_at is null) then
    return new;
  end if;

  select balance into v_before
  from public.bank_accounts
  where id=new.bank_account_id
  for update;
  if not found then
    raise exception 'Bank account not found for executed payment';
  end if;

  v_after:=v_before-new.amount;
  perform set_config('app.auto_payment_balance','1',true);
  update public.bank_accounts
     set balance=v_after,updated_at=now()
   where id=new.bank_account_id;
  perform set_config('app.auto_payment_balance',coalesce(prior_flag,''),true);

  insert into public.payment_bank_balance_effects(payment_id,bank_account_id,amount,balance_before,balance_after,applied_by,source_status)
  values(new.id,new.bank_account_id,new.amount,v_before,v_after,auth.uid(),'منفذ')
  on conflict(payment_id) do update
  set bank_account_id=excluded.bank_account_id, amount=excluded.amount,
      balance_before=excluded.balance_before,balance_after=excluded.balance_after,
      applied_at=now(),applied_by=excluded.applied_by,source_status=excluded.source_status,reversed_at=null;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'PAYMENT_BANK_BALANCE_APPLIED','payment',new.id::text,
    jsonb_build_object('bank_account_id',new.bank_account_id,'amount',new.amount,'balance_before',v_before,'balance_after',v_after,'status','منفذ'));

  return new;
end $$;


create function public.cfo_override_payment_status_v2(
  p_payment_id uuid,
  p_status text,
  p_reason text,
  p_reverse_bank_effect boolean
)
returns public.payments
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
declare
  v public.payments;
  v_old text;
  previous_payment public.payments%rowtype;
  bank_effect public.payment_bank_balance_effects%rowtype;
  reversed_amount numeric:=0;
begin
  if auth.uid() is null or private.current_role() is distinct from 'CFO' then raise exception 'Only CFO can override payment status'; end if;
  if p_status not in ('بانتظار مراجعة المشرف','بانتظار اعتماد CFO','معتمد للدفع','منفذ','تم التسجيل','معلقة','مرحّل','مرفوض','موقوف') then
    raise exception 'Invalid payment status';
  end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Override reason is required'; end if;

  select * into v from public.payments where id=p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;

  if p_status='معلقة' then raise exception 'USE_GOVERNED_PAYMENT_PENDING_WORKFLOW'; end if;
  if v.status='معلقة' and p_status not in ('مرفوض','موقوف') then
    raise exception 'RESOLVE_PENDING_THROUGH_GOVERNED_WORKFLOW';
  end if;
  if p_status='مرحّل' and (
      v.status<>'تم التسجيل'
      or v.accounting_registered_at is null
      or v.posted_at is not null
      or coalesce(v.pending_amount,0)>0
    ) then
    raise exception 'PAYMENT_NOT_READY_FOR_FINAL_POSTING';
  end if;

  v_old:=v.status;
  previous_payment:=v;
  if p_status='بانتظار مراجعة المشرف' and (v.accounting_registered_at is not null or v.posted_at is not null) then
    raise exception 'PAYMENT_RESTART_REQUIRES_ACCOUNTING_REVERSAL';
  end if;
  if p_status='بانتظار مراجعة المشرف' and v.executed_at is not null then
    if exists(select 1 from public.imprest_funding_requests where payment_id=v.id and status='FUNDED')
       or exists(select 1 from public.bank_reserve_movements where restores_payment_id=v.id)
       or exists(select 1 from public.reserve_recovery_allocations_v3 where payment_id=v.id) then
      raise exception 'PAYMENT_RESTART_REQUIRES_LINKED_RECONCILIATION';
    end if;

    select * into bank_effect from public.payment_bank_balance_effects
    where payment_id=v.id and reversed_at is null for update;
    if found then
      if bank_effect.bank_account_id is distinct from v.bank_account_id then
        raise exception 'PAYMENT_RESTART_BANK_MISMATCH';
      end if;
      -- A CFO amount correction has already adjusted the bank by the difference.
      if p_reverse_bank_effect is null then
        raise exception 'PAYMENT_RESTART_BANK_EFFECT_REQUIRED';
      end if;
      if p_reverse_bank_effect then
        reversed_amount:=v.amount;
        update public.bank_accounts set balance=balance+reversed_amount,updated_at=now()
        where id=bank_effect.bank_account_id;
      end if;
      update public.payment_bank_balance_effects set reversed_at=now() where payment_id=v.id;
    end if;
  end if;

  if p_status='منفذ'
     and exists(select 1 from public.payment_bank_balance_effects where payment_id=v.id and reversed_at is not null)
     and (v.status is distinct from 'معتمد للدفع' or v.supervisor_status is distinct from 'موافق'
          or v.cfo_status is distinct from 'موافق') then
    raise exception 'PAYMENT_RESTART_REQUIRES_APPROVALS';
  end if;

  update public.payments
  set status=p_status,
      supervisor_status=case
        when p_status='بانتظار مراجعة المشرف' then 'معلق'
        else supervisor_status
      end,
      supervisor_approved_by=case
        when p_status='بانتظار مراجعة المشرف' then null
        else supervisor_approved_by
      end,
      supervisor_approved_at=case
        when p_status='بانتظار مراجعة المشرف' then null
        else supervisor_approved_at
      end,
      cfo_status=case
        when p_status='بانتظار مراجعة المشرف' then 'معلق'
        else cfo_status
      end,
      cfo_approved_by=case
        when p_status='بانتظار مراجعة المشرف' then null
        else cfo_approved_by
      end,
      cfo_approved_at=case
        when p_status='بانتظار مراجعة المشرف' then null
        else cfo_approved_at
      end,
      executed_at=case when p_status='بانتظار مراجعة المشرف' then null when p_status in ('منفذ','تم التسجيل','مرحّل') then coalesce(executed_at,now()) else executed_at end,
      executed_by=case when p_status='بانتظار مراجعة المشرف' then null when p_status in ('منفذ','تم التسجيل','مرحّل') then coalesce(executed_by,auth.uid()) else executed_by end,
      accounting_registered_at=case when p_status in ('تم التسجيل','مرحّل') then coalesce(accounting_registered_at,now()) else accounting_registered_at end,
      accounting_registered_by=case when p_status in ('تم التسجيل','مرحّل') then coalesce(accounting_registered_by,auth.uid()) else accounting_registered_by end,
      registered_amount=case when p_status in ('تم التسجيل','مرحّل') then amount else registered_amount end,
      pending_amount=case when p_status in ('تم التسجيل','مرحّل') then 0 else pending_amount end,
      posted_at=case when p_status='مرحّل' then coalesce(posted_at,now()) else posted_at end,
      posted_by=case when p_status='مرحّل' then coalesce(posted_by,auth.uid()) else posted_by end,
      updated_at=now()
  where id=p_payment_id
  returning * into v;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(
    auth.uid(),
    'CFO_PAYMENT_STATUS_OVERRIDE',
    'payment',
    p_payment_id::text,
    jsonb_build_object(
      'old_status',v_old,
      'new_status',p_status,
      'reason',trim(p_reason),
      'previous_executed_at',previous_payment.executed_at,
      'previous_executed_by',previous_payment.executed_by,
      'previous_supervisor_approved_at',previous_payment.supervisor_approved_at,
      'previous_supervisor_approved_by',previous_payment.supervisor_approved_by,
      'previous_cfo_approved_at',previous_payment.cfo_approved_at,
      'previous_cfo_approved_by',previous_payment.cfo_approved_by,
      'bank_balance_reversed',reversed_amount,
      'bank_effect_already_reconciled',bank_effect.payment_id is not null and p_reverse_bank_effect is false,
      'approval_reset',case when p_status='بانتظار مراجعة المشرف' then 'SUPERVISOR_AND_CFO' else 'NONE' end
    )
  );

  perform private.ensure_payment_workflow_v3(v.id);
  return v;
end
$function$;


revoke all on function public.cfo_override_payment_status_v2(uuid,text,text,boolean) from public,anon;
grant execute on function public.cfo_override_payment_status_v2(uuid,text,text,boolean) to authenticated;

create or replace function public.cfo_override_payment_status(p_payment_id uuid,p_status text,p_reason text)
returns public.payments language sql security invoker set search_path='' as $$
  select public.cfo_override_payment_status_v2(p_payment_id,p_status,p_reason,null);
$$;
