alter table public.payments add column operation_type text not null default 'Payment';

create function private.validate_payment_operation() returns trigger
language plpgsql set search_path='' as $$
begin
  if tg_op='UPDATE' and new.operation_type is distinct from old.operation_type then
    raise exception 'PAYMENT_OPERATION_TYPE_FIXED';
  end if;
  if not ((new.operation_type='Bank Action' and new.amount=0)
    or (new.operation_type in ('Payment','Refund') and new.amount>0 and new.amount::text<>'NaN')) then
    raise exception 'PAYMENT_OPERATION_AMOUNT_INVALID';
  end if;
  return new;
end $$;
revoke all on function private.validate_payment_operation() from public,anon,authenticated;
create trigger validate_payment_operation before insert or update of operation_type,amount on public.payments
for each row execute function private.validate_payment_operation();

create or replace function private.apply_executed_payment_bank_balance() returns trigger
language plpgsql security definer set search_path='public','private','pg_temp'
as $$
declare
  v_before numeric(18,2);
  v_after numeric(18,2);
  prior_flag text:=current_setting('app.auto_payment_balance',true);
begin
  if old.status is not distinct from new.status or new.status <> 'منفذ' or new.operation_type='Bank Action' then
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

  v_after:=v_before+case when new.operation_type='Refund' then new.amount else -new.amount end;
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

