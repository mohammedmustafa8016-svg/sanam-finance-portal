-- CFO daily plan override, reserve draw recovery classification, and CFO post-approval payment editing.
-- Additive migration: preserves existing task ownership, payment workflow, and historical reserve records.

alter table public.bank_reserve_movements
  add column if not exists requires_restoration boolean,
  add column if not exists restores_movement_id uuid references public.bank_reserve_movements(id) on delete restrict,
  add column if not exists restores_payment_id uuid references public.payments(id) on delete restrict;

-- Existing support draws were previously treated as fully recoverable by the monitor.
-- Preserve that historical behavior explicitly.
update public.bank_reserve_movements
set requires_restoration = true
where movement_type = 'Support Draw'
  and requires_restoration is null;

alter table public.bank_reserve_movements
  drop constraint if exists bank_reserve_movements_recovery_shape_chk;

alter table public.bank_reserve_movements
  add constraint bank_reserve_movements_recovery_shape_chk check (
    (movement_type = 'Support Draw'
      and requires_restoration is not null
      and restores_movement_id is null
      and restores_payment_id is null)
    or
    (movement_type = 'Restoration'
      and requires_restoration is null
      and ((restores_movement_id is not null)::int + (restores_payment_id is not null)::int) = 1)
  );

create index if not exists idx_bank_reserve_movements_restores_movement
  on public.bank_reserve_movements(restores_movement_id)
  where restores_movement_id is not null;

create index if not exists idx_bank_reserve_movements_restores_payment
  on public.bank_reserve_movements(restores_payment_id)
  where restores_payment_id is not null;

-- Replace the old 5-argument RPC with the extended named-parameter RPC.
drop function if exists public.record_reserve_movement(uuid,text,numeric,date,text);

