
begin;

create unique index uq_imprest_ledger_reversal_once
  on public.imprest_ledger_entries(reversal_of_entry_id)
  where reversal_of_entry_id is not null;

create function private.imprest_is_closed_status(p_status text)
returns boolean
language sql
immutable
set search_path='public','private','pg_temp'
as $function$
  select lower(trim(coalesce(p_status,''))) in (
    'closed','cancelled','final settled',
    'مغلق','ملغي','ملغاة','تمت التصفية النهائية','مصفي نهائي'
  )
$function$;

create function private.guard_imprest_duplicate()
returns trigger
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $function$
declare
  v_duplicate public.imprest_funds%rowtype;
  v_override boolean:=coalesce(new.duplicate_override,false);
begin
  new.company:=trim(new.company);
  new.name:=trim(new.name);
  new.currency_code:=upper(trim(coalesce(new.currency_code,'SAR')));

  if tg_op='UPDATE'
     and new.company is not distinct from old.company
     and new.name is not distinct from old.name
     and new.custodian_id is not distinct from old.custodian_id
     and new.currency_code is not distinct from old.currency_code then
    return new;
  end if;

  select f.* into v_duplicate
  from public.imprest_funds f
  where (tg_op='INSERT' or f.id<>new.id)
    and not private.imprest_is_closed_status(f.status)
    and lower(regexp_replace(trim(f.company),'\s+',' ','g'))
        = lower(regexp_replace(trim(new.company),'\s+',' ','g'))
    and upper(coalesce(f.currency_code,'SAR'))=upper(coalesce(new.currency_code,'SAR'))
    and (
      (new.custodian_id is not null and f.custodian_id=new.custodian_id)
      or
      lower(regexp_replace(trim(f.name),'\s+',' ','g'))
        = lower(regexp_replace(trim(new.name),'\s+',' ','g'))
    )
  order by f.created_at
  limit 1;

  if found then
    if not (
      private.current_role()='CFO'
      and v_override=true
      and nullif(trim(coalesce(new.duplicate_override_reason,'')),'') is not null
    ) then
      raise exception 'ACTIVE_IMPREST_DUPLICATE|%|%',v_duplicate.id,v_duplicate.name;
    end if;
    new.duplicate_override_by:=auth.uid();
    new.duplicate_override_at:=now();
  else
    new.duplicate_override:=false;
    new.duplicate_override_reason:=null;
    new.duplicate_override_by:=null;
    new.duplicate_override_at:=null;
  end if;

  return new;
end
$function$;

create trigger trg_guard_imprest_duplicate
before insert or update of company,name,custodian_id,currency_code,duplicate_override,duplicate_override_reason
on public.imprest_funds
for each row execute function private.guard_imprest_duplicate();

create function private.imprest_opening_ledger_on_insert()
returns trigger
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $function$
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
  return new;
end
$function$;

create trigger trg_imprest_opening_ledger
after insert on public.imprest_funds
for each row execute function private.imprest_opening_ledger_on_insert();

create function private.imprest_manual_balance_ledger()
returns trigger
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $function$
declare
  v_delta numeric;
begin
  if coalesce(current_setting('sanam.imprest_internal_update',true),'0')='1' then
    return new;
  end if;

  v_delta:=coalesce(new.balance,0)-coalesce(old.balance,0);
  if v_delta=0 then return new; end if;

  insert into public.imprest_ledger_entries(
    imprest_fund_id,entry_type,direction,amount,currency_code,effective_at,
    source_key,description,created_by
  )
  values(
    new.id,'MANUAL_ADJUSTMENT',
    case when v_delta>0 then 'INCREASE' else 'DECREASE' end,
    abs(v_delta),coalesce(new.currency_code,'SAR'),now(),
    'MANUAL_BALANCE:'||new.id::text||':'||txid_current()::text||':'||extract(epoch from clock_timestamp())::text,
    'Compatibility ledger entry for an authorized manual change to the existing imprest balance field.',
    auth.uid()
  );

  return new;
end
$function$;

create trigger trg_imprest_manual_balance_ledger
after update of balance on public.imprest_funds
for each row execute function private.imprest_manual_balance_ledger();