create or replace function public.cfo_override_payment_status_v2(
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
        reversed_amount:=case when v.operation_type='Refund' then -v.amount else v.amount end;
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

create or replace function public.update_unapproved_payment(
  p_payment_id uuid,
  p_due_date date,
  p_company text,
  p_beneficiary text,
  p_amount numeric,
  p_bank_account_id uuid,
  p_priority text,
  p_documents_status text,
  p_purpose text default null
)
returns void
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $$
declare
  v_role text := private.current_role();
  v_old public.payments%rowtype;
  v_material_change boolean := false;
  v_post_approval_edit boolean := false;
begin
  if v_role <> all(array['CFO'::text,'Supervisor'::text,'BankAccountant'::text]) then
    raise exception 'Not authorized to edit payment';
  end if;
  select * into v_old from public.payments where id=p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if v_old.executed_at is not null or v_old.posted_at is not null or v_old.status='مرحّل' then
    raise exception 'Execution or posting prevents editing';
  end if;
  if v_old.cfo_status='موافق' and v_role<>'CFO' then
    raise exception 'Only CFO can edit a CFO-approved payment before execution';
  end if;
  if v_old.operation_type<>'Bank Action' and coalesce(p_amount,0)<=0 then raise exception 'Amount must be greater than zero'; end if;

  v_post_approval_edit := (v_old.cfo_status='موافق' and v_role='CFO');
  v_material_change :=
    coalesce(v_old.company,'') is distinct from coalesce(p_company,'') or
    coalesce(v_old.beneficiary,'') is distinct from coalesce(p_beneficiary,'') or
    v_old.amount is distinct from p_amount or
    v_old.bank_account_id is distinct from p_bank_account_id;

  if not v_post_approval_edit then
    -- Existing behavior remains unchanged before final CFO approval.
    update public.payments
       set due_date=p_due_date,company=p_company,beneficiary=p_beneficiary,amount=p_amount,
           bank_account_id=p_bank_account_id,priority=p_priority,documents_status=p_documents_status,
           purpose=nullif(trim(coalesce(p_purpose,'')),''),
           supervisor_status='معلق',supervisor_approved_by=null,supervisor_approved_at=null,
           cfo_status='معلق',cfo_approved_by=null,cfo_approved_at=null,updated_at=now()
     where id=p_payment_id;
    insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
    values(auth.uid(),'EDIT_UNAPPROVED_PAYMENT','payment',p_payment_id::text,
      jsonb_build_object('company',p_company,'beneficiary',p_beneficiary,'amount',p_amount,'bank_account_id',p_bank_account_id,'approval_reset',true));
  elsif v_material_change then
    -- Critical commercial/bank changes require the full approval chain again.
    update public.payments
       set due_date=p_due_date,company=p_company,beneficiary=p_beneficiary,amount=p_amount,
           bank_account_id=p_bank_account_id,priority=p_priority,documents_status=p_documents_status,
           purpose=nullif(trim(coalesce(p_purpose,'')),''),
           supervisor_status='معلق',supervisor_approved_by=null,supervisor_approved_at=null,
           cfo_status='معلق',cfo_approved_by=null,cfo_approved_at=null,
           status='بانتظار مراجعة المشرف',updated_at=now()
     where id=p_payment_id;
    insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
    values(auth.uid(),'CFO_EDIT_APPROVED_PAYMENT','payment',p_payment_id::text,
      jsonb_build_object('approval_reset','FULL','material_change',true,
        'before',jsonb_build_object('company',v_old.company,'beneficiary',v_old.beneficiary,'amount',v_old.amount,'bank_account_id',v_old.bank_account_id,'due_date',v_old.due_date,'priority',v_old.priority,'documents_status',v_old.documents_status,'purpose',v_old.purpose),
        'after',jsonb_build_object('company',p_company,'beneficiary',p_beneficiary,'amount',p_amount,'bank_account_id',p_bank_account_id,'due_date',p_due_date,'priority',p_priority,'documents_status',p_documents_status,'purpose',p_purpose)));
  else
    -- Non-critical changes keep Supervisor approval but require CFO re-approval.
    update public.payments
       set due_date=p_due_date,company=p_company,beneficiary=p_beneficiary,amount=p_amount,
           bank_account_id=p_bank_account_id,priority=p_priority,documents_status=p_documents_status,
           purpose=nullif(trim(coalesce(p_purpose,'')),''),
           cfo_status='معلق',cfo_approved_by=null,cfo_approved_at=null,
           status=case when supervisor_status='موافق' then 'بانتظار اعتماد CFO' else 'بانتظار مراجعة المشرف' end,
           updated_at=now()
     where id=p_payment_id;
    insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
    values(auth.uid(),'CFO_EDIT_APPROVED_PAYMENT','payment',p_payment_id::text,
      jsonb_build_object('approval_reset','CFO_ONLY','material_change',false,
        'before',jsonb_build_object('due_date',v_old.due_date,'priority',v_old.priority,'documents_status',v_old.documents_status,'purpose',v_old.purpose),
        'after',jsonb_build_object('due_date',p_due_date,'priority',p_priority,'documents_status',p_documents_status,'purpose',p_purpose)));
  end if;
end;
$$;

create or replace function public.cfo_correct_executed_payment_amount(p_payment_id uuid,p_expected_amount numeric,p_new_amount numeric,p_reason text)
returns void language plpgsql security definer set search_path='' as $$
declare p public.payments%rowtype;b public.bank_accounts%rowtype;e public.payment_bank_balance_effects%rowtype;bank_id uuid;delta numeric;
begin
 if auth.uid() is null or private.current_role() is distinct from 'CFO' then raise exception 'CFO_REQUIRED';end if;
 if p_new_amount is null or p_new_amount::text in ('NaN','Infinity','-Infinity') or p_new_amount<=0 or p_new_amount>=10000000000000000 or p_new_amount<>round(p_new_amount,2) then raise exception 'PAYMENT_CORRECTION_INVALID_AMOUNT';end if;
 if length(trim(coalesce(p_reason,''))) not between 10 and 2000 then raise exception 'PAYMENT_CORRECTION_REASON_REQUIRED';end if;
 select bank_account_id into bank_id from public.payments where id=p_payment_id;
 select * into b from public.bank_accounts where id=bank_id for update;
 if not found then raise exception 'PAYMENT_CORRECTION_BANK_REQUIRED';end if;
 select * into p from public.payments where id=p_payment_id for update;
 if not found or p.bank_account_id is distinct from b.id or p.amount is distinct from p_expected_amount then raise exception 'PAYMENT_CORRECTION_STALE_REFRESH';end if;
 if p.executed_at is null or p.status<>'منفذ' or p.posted_at is not null or p.accounting_registered_at is not null then raise exception 'PAYMENT_CORRECTION_REQUIRES_UNREGISTERED_EXECUTED';end if;
 if exists(select 1 from public.imprest_funding_requests where payment_id=p.id) then raise exception 'PAYMENT_CORRECTION_LINKED_IMPREST_REQUIRES_RECONCILIATION';end if;
 if b.account_type<>'Operational' then raise exception 'PAYMENT_CORRECTION_RESERVE_REQUIRES_RECONCILIATION';end if;
 select * into e from public.payment_bank_balance_effects where payment_id=p.id for update;
 if not found or e.bank_account_id<>b.id then raise exception 'PAYMENT_CORRECTION_BALANCE_EFFECT_REQUIRED';end if;
 delta:=p_new_amount-p.amount;
 if delta=0 then return;end if;
 perform set_config('app.auto_payment_balance','1',true);
 update public.bank_accounts set balance=balance+case when p.operation_type='Refund' then delta else -delta end,updated_at=now() where id=b.id;
 perform set_config('app.auto_payment_balance','0',true);
 update public.payments set amount=p_new_amount,updated_at=now() where id=p.id;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'EXECUTED_PAYMENT_AMOUNT_CORRECTED','payment',p.id::text,jsonb_build_object('old_amount',p.amount,'new_amount',p_new_amount,'difference',delta,'bank_account_id',b.id,'bank_balance_before',b.balance,'bank_balance_after',b.balance+case when p.operation_type='Refund' then delta else -delta end,'reason',trim(p_reason),'original_execution_effect',e.amount));