create or replace function public.record_reserve_movement(
  p_bank_account_id uuid,
  p_movement_type text,
  p_amount numeric,
  p_movement_date date default current_date,
  p_note text default null,
  p_requires_restoration boolean default true,
  p_restores_movement_id uuid default null,
  p_restores_payment_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $$
declare
  v_id uuid;
  v_type text;
  v_target public.bank_reserve_movements%rowtype;
  v_payment public.payments%rowtype;
  v_restored numeric := 0;
  v_outstanding numeric := 0;
begin
  if private.current_role() <> all(array['CFO'::text,'Supervisor'::text,'BankAccountant'::text]) then
    raise exception 'Not authorized to record reserve movements';
  end if;
  if p_movement_type not in ('Support Draw','Restoration') then
    raise exception 'Invalid reserve movement type';
  end if;
  if coalesce(p_amount,0) <= 0 then
    raise exception 'Amount must be greater than zero';
  end if;

  select account_type into v_type from public.bank_accounts where id=p_bank_account_id;
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
      v_outstanding := greatest(v_target.amount-v_restored,0);
    else
      select * into v_payment from public.payments where id=p_restores_payment_id for update;
      if not found or v_payment.bank_account_id<>p_bank_account_id or v_payment.executed_at is null then
        raise exception 'Recoverable protected-account payment not found';
      end if;
      select coalesce(sum(amount),0) into v_restored
      from public.bank_reserve_movements
      where movement_type='Restoration' and restores_payment_id=p_restores_payment_id;
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
$$;

grant execute on function public.record_reserve_movement(uuid,text,numeric,date,text,boolean,uuid,uuid) to authenticated;

create or replace function public.get_recoverable_reserve_uses(p_bank_account_id uuid)
returns table(
  source_type text,
  source_id uuid,
  use_date date,
  amount numeric,
  restored_amount numeric,
  outstanding_amount numeric,
  note text
)
language plpgsql
stable security definer
set search_path to 'public','private','pg_temp'
as $$
begin
  if private.current_role() <> all(array['CFO'::text,'Supervisor'::text,'BankAccountant'::text]) then
    raise exception 'Not authorized to view reserve recovery items';
  end if;
  return query
  with manual as (
    select 'Support Draw'::text source_type,m.id source_id,m.movement_date use_date,m.amount::numeric,
           coalesce((select sum(r.amount) from public.bank_reserve_movements r where r.movement_type='Restoration' and r.restores_movement_id=m.id),0)::numeric restored_amount,
           m.note::text note
    from public.bank_reserve_movements m
    join public.bank_accounts b on b.id=m.bank_account_id
    where m.bank_account_id=p_bank_account_id and m.movement_type='Support Draw' and m.requires_restoration=true and b.account_type<>'Operational'
  ), pay as (
    select 'Payment'::text source_type,p.id source_id,(p.executed_at at time zone 'Asia/Riyadh')::date use_date,p.amount::numeric,
           coalesce((select sum(r.amount) from public.bank_reserve_movements r where r.movement_type='Restoration' and r.restores_payment_id=p.id),0)::numeric restored_amount,
           trim(concat_ws(' — ',p.beneficiary,p.purpose))::text note
    from public.payments p
    join public.bank_accounts b on b.id=p.bank_account_id
    where p.bank_account_id=p_bank_account_id and p.executed_at is not null and b.account_type<>'Operational'
  ), all_uses as (
    select * from manual union all select * from pay
  )
  select a.source_type,a.source_id,a.use_date,a.amount,a.restored_amount,
         greatest(a.amount-a.restored_amount,0)::numeric as outstanding_amount,a.note
  from all_uses a
  where greatest(a.amount-a.restored_amount,0)>0
  order by a.use_date,a.source_type,a.source_id;
end;
$$;

grant execute on function public.get_recoverable_reserve_uses(uuid) to authenticated;

-- Preserve the existing monitor return contract; only refine the outstanding-restoration calculation.
create or replace function public.get_reserve_account_monitor()
returns table(
  bank_account_id uuid, company text, bank_name text, account_name text, account_no_last4 text,
  account_type text, reference_balance numeric, balance numeric, reserved_balance numeric,
  available_balance numeric, executed_outflows numeric, manual_support_draws numeric,
  restorations numeric, outstanding_restoration numeric, amount_to_restore_reference numeric,
  variance_to_reference numeric, last_movement_at timestamptz, last_movement_type text
)
language sql
stable security definer
set search_path to 'public','private','pg_temp'
as $$
with p as (
  select bank_account_id,coalesce(sum(amount) filter(where executed_at is not null),0)::numeric(18,2) executed_outflows
  from public.payments group by bank_account_id
),m as (
  select bank_account_id,
         coalesce(sum(amount) filter(where movement_type='Support Draw'),0)::numeric(18,2) manual_support_draws,
         coalesce(sum(amount) filter(where movement_type='Support Draw' and requires_restoration=true),0)::numeric(18,2) recoverable_support_draws,
         coalesce(sum(amount) filter(where movement_type='Restoration'),0)::numeric(18,2) restorations,
         max(created_at) last_movement_at
  from public.bank_reserve_movements group by bank_account_id
),lm as (
  select distinct on(bank_account_id) bank_account_id,movement_type
  from public.bank_reserve_movements order by bank_account_id,created_at desc
)
select bl.id,bl.company,bl.bank_name,bl.account_name,
       case when coalesce(bl.account_no,'')='' then null else right(regexp_replace(bl.account_no,'\\s+','','g'),4) end,
       bl.account_type,b.reference_balance,bl.balance,bl.reserved_balance,bl.available_balance,
       coalesce(p.executed_outflows,0)::numeric,
       coalesce(m.manual_support_draws,0)::numeric,
       coalesce(m.restorations,0)::numeric,
       greatest(coalesce(p.executed_outflows,0)+coalesce(m.recoverable_support_draws,0)-coalesce(m.restorations,0),0)::numeric,
       greatest(coalesce(b.reference_balance,bl.balance)-bl.balance,0)::numeric,
       case when b.reference_balance is null then null else (b.reference_balance-bl.balance)::numeric end,
       m.last_movement_at,lm.movement_type
from public.bank_liquidity bl
join public.bank_accounts b on b.id=bl.id
left join p on p.bank_account_id=bl.id
left join m on m.bank_account_id=bl.id
left join lm on lm.bank_account_id=bl.id
where bl.account_type<>'Operational' and public.has_user_permission('data.bank_balances')
order by case bl.account_type when 'Working Capital Reserve' then 1 when 'VAT Reserve' then 2 else 3 end,bl.company,bl.bank_name;
$$;

create or replace function public.get_reserve_account_movement_report_v2(
  p_bank_account_id uuid default null,
  p_from date default null,
  p_to date default null
)
returns table(
  movement_date date,
  bank_account_id uuid,
  company text,
  bank_name text,
  account_name text,
  account_type text,
  movement_type text,
  source text,
  reference text,
  amount numeric,
  note text,
  requires_restoration boolean,
  restored_amount numeric,
  outstanding_amount numeric,
  recovery_status text,
  restoration_target text
)
language plpgsql
stable security definer
set search_path to 'public','private','pg_temp'
as $$
begin
  if private.current_role() <> all(array['CFO'::text,'Supervisor'::text,'BankAccountant'::text]) then
    raise exception 'Not authorized to view reserve account movements';
  end if;
  return query
  with manual_draws as (
    select m.movement_date,b.id bank_account_id,b.company,b.bank_name,b.account_name,b.account_type,
           m.movement_type,'Manual'::text source,m.id::text reference,m.amount::numeric,coalesce(m.note,'')::text note,
           m.requires_restoration,
           coalesce((select sum(r.amount) from public.bank_reserve_movements r where r.movement_type='Restoration' and r.restores_movement_id=m.id),0)::numeric restored_amount,
           null::text restoration_target
    from public.bank_reserve_movements m join public.bank_accounts b on b.id=m.bank_account_id
    where m.movement_type='Support Draw' and b.account_type<>'Operational'
      and (p_bank_account_id is null or b.id=p_bank_account_id)
      and (p_from is null or m.movement_date>=p_from) and (p_to is null or m.movement_date<=p_to)
  ), restorations as (
    select m.movement_date,b.id bank_account_id,b.company,b.bank_name,b.account_name,b.account_type,
           m.movement_type,'Manual'::text source,m.id::text reference,m.amount::numeric,coalesce(m.note,'')::text note,
           null::boolean requires_restoration,m.amount::numeric restored_amount,
           coalesce(m.restores_movement_id::text,m.restores_payment_id::text)::text restoration_target
    from public.bank_reserve_movements m join public.bank_accounts b on b.id=m.bank_account_id
    where m.movement_type='Restoration' and b.account_type<>'Operational'
      and (p_bank_account_id is null or b.id=p_bank_account_id)
      and (p_from is null or m.movement_date>=p_from) and (p_to is null or m.movement_date<=p_to)
  ), payment_movements as (
    select (p.executed_at at time zone 'Asia/Riyadh')::date movement_date,b.id bank_account_id,b.company,b.bank_name,b.account_name,b.account_type,
           'Payment Outflow'::text movement_type,'Payment'::text source,p.id::text reference,p.amount::numeric,
           trim(concat_ws(' — ',p.beneficiary,p.purpose))::text note,true::boolean requires_restoration,
           coalesce((select sum(r.amount) from public.bank_reserve_movements r where r.movement_type='Restoration' and r.restores_payment_id=p.id),0)::numeric restored_amount,
           null::text restoration_target
    from public.payments p join public.bank_accounts b on b.id=p.bank_account_id
    where b.account_type<>'Operational' and p.executed_at is not null
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
$$;

grant execute on function public.get_reserve_account_movement_report_v2(uuid,date,date) to authenticated;

-- CFO may open the same daily plan as the Supervisor, without changing task ownership.
create or replace function public.supervisor_open_daily_plan(p_items jsonb)
returns integer
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $$
declare
  v_role text := private.current_role();
  v_today date := (now() at time zone 'Asia/Riyadh')::date;
  v_item jsonb; v_id uuid; v_due_time time without time zone; v_count integer := 0; v_task public.tasks%rowtype;
begin
  if v_role <> all(array['Supervisor'::text,'CFO'::text]) then
    raise exception 'Only Supervisor or CFO can open the daily work plan';
  end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then
    raise exception 'Daily plan must include at least one task';
  end if;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_id := (v_item->>'id')::uuid;
    if coalesce(v_item->>'due_time','')='' then raise exception 'Due time is required for every released daily task'; end if;
    v_due_time := (v_item->>'due_time')::time;
    select * into v_task from public.tasks where id=v_id for update;
    if not found then raise exception 'Task not found'; end if;
    if v_task.frequency<>'يومي' or v_task.due_date<>v_today then raise exception 'Only today daily tasks can be released'; end if;
    if v_task.status='مكتمل' then continue; end if;
    update public.tasks set due_time=v_due_time,opened_at=coalesce(opened_at,now()),opened_by=auth.uid(),updated_at=now() where id=v_id;
    insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
    values(auth.uid(),'OPEN_DAILY_TASK','task',v_id::text,jsonb_build_object('owner_id',v_task.owner_id,'due_date',v_today,'due_time',v_due_time,'operator_role',v_role));
    v_count:=v_count+1;
  end loop;
  return v_count;
end;
$$;

-- Preserve existing pre-final edit behavior. Add CFO-only editing after CFO approval and before execution/posting.
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
  if coalesce(p_amount,0)<=0 then raise exception 'Amount must be greater than zero'; end if;

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

grant execute on function public.update_unapproved_payment(uuid,date,text,text,numeric,uuid,text,text,text) to authenticated;