insert into public.imprest_ledger_entries(
  imprest_fund_id,entry_type,direction,amount,currency_code,effective_at,
  source_key,description,created_by
)
select
  f.id,'OPENING_BALANCE','INCREASE',f.balance,coalesce(f.currency_code,'SAR'),now(),
  'OPENING:'||f.id::text,
  'Opening/base funding snapshot at Imprest Funding Ledger V2 cutover. Existing fund fields were not changed.',
  f.created_by
from public.imprest_funds f
where coalesce(f.balance,0)>0
on conflict(source_key) do nothing;

create function public.get_imprest_duplicate_candidate(
  p_company text,
  p_name text,
  p_custodian_id uuid,
  p_currency_code text default 'SAR'
)
returns table(
  fund_id uuid,
  company text,
  fund_name text,
  custodian_id uuid,
  custodian_name text,
  currency_code text,
  status text
)
language plpgsql
stable
security definer
set search_path='public','private','pg_temp'
as $function$
begin
  if not exists(select 1 from public.profiles p where p.id=auth.uid() and p.active=true) then
    raise exception 'NOT_AUTHORIZED';
  end if;
  if private.current_role()='Viewer' and not public.has_user_permission('page.imprest') then
    raise exception 'NOT_AUTHORIZED';
  end if;

  return query
  select f.id,f.company,f.name,f.custodian_id,p.full_name,coalesce(f.currency_code,'SAR'),f.status
  from public.imprest_funds f
  left join public.profiles p on p.id=f.custodian_id
  where not private.imprest_is_closed_status(f.status)
    and lower(regexp_replace(trim(f.company),'\s+',' ','g'))
        = lower(regexp_replace(trim(coalesce(p_company,'')),'\s+',' ','g'))
    and upper(coalesce(f.currency_code,'SAR'))=upper(coalesce(nullif(trim(p_currency_code),''),'SAR'))
    and (
      (p_custodian_id is not null and f.custodian_id=p_custodian_id)
      or
      lower(regexp_replace(trim(f.name),'\s+',' ','g'))
        = lower(regexp_replace(trim(coalesce(p_name,'')),'\s+',' ','g'))
    )
  order by f.created_at
  limit 1;
end
$function$;

create function public.create_imprest_fund_v2(
  p_type text,
  p_company text,
  p_name text,
  p_custodian_id uuid,
  p_balance numeric,
  p_unsettled numeric,
  p_aging integer,
  p_status text,
  p_currency_code text default 'SAR',
  p_duplicate_override boolean default false,
  p_override_reason text default null
)
returns public.imprest_funds
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $function$
declare
  v_role text:=private.current_role();
  v_fund public.imprest_funds%rowtype;
begin
  if v_role not in ('CFO','Supervisor','BankAccountant','APAccountant') then
    raise exception 'NOT_AUTHORIZED';
  end if;
  if nullif(trim(coalesce(p_company,'')),'') is null
     or nullif(trim(coalesce(p_name,'')),'') is null then
    raise exception 'IMPREST_COMPANY_AND_NAME_REQUIRED';
  end if;
  if coalesce(p_balance,0)<0 or coalesce(p_unsettled,0)<0 or coalesce(p_aging,0)<0 then
    raise exception 'IMPREST_VALUES_MUST_BE_NON_NEGATIVE';
  end if;
  if coalesce(p_duplicate_override,false) and v_role<>'CFO' then
    raise exception 'ONLY_CFO_CAN_OVERRIDE_IMPREST_DUPLICATE';
  end if;
  if coalesce(p_duplicate_override,false)
     and nullif(trim(coalesce(p_override_reason,'')),'') is null then
    raise exception 'DUPLICATE_OVERRIDE_REASON_REQUIRED';
  end if;

  insert into public.imprest_funds(
    type,company,name,custodian_id,balance,unsettled,aging,status,created_by,
    currency_code,duplicate_override,duplicate_override_reason
  )
  values(
    coalesce(nullif(trim(p_type),''),'عامة'),trim(p_company),trim(p_name),p_custodian_id,
    coalesce(p_balance,0),coalesce(p_unsettled,0),coalesce(p_aging,0),
    coalesce(nullif(trim(p_status),''),'سليمة'),auth.uid(),
    upper(coalesce(nullif(trim(p_currency_code),''),'SAR')),
    coalesce(p_duplicate_override,false),
    case when coalesce(p_duplicate_override,false) then trim(p_override_reason) else null end
  )
  returning * into v_fund;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(
    auth.uid(),'CREATE_IMPREST_FUND_V2','imprest_fund',v_fund.id::text,
    jsonb_build_object(
      'company',v_fund.company,'name',v_fund.name,'custodian_id',v_fund.custodian_id,
      'balance',v_fund.balance,'unsettled',v_fund.unsettled,'currency_code',v_fund.currency_code,
      'duplicate_override',v_fund.duplicate_override,
      'duplicate_override_reason',v_fund.duplicate_override_reason
    )
  );

  return v_fund;