end $$;

CREATE OR REPLACE FUNCTION public.get_daily_payment_mail_preview(p_report_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare payload jsonb;items jsonb;sender public.profiles%rowtype;configuration jsonb;
begin
 if coalesce(private.current_role(),'') not in ('Supervisor','BankAccountant') or not coalesce(public.has_user_permission('page.payments'),false) then raise exception 'MAIL_SENDER_ROLE_REQUIRED';end if;
 if p_report_date is null or p_report_date>(now() at time zone 'Asia/Riyadh')::date then raise exception 'MAIL_REPORT_DATE_INVALID';end if;
 select * into sender from public.profiles where id=auth.uid() and active;
 configuration:=public.get_daily_payment_mail_config();
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'due_date',p.due_date,'company',p.company,'beneficiary',p.beneficiary,'amount',p.amount,
  'bank_account',concat_ws(' — ',b.bank_name,b.account_name),'purpose',p.purpose,'executed_at',p.executed_at) order by p.executed_at,p.id),'[]') into items
 from public.payments p left join public.bank_accounts b on b.id=p.bank_account_id
 where p.operation_type='Payment' and (p.executed_at at time zone 'Asia/Riyadh')::date=p_report_date and p.supervisor_status='موافق' and p.cfo_status='موافق';
 payload:=jsonb_build_object('date',p_report_date,'subject','التحويلات البنكية المنفذة خلال اليوم '||p_report_date::text,
  'sender',jsonb_build_object('id',sender.id,'name',sender.full_name,'email',sender.email,'role',sender.role),
  'to',configuration->'to','cc',configuration->'cc','items',items,'total',(select coalesce(sum((x->>'amount')::numeric),0) from jsonb_array_elements(items) x));
 if jsonb_typeof(configuration->'template')='object' then
  payload:=payload||jsonb_build_object(
    'template',configuration->'template',
    'subject',replace(configuration->'template'->>'subject','{{date}}',p_report_date::text)
  );
 end if;
 return payload||jsonb_build_object(
   'snapshot_hash',encode(extensions.digest(payload::text,'sha256'),'hex'),
   'already_accepted',private.find_accepted_daily_payment_report(p_report_date,payload) is not null
 );