end
$function$;

create function public.request_imprest_funding(
  p_fund_id uuid,
  p_funding_type text,
  p_amount numeric,
  p_purpose text,
  p_project_cost_center text,
  p_expected_settlement_date date,
  p_due_date date,
  p_bank_account_id uuid,
  p_priority text default 'عادي',
  p_documents_status text default 'مكتملة'
)
returns jsonb
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $function$
declare
  v_role text:=private.current_role();
  v_fund public.imprest_funds%rowtype;
  v_bank public.bank_accounts%rowtype;
  v_beneficiary text;
  v_payment_id uuid;
  v_request_id uuid:=gen_random_uuid();
begin
  if v_role not in ('CFO','Supervisor','BankAccountant','APAccountant') then
    raise exception 'NOT_AUTHORIZED';
  end if;
  if p_funding_type not in ('TOP_UP','TEMPORARY_FUNDING') then
    raise exception 'INVALID_IMPREST_FUNDING_TYPE';
  end if;
  if p_amount is null or p_amount<=0 then
    raise exception 'FUNDING_AMOUNT_REQUIRED';
  end if;
  if nullif(trim(coalesce(p_purpose,'')),'') is null then
    raise exception 'FUNDING_PURPOSE_REQUIRED';
  end if;
  if p_due_date is null or p_bank_account_id is null then
    raise exception 'PAYMENT_DUE_DATE_AND_BANK_REQUIRED';
  end if;
  if p_funding_type='TEMPORARY_FUNDING' and p_expected_settlement_date is null then
    raise exception 'EXPECTED_SETTLEMENT_DATE_REQUIRED';
  end if;

  select * into v_fund from public.imprest_funds where id=p_fund_id for update;
  if not found then raise exception 'IMPREST_NOT_FOUND'; end if;
  if private.imprest_is_closed_status(v_fund.status) then
    raise exception 'IMPREST_IS_CLOSED';
  end if;

  select * into v_bank from public.bank_accounts where id=p_bank_account_id;
  if not found then raise exception 'BANK_ACCOUNT_NOT_FOUND'; end if;

  select coalesce(p.full_name,v_fund.name) into v_beneficiary
  from (select 1) x
  left join public.profiles p on p.id=v_fund.custodian_id;

  insert into public.payments(
    due_date,company,beneficiary,amount,priority,documents_status,status,
    supervisor_status,cfo_status,bank_account_id,purpose,requested_by
  )
  values(
    p_due_date,v_fund.company,v_beneficiary,p_amount,
    coalesce(nullif(trim(p_priority),''),'عادي'),
    coalesce(nullif(trim(p_documents_status),''),'مكتملة'),
    'بانتظار مراجعة المشرف','معلق','معلق',p_bank_account_id,
    case when p_funding_type='TOP_UP' then 'زيادة عهدة — ' else 'عهدة مؤقتة — ' end
      ||v_fund.name||' — '||trim(p_purpose),
    auth.uid()
  )
  returning id into v_payment_id;

  insert into public.imprest_funding_requests(
    id,imprest_fund_id,funding_type,amount,currency_code,purpose,
    project_cost_center,expected_settlement_date,due_date,bank_account_id,
    priority,documents_status,payment_id,status,requested_by
  )
  values(
    v_request_id,v_fund.id,p_funding_type,p_amount,coalesce(v_fund.currency_code,'SAR'),
    trim(p_purpose),nullif(trim(coalesce(p_project_cost_center,'')),''),
    p_expected_settlement_date,p_due_date,p_bank_account_id,
    coalesce(nullif(trim(p_priority),''),'عادي'),
    coalesce(nullif(trim(p_documents_status),''),'مكتملة'),
    v_payment_id,'PAYMENT_CREATED',auth.uid()
  );

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(
    auth.uid(),'REQUEST_IMPREST_FUNDING','imprest_funding_request',v_request_id::text,
    jsonb_build_object(
      'imprest_fund_id',v_fund.id,'funding_type',p_funding_type,'amount',p_amount,
      'payment_id',v_payment_id,'bank_account_id',p_bank_account_id,
      'purpose',trim(p_purpose),'expected_settlement_date',p_expected_settlement_date
    )
  );

  return jsonb_build_object(
    'funding_request_id',v_request_id,
    'payment_id',v_payment_id,
    'status','PAYMENT_CREATED'
  );
end
$function$;

create function private.sync_imprest_funding_from_payment()
returns trigger
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $function$
declare
  v_req public.imprest_funding_requests%rowtype;
begin
  select * into v_req
  from public.imprest_funding_requests
  where payment_id=new.id
  for update;

  if not found then return new; end if;

  if old.amount is distinct from new.amount
     or old.company is distinct from new.company
     or old.beneficiary is distinct from new.beneficiary
     or old.purpose is distinct from new.purpose then
    raise exception 'IMPREST_FUNDING_PAYMENT_CORE_FIELDS_LOCKED';
  end if;

  if v_req.status='FUNDED' and (
       old.bank_account_id is distinct from new.bank_account_id
       or old.executed_at is distinct from new.executed_at
     ) then
    raise exception 'EXECUTED_IMPREST_FUNDING_PAYMENT_IMMUTABLE';
  end if;

  if v_req.status='PAYMENT_CREATED' then
    update public.imprest_funding_requests
    set due_date=new.due_date,
        bank_account_id=new.bank_account_id,
        priority=new.priority,
        documents_status=new.documents_status,
        updated_at=now()
    where id=v_req.id;

    if old.executed_at is null and new.executed_at is not null then
      perform set_config('sanam.imprest_internal_update','1',true);

      update public.imprest_funds
      set balance=coalesce(balance,0)+v_req.amount,
          unsettled=coalesce(unsettled,0)+v_req.amount,
          updated_at=now()
      where id=v_req.imprest_fund_id;

      perform set_config('sanam.imprest_internal_update','0',true);

      update public.imprest_funding_requests
      set status='FUNDED',
          funded_by=new.executed_by,
          funded_at=new.executed_at,
          updated_at=now()
      where id=v_req.id;

      insert into public.imprest_ledger_entries(
        imprest_fund_id,entry_type,direction,amount,currency_code,effective_at,
        funding_request_id,payment_id,source_key,description,created_by
      )
      values(
        v_req.imprest_fund_id,v_req.funding_type,'INCREASE',v_req.amount,v_req.currency_code,
        new.executed_at,v_req.id,new.id,'FUNDING:'||v_req.id::text,
        case when v_req.funding_type='TOP_UP'
          then 'Executed additional funding/top-up.'
          else 'Executed temporary funding for a specific purpose.'
        end,
        coalesce(new.executed_by,v_req.requested_by)
      )
      on conflict(source_key) do nothing;

      insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
      values(
        coalesce(new.executed_by,auth.uid()),
        'FUND_IMPREST_FROM_EXECUTED_PAYMENT',
        'imprest_funding_request',v_req.id::text,
        jsonb_build_object(
          'imprest_fund_id',v_req.imprest_fund_id,'payment_id',new.id,
          'amount',v_req.amount,'funding_type',v_req.funding_type
        )
      );
    end if;
  end if;

  return new;
end
$function$;

create trigger trg_sync_imprest_funding_from_payment
after update on public.payments
for each row
when (old.id is not distinct from new.id)
execute function private.sync_imprest_funding_from_payment();

create function private.guard_imprest_funding_payment_delete()
returns trigger
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $function$
declare
  v_req public.imprest_funding_requests%rowtype;
begin
  select * into v_req
  from public.imprest_funding_requests
  where payment_id=old.id
  for update;

  if not found then return old; end if;

  if v_req.status='FUNDED' then
    raise exception 'EXECUTED_IMPREST_FUNDING_PAYMENT_IMMUTABLE';
  end if;

  update public.imprest_funding_requests
  set status='CANCELLED',payment_id=null,updated_at=now()
  where id=v_req.id;

  return old;