end$function$;

CREATE OR REPLACE FUNCTION public.get_recoverable_reserve_uses(p_bank_account_id uuid)
 RETURNS TABLE(source_type text, source_id uuid, use_date date, amount numeric, restored_amount numeric, outstanding_amount numeric, note text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
begin
  if coalesce(private.current_role(),'') not in ('CFO','Supervisor','BankAccountant') then
    raise exception 'Not authorized to view reserve recovery items';
  end if;
  return query
  with manual as (
    select 'Support Draw'::text source_type,m.id source_id,m.movement_date use_date,m.amount::numeric,
           (coalesce((select sum(r.amount) from public.bank_reserve_movements r where r.movement_type='Restoration' and r.restores_movement_id=m.id),0)+coalesce((select sum(a.amount) from public.reserve_recovery_allocations_v3 a where a.draw_movement_id=m.id),0))::numeric restored_amount,
           m.note::text note
    from public.bank_reserve_movements m
    join public.bank_accounts b on b.id=m.bank_account_id
    where m.bank_account_id=p_bank_account_id and m.movement_type='Support Draw' and m.requires_restoration=true and b.account_type<>'Operational'
  ), pay as (
    select 'Payment'::text source_type,p.id source_id,(p.executed_at at time zone 'Asia/Riyadh')::date use_date,p.amount::numeric,
           (coalesce((select sum(r.amount) from public.bank_reserve_movements r where r.movement_type='Restoration' and r.restores_payment_id=p.id),0)+coalesce((select sum(a.amount) from public.reserve_recovery_allocations_v3 a where a.payment_id=p.id),0))::numeric restored_amount,
           trim(concat_ws(' — ',p.beneficiary,p.purpose))::text note
    from public.payments p
    join public.bank_accounts b on b.id=p.bank_account_id
    where p.bank_account_id=p_bank_account_id and p.company=b.company and p.operation_type='Payment' and p.executed_at is not null and b.account_type<>'Operational'
  ), all_uses as (
    select * from manual union all select * from pay
  )
  select a.source_type,a.source_id,a.use_date,a.amount,a.restored_amount,
         greatest(a.amount-a.restored_amount,0)::numeric as outstanding_amount,a.note
  from all_uses a
  where greatest(a.amount-a.restored_amount,0)>0
  order by a.use_date,a.source_type,a.source_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_reserve_account_movement_report_v2(p_bank_account_id uuid DEFAULT NULL::uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS TABLE(movement_date date, bank_account_id uuid, company text, bank_name text, account_name text, account_type text, movement_type text, source text, reference text, amount numeric, note text, requires_restoration boolean, restored_amount numeric, outstanding_amount numeric, recovery_status text, restoration_target text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
begin
  if private.current_role() <> all(array['CFO'::text,'Supervisor'::text,'BankAccountant'::text]) then
    raise exception 'Not authorized to view reserve account movements';
  end if;
  return query
  with manual_draws as (
    select m.movement_date,b.id bank_account_id,b.company,b.bank_name,b.account_name,b.account_type,
           m.movement_type,'Manual'::text source,m.id::text reference,m.amount::numeric,coalesce(m.note,'')::text note,
           m.requires_restoration,
           (coalesce((select sum(r.amount) from public.bank_reserve_movements r where r.movement_type='Restoration' and r.restores_movement_id=m.id),0)+coalesce((select sum(a.amount) from public.reserve_recovery_allocations_v3 a where a.draw_movement_id=m.id),0))::numeric restored_amount,
           null::text restoration_target
    from public.bank_reserve_movements m join public.bank_accounts b on b.id=m.bank_account_id
    where m.movement_type='Support Draw' and b.account_type<>'Operational'
      and (p_bank_account_id is null or b.id=p_bank_account_id)
      and (p_from is null or m.movement_date>=p_from) and (p_to is null or m.movement_date<=p_to)
  ), restorations as (
    select m.movement_date,b.id bank_account_id,b.company,b.bank_name,b.account_name,b.account_type,
           m.movement_type,'Manual'::text source,m.id::text reference,m.amount::numeric,coalesce(m.note,'')::text note,
           null::boolean requires_restoration,m.amount::numeric restored_amount,
           coalesce(m.restores_movement_id::text,m.restores_payment_id::text,(select string_agg(coalesce(a.draw_movement_id,a.payment_id)::text||' : '||a.amount::text,'; ' order by a.created_at,a.id) from public.reserve_recovery_allocations_v3 a where a.restoration_movement_id=m.id))::text restoration_target
    from public.bank_reserve_movements m join public.bank_accounts b on b.id=m.bank_account_id
    where m.movement_type='Restoration' and b.account_type<>'Operational'
      and (p_bank_account_id is null or b.id=p_bank_account_id)
      and (p_from is null or m.movement_date>=p_from) and (p_to is null or m.movement_date<=p_to)
  ), payment_movements as (
    select (p.executed_at at time zone 'Asia/Riyadh')::date movement_date,b.id bank_account_id,b.company,b.bank_name,b.account_name,b.account_type,
           'Payment Outflow'::text movement_type,'Payment'::text source,p.id::text reference,p.amount::numeric,
           trim(concat_ws(' — ',p.beneficiary,p.purpose))::text note,true::boolean requires_restoration,
           (coalesce((select sum(r.amount) from public.bank_reserve_movements r where r.movement_type='Restoration' and r.restores_payment_id=p.id),0)+coalesce((select sum(a.amount) from public.reserve_recovery_allocations_v3 a where a.payment_id=p.id),0))::numeric restored_amount,
           null::text restoration_target
    from public.payments p join public.bank_accounts b on b.id=p.bank_account_id
    where b.account_type<>'Operational' and p.operation_type='Payment' and p.executed_at is not null
      and (p_bank_account_id is null or b.id=p_bank_account_id)
      and (p_from is null or (p.executed_at at time zone 'Asia/Riyadh')::date>=p_from)
      and (p_to is null or (p.executed_at at time zone 'Asia/Riyadh')::date<=p_to)
  ), u as (
    select * from manual_draws union all select * from restorations union all select * from payment_movements
  )
  select u.movement_date,u.bank_account_id,u.company,u.bank_name,u.account_name,u.account_type,
         u.movement_type,u.source,u.reference,u.amount,u.note,u.requires_restoration,u.restored_amount,
         case when u.movement_type='Restoration' then 0::numeric
              when u.requires_restoration=false then 0::numeric
              else greatest(u.amount-u.restored_amount,0)::numeric end as outstanding_amount,
         case when u.movement_type='Restoration' then 'Restoration'
              when u.requires_restoration=false then 'Not Required'
              when u.restored_amount<=0 then 'Not Restored'
              when u.restored_amount<u.amount then 'Partially Restored'
              else 'Restored' end::text as recovery_status,
         u.restoration_target
  from u
  order by u.movement_date desc,u.bank_account_id,u.source,u.reference;
end;
$function$;

-- Correct liquidity reservation logic.
-- A payment reserves bank liquidity only while it has not been executed.
-- Rejected, on-hold, and posted payments never reserve liquidity.

create or replace view public.bank_liquidity as
select
  b.id,
  b.company,
  b.bank_name,
  b.account_name,
  b.account_no,
  b.balance,
  coalesce(sum(
    case
      when p.operation_type='Payment' and p.executed_at is null
       and p.status not in ('مرفوض','موقوف','مرحّل')
      then p.amount
      else 0::numeric
    end
  ),0::numeric)::numeric(18,2) as reserved_balance,
  (
    b.balance - coalesce(sum(
      case
        when p.operation_type='Payment' and p.executed_at is null
         and p.status not in ('مرفوض','موقوف','مرحّل')
        then p.amount
        else 0::numeric
      end
    ),0::numeric)
  )::numeric(18,2) as available_balance,
  b.updated_at,
  b.account_type
from public.bank_accounts b
left join public.payments p on p.bank_account_id=b.id
group by b.id;

CREATE OR REPLACE FUNCTION public.get_reserve_account_monitor()
 RETURNS TABLE(bank_account_id uuid, company text, bank_name text, account_name text, account_no_last4 text, account_type text, reference_balance numeric, balance numeric, reserved_balance numeric, available_balance numeric, executed_outflows numeric, manual_support_draws numeric, restorations numeric, outstanding_restoration numeric, amount_to_restore_reference numeric, variance_to_reference numeric, last_movement_at timestamp with time zone, last_movement_type text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
with payment_uses as (
  select p.bank_account_id,p.id,p.amount,(coalesce((select sum(r.amount) from public.bank_reserve_movements r where r.movement_type='Restoration' and r.restores_payment_id=p.id),0)+coalesce((select sum(a.amount) from public.reserve_recovery_allocations_v3 a where a.payment_id=p.id),0)) restored
  from public.payments p join public.bank_accounts b on b.id=p.bank_account_id where p.operation_type='Payment' and p.executed_at is not null and b.account_type<>'Operational'
), manual_uses as (
  select m.bank_account_id,m.id,m.amount,m.requires_restoration,m.created_at,(coalesce((select sum(r.amount) from public.bank_reserve_movements r where r.movement_type='Restoration' and r.restores_movement_id=m.id),0)+coalesce((select sum(a.amount) from public.reserve_recovery_allocations_v3 a where a.draw_movement_id=m.id),0)) restored
  from public.bank_reserve_movements m join public.bank_accounts b on b.id=m.bank_account_id where m.movement_type='Support Draw' and b.account_type<>'Operational'
), p as (
  select bank_account_id,coalesce(sum(amount),0)::numeric(18,2) executed_outflows,coalesce(sum(greatest(amount-restored,0)),0)::numeric(18,2) outstanding from payment_uses group by bank_account_id
), m as (
  select bank_account_id,coalesce(sum(amount),0)::numeric(18,2) manual_support_draws,coalesce(sum(greatest(amount-restored,0)) filter(where requires_restoration=true),0)::numeric(18,2) outstanding,max(created_at) last_movement_at from manual_uses group by bank_account_id
), r as (
  select bank_account_id,coalesce(sum(amount),0)::numeric(18,2) restorations,max(created_at) last_movement_at from public.bank_reserve_movements where movement_type='Restoration' group by bank_account_id
), lm as (
  select distinct on(bank_account_id) bank_account_id,movement_type from public.bank_reserve_movements order by bank_account_id,created_at desc
)
select bl.id,bl.company,bl.bank_name,bl.account_name,case when coalesce(bl.account_no,'')='' then null else right(regexp_replace(bl.account_no,'\\s+','','g'),4) end,bl.account_type,b.reference_balance,bl.balance,bl.reserved_balance,bl.available_balance,coalesce(p.executed_outflows,0),coalesce(m.manual_support_draws,0),coalesce(r.restorations,0),(coalesce(p.outstanding,0)+coalesce(m.outstanding,0))::numeric,greatest(coalesce(b.reference_balance,bl.balance)-bl.balance,0)::numeric,case when b.reference_balance is null then null else (b.reference_balance-bl.balance)::numeric end,nullif(greatest(coalesce(m.last_movement_at,'epoch'::timestamptz),coalesce(r.last_movement_at,'epoch'::timestamptz)),'epoch'::timestamptz),lm.movement_type
from public.bank_liquidity bl join public.bank_accounts b on b.id=bl.id left join p on p.bank_account_id=bl.id left join m on m.bank_account_id=bl.id left join r on r.bank_account_id=bl.id left join lm on lm.bank_account_id=bl.id
where bl.account_type<>'Operational' and public.has_user_permission('data.bank_balances') order by case bl.account_type when 'Working Capital Reserve' then 1 when 'VAT Reserve' then 2 else 3 end,bl.company,bl.bank_name;
$function$;