end
$function$;

create trigger trg_guard_imprest_funding_payment_delete
before delete on public.payments
for each row execute function private.guard_imprest_funding_payment_delete();

create function private.sync_imprest_settlement_ledger()
returns trigger
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $function$
begin
  if new.status='Approved' and old.status is distinct from 'Approved' then
    insert into public.imprest_ledger_entries(
      imprest_fund_id,entry_type,direction,amount,currency_code,effective_at,
      settlement_id,source_key,description,created_by
    )
    select
      new.imprest_fund_id,'SETTLEMENT','DECREASE',new.amount,coalesce(f.currency_code,'SAR'),
      coalesce(new.reviewed_at,new.updated_at,now()),
      new.id,'SETTLEMENT:'||new.id::text,
      'Approved imprest settlement.',
      coalesce(new.reviewed_by,new.created_by)
    from public.imprest_funds f
    where f.id=new.imprest_fund_id
    on conflict(source_key) do nothing;
  elsif old.status='Approved' and new.status is distinct from 'Approved' then
    if not exists(
      select 1 from public.imprest_ledger_entries
      where source_key='SETTLEMENT_REVERSAL:'||new.id::text
    ) then
      insert into public.imprest_ledger_entries(
        imprest_fund_id,entry_type,direction,amount,currency_code,effective_at,
        settlement_id,source_key,description,created_by
      )
      select
        new.imprest_fund_id,'REVERSAL','INCREASE',new.amount,coalesce(f.currency_code,'SAR'),
        now(),new.id,'SETTLEMENT_REVERSAL:'||new.id::text,
        'Automatic ledger reversal because an approved settlement was reopened.',
        auth.uid()
      from public.imprest_funds f
      where f.id=new.imprest_fund_id;

      update public.imprest_funds
      set unsettled=coalesce(unsettled,0)+new.amount,updated_at=now()
      where id=new.imprest_fund_id;
    end if;
  end if;

  return new;
end
$function$;

create trigger trg_sync_imprest_settlement_ledger
after update of status on public.imprest_settlements
for each row execute function private.sync_imprest_settlement_ledger();

create function public.record_imprest_refund(
  p_fund_id uuid,
  p_amount numeric,
  p_refund_date date,
  p_bank_account_id uuid,
  p_reference text,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $function$
declare
  v_role text:=private.current_role();
  v_fund public.imprest_funds%rowtype;
  v_outstanding numeric;
  v_refund_id uuid:=gen_random_uuid();
begin
  if v_role not in ('CFO','Supervisor','BankAccountant') then
    raise exception 'NOT_AUTHORIZED';
  end if;
  if p_amount is null or p_amount<=0 then raise exception 'REFUND_AMOUNT_REQUIRED'; end if;
  if p_refund_date is null or p_bank_account_id is null then
    raise exception 'REFUND_DATE_AND_BANK_REQUIRED';
  end if;
  if nullif(trim(coalesce(p_reference,'')),'') is null then
    raise exception 'REFUND_REFERENCE_REQUIRED';
  end if;

  select * into v_fund from public.imprest_funds where id=p_fund_id for update;
  if not found then raise exception 'IMPREST_NOT_FOUND'; end if;

  select coalesce(sum(case when direction='INCREASE' then amount else -amount end),0)
  into v_outstanding
  from public.imprest_ledger_entries
  where imprest_fund_id=p_fund_id;

  if p_amount>v_outstanding then
    raise exception 'REFUND_EXCEEDS_LEDGER_OUTSTANDING';
  end if;

  insert into public.imprest_refunds(
    id,imprest_fund_id,amount,refund_date,bank_account_id,reference,note,status,recorded_by
  )
  values(
    v_refund_id,p_fund_id,p_amount,p_refund_date,p_bank_account_id,
    trim(p_reference),nullif(trim(coalesce(p_note,'')),''),
    'POSTED',auth.uid()
  );

  insert into public.imprest_ledger_entries(
    imprest_fund_id,entry_type,direction,amount,currency_code,effective_at,
    refund_id,source_key,description,created_by
  )
  values(
    p_fund_id,'REFUND','DECREASE',p_amount,coalesce(v_fund.currency_code,'SAR'),
    (p_refund_date::timestamp + time '12:00') at time zone 'Asia/Riyadh',
    v_refund_id,'REFUND:'||v_refund_id::text,
    'Imprest cash/bank refund: '||trim(p_reference),
    auth.uid()
  );

  update public.imprest_funds
  set unsettled=greatest(coalesce(unsettled,0)-p_amount,0),updated_at=now()
  where id=p_fund_id;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(
    auth.uid(),'RECORD_IMPREST_REFUND','imprest_refund',v_refund_id::text,
    jsonb_build_object(
      'imprest_fund_id',p_fund_id,'amount',p_amount,'refund_date',p_refund_date,
      'bank_account_id',p_bank_account_id,'reference',trim(p_reference)
    )
  );

  return v_refund_id;
end
$function$;

create function public.reverse_imprest_ledger_entry(
  p_entry_id uuid,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $function$
declare
  v_entry public.imprest_ledger_entries%rowtype;
  v_fund public.imprest_funds%rowtype;
  v_reversal_id uuid:=gen_random_uuid();
begin
  if private.current_role()<>'CFO' then
    raise exception 'ONLY_CFO_CAN_REVERSE_IMPREST_LEDGER';
  end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then
    raise exception 'REVERSAL_REASON_REQUIRED';
  end if;

  select * into v_entry
  from public.imprest_ledger_entries
  where id=p_entry_id
  for update;
  if not found then raise exception 'IMPREST_LEDGER_ENTRY_NOT_FOUND'; end if;

  if v_entry.entry_type in ('OPENING_BALANCE','SETTLEMENT','REVERSAL') then
    raise exception 'THIS_LEDGER_ENTRY_CANNOT_BE_REVERSED_HERE';
  end if;
  if exists(select 1 from public.imprest_ledger_entries where reversal_of_entry_id=v_entry.id) then
    raise exception 'IMPREST_LEDGER_ENTRY_ALREADY_REVERSED';
  end if;

  select * into v_fund from public.imprest_funds
  where id=v_entry.imprest_fund_id for update;

  if v_entry.entry_type in ('TOP_UP','TEMPORARY_FUNDING') then
    if coalesce(v_fund.unsettled,0)<v_entry.amount then
      raise exception 'FUNDING_REVERSAL_EXCEEDS_CURRENT_UNSETTLED';
    end if;
    perform set_config('sanam.imprest_internal_update','1',true);
    update public.imprest_funds
    set balance=greatest(coalesce(balance,0)-v_entry.amount,0),
        unsettled=greatest(coalesce(unsettled,0)-v_entry.amount,0),
        updated_at=now()
    where id=v_entry.imprest_fund_id;
    perform set_config('sanam.imprest_internal_update','0',true);

    update public.imprest_funding_requests
    set status='REVERSED',reversed_by=auth.uid(),reversed_at=now(),
        reversal_reason=trim(p_reason),updated_at=now()
    where id=v_entry.funding_request_id;

  elsif v_entry.entry_type='REFUND' then
    update public.imprest_funds
    set unsettled=coalesce(unsettled,0)+v_entry.amount,updated_at=now()
    where id=v_entry.imprest_fund_id;

    update public.imprest_refunds
    set status='REVERSED',reversed_by=auth.uid(),reversed_at=now(),
        reversal_reason=trim(p_reason)
    where id=v_entry.refund_id;

  elsif v_entry.entry_type='MANUAL_ADJUSTMENT' then
    perform set_config('sanam.imprest_internal_update','1',true);
    update public.imprest_funds
    set balance=case when v_entry.direction='INCREASE'
      then greatest(coalesce(balance,0)-v_entry.amount,0)
      else coalesce(balance,0)+v_entry.amount end,
      updated_at=now()
    where id=v_entry.imprest_fund_id;
    perform set_config('sanam.imprest_internal_update','0',true);
  end if;

  insert into public.imprest_ledger_entries(
    id,imprest_fund_id,entry_type,direction,amount,currency_code,effective_at,
    reversal_of_entry_id,source_key,description,created_by
  )
  values(
    v_reversal_id,v_entry.imprest_fund_id,'REVERSAL',
    case when v_entry.direction='INCREASE' then 'DECREASE' else 'INCREASE' end,
    v_entry.amount,v_entry.currency_code,now(),v_entry.id,
    'REVERSAL:'||v_entry.id::text,
    'CFO reversal/correction: '||trim(p_reason),
    auth.uid()
  );

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(
    auth.uid(),'REVERSE_IMPREST_LEDGER_ENTRY','imprest_ledger_entry',v_entry.id::text,
    jsonb_build_object(
      'reversal_entry_id',v_reversal_id,'imprest_fund_id',v_entry.imprest_fund_id,
      'entry_type',v_entry.entry_type,'amount',v_entry.amount,'reason',trim(p_reason)
    )
  );

  return v_reversal_id;
end
$function$;

create function public.get_imprest_funding_overview()
returns table(
  imprest_fund_id uuid,
  currency_code text,
  base_funding numeric,
  additional_funding numeric,
  manual_adjustment_net numeric,
  settled_amount numeric,
  refunded_amount numeric,
  reversal_net numeric,
  ledger_outstanding numeric,
  pending_funding numeric,
  funding_count integer
)
language sql
stable
security definer
set search_path='public','private','pg_temp'
as $function$
with allowed as(
  select exists(select 1 from public.profiles p where p.id=auth.uid() and p.active=true)
    and (private.current_role()<>'Viewer' or public.has_user_permission('page.imprest')) ok
),
l as(
  select
    e.imprest_fund_id,
    coalesce(sum(e.amount) filter(where e.entry_type='OPENING_BALANCE' and e.direction='INCREASE'),0) base_funding,
    coalesce(sum(e.amount) filter(where e.entry_type in ('TOP_UP','TEMPORARY_FUNDING') and e.direction='INCREASE'),0) additional_funding,
    coalesce(sum(case when e.entry_type='MANUAL_ADJUSTMENT' then
      case when e.direction='INCREASE' then e.amount else -e.amount end else 0 end),0) manual_adjustment_net,
    coalesce(sum(e.amount) filter(where e.entry_type='SETTLEMENT' and e.direction='DECREASE'),0) settled_amount,
    coalesce(sum(e.amount) filter(where e.entry_type='REFUND' and e.direction='DECREASE'),0) refunded_amount,
    coalesce(sum(case when e.entry_type='REVERSAL' then
      case when e.direction='INCREASE' then e.amount else -e.amount end else 0 end),0) reversal_net,
    coalesce(sum(case when e.direction='INCREASE' then e.amount else -e.amount end),0) ledger_outstanding
  from public.imprest_ledger_entries e
  group by e.imprest_fund_id
),
p as(
  select r.imprest_fund_id,
         coalesce(sum(r.amount) filter(where r.status='PAYMENT_CREATED'),0) pending_funding,
         count(*) filter(where r.status='FUNDED')::int funding_count
  from public.imprest_funding_requests r
  group by r.imprest_fund_id
)
select
  f.id,coalesce(f.currency_code,'SAR'),
  coalesce(l.base_funding,0)::numeric,
  coalesce(l.additional_funding,0)::numeric,
  coalesce(l.manual_adjustment_net,0)::numeric,
  coalesce(l.settled_amount,0)::numeric,
  coalesce(l.refunded_amount,0)::numeric,
  coalesce(l.reversal_net,0)::numeric,
  coalesce(l.ledger_outstanding,0)::numeric,
  coalesce(p.pending_funding,0)::numeric,
  coalesce(p.funding_count,0)::int
from public.imprest_funds f
cross join allowed a
left join l on l.imprest_fund_id=f.id
left join p on p.imprest_fund_id=f.id
where a.ok
order by f.created_at;
$function$;

create function public.get_imprest_funding_requests(p_fund_id uuid default null)
returns table(
  funding_request_id uuid,
  imprest_fund_id uuid,
  fund_name text,
  company text,
  funding_type text,
  amount numeric,
  currency_code text,
  purpose text,
  project_cost_center text,
  expected_settlement_date date,
  requested_at timestamptz,
  requested_by_name text,
  payment_id uuid,
  payment_status text,
  supervisor_status text,
  cfo_status text,
  executed_at timestamptz,
  bank_name text,
  bank_account_name text,
  request_status text
)
language plpgsql
stable
security definer
set search_path='public','private','pg_temp'
as $function$
begin
  if not exists(select 1 from public.profiles p where p.id=auth.uid() and p.active=true)
     or (private.current_role()='Viewer' and not public.has_user_permission('page.imprest')) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  return query
  select
    r.id,r.imprest_fund_id,f.name,f.company,r.funding_type,r.amount,r.currency_code,
    r.purpose,r.project_cost_center,r.expected_settlement_date,r.requested_at,
    pr.full_name,r.payment_id,p.status,p.supervisor_status,p.cfo_status,p.executed_at,
    b.bank_name,b.account_name,r.status
  from public.imprest_funding_requests r
  join public.imprest_funds f on f.id=r.imprest_fund_id
  left join public.profiles pr on pr.id=r.requested_by
  left join public.payments p on p.id=r.payment_id
  left join public.bank_accounts b on b.id=r.bank_account_id
  where p_fund_id is null or r.imprest_fund_id=p_fund_id
  order by r.created_at desc;
end
$function$;

create function public.get_imprest_ledger_entries(p_fund_id uuid)
returns table(
  ledger_entry_id uuid,
  imprest_fund_id uuid,
  effective_at timestamptz,
  entry_type text,
  direction text,
  amount numeric,
  currency_code text,
  running_balance numeric,
  payment_id uuid,
  settlement_id uuid,
  refund_id uuid,
  funding_request_id uuid,
  reversal_of_entry_id uuid,
  description text,
  created_by_name text
)
language plpgsql
stable
security definer
set search_path='public','private','pg_temp'
as $function$
begin
  if not exists(select 1 from public.profiles p where p.id=auth.uid() and p.active=true)
     or (private.current_role()='Viewer' and not public.has_user_permission('page.imprest')) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  return query
  with x as(
    select e.*,
      sum(case when e.direction='INCREASE' then e.amount else -e.amount end)
      over(partition by e.imprest_fund_id order by e.effective_at,e.created_at,e.id) running_balance
    from public.imprest_ledger_entries e
    where e.imprest_fund_id=p_fund_id
  )
  select
    x.id,x.imprest_fund_id,x.effective_at,x.entry_type,x.direction,x.amount,x.currency_code,
    x.running_balance::numeric,x.payment_id,x.settlement_id,x.refund_id,x.funding_request_id,
    x.reversal_of_entry_id,x.description,p.full_name
  from x
  left join public.profiles p on p.id=x.created_by
  order by x.effective_at desc,x.created_at desc,x.id desc;
end
$function$;

revoke all on function public.get_imprest_duplicate_candidate(text,text,uuid,text)
from public,anon,authenticated;
revoke all on function public.create_imprest_fund_v2(text,text,text,uuid,numeric,numeric,integer,text,text,boolean,text)
from public,anon,authenticated;
revoke all on function public.request_imprest_funding(uuid,text,numeric,text,text,date,date,uuid,text,text)
from public,anon,authenticated;
revoke all on function public.record_imprest_refund(uuid,numeric,date,uuid,text,text)
from public,anon,authenticated;
revoke all on function public.reverse_imprest_ledger_entry(uuid,text)
from public,anon,authenticated;
revoke all on function public.get_imprest_funding_overview()
from public,anon,authenticated;
revoke all on function public.get_imprest_funding_requests(uuid)
from public,anon,authenticated;
revoke all on function public.get_imprest_ledger_entries(uuid)
from public,anon,authenticated;

grant execute on function public.get_imprest_duplicate_candidate(text,text,uuid,text) to authenticated;
grant execute on function public.create_imprest_fund_v2(text,text,text,uuid,numeric,numeric,integer,text,text,boolean,text) to authenticated;
grant execute on function public.request_imprest_funding(uuid,text,numeric,text,text,date,date,uuid,text,text) to authenticated;
grant execute on function public.record_imprest_refund(uuid,numeric,date,uuid,text,text) to authenticated;
grant execute on function public.reverse_imprest_ledger_entry(uuid,text) to authenticated;
grant execute on function public.get_imprest_funding_overview() to authenticated;
grant execute on function public.get_imprest_funding_requests(uuid) to authenticated;
grant execute on function public.get_imprest_ledger_entries(uuid) to authenticated;

commit;
