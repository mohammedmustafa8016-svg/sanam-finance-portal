-- Additive/non-destructive enhancement for reserve target reporting and controlled payment editing.

create or replace function public.get_reserve_account_movement_report(
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
  note text
)
language plpgsql
stable security definer
set search_path = public, private, pg_temp
as $$
begin
  if private.current_role() <> all(array['CFO'::text,'Supervisor'::text,'BankAccountant'::text]) then
    raise exception 'Not authorized to view reserve account movements';
  end if;
  return query
  with manual_movements as (
    select m.movement_date,
           b.id as bank_account_id,b.company,b.bank_name,b.account_name,b.account_type,
           m.movement_type,'Manual'::text as source,m.id::text as reference,
           m.amount::numeric,
           coalesce(m.note,'')::text as note
    from public.bank_reserve_movements m
    join public.bank_accounts b on b.id=m.bank_account_id
    where b.account_type <> 'Operational'
      and (p_bank_account_id is null or b.id=p_bank_account_id)
      and (p_from is null or m.movement_date>=p_from)
      and (p_to is null or m.movement_date<=p_to)
  ), payment_movements as (
    select (p.executed_at at time zone 'Asia/Riyadh')::date as movement_date,
           b.id as bank_account_id,b.company,b.bank_name,b.account_name,b.account_type,
           'Payment Outflow'::text as movement_type,'Payment'::text as source,p.id::text as reference,
           p.amount::numeric,
           trim(concat_ws(' — ',p.beneficiary,p.purpose))::text as note
    from public.payments p
    join public.bank_accounts b on b.id=p.bank_account_id
    where b.account_type <> 'Operational' and p.executed_at is not null
      and (p_bank_account_id is null or b.id=p_bank_account_id)
      and (p_from is null or (p.executed_at at time zone 'Asia/Riyadh')::date>=p_from)
      and (p_to is null or (p.executed_at at time zone 'Asia/Riyadh')::date<=p_to)
  )
  select * from manual_movements
  union all
  select * from payment_movements
  order by movement_date desc, bank_account_id;
end $$;

revoke all on function public.get_reserve_account_movement_report(uuid,date,date) from public;
grant execute on function public.get_reserve_account_movement_report(uuid,date,date) to authenticated;

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
set search_path = public, private, pg_temp
as $$
declare
  v_role text := private.current_role();
  v_old public.payments%rowtype;
begin
  if v_role <> all(array['CFO'::text,'Supervisor'::text,'BankAccountant'::text]) then
    raise exception 'Not authorized to edit payment';
  end if;

  select * into v_old from public.payments where id=p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if v_old.cfo_status='موافق' or v_old.executed_at is not null or v_old.posted_at is not null or v_old.status='مرحّل' then
    raise exception 'Final approval or execution prevents editing';
  end if;
  if coalesce(p_amount,0)<=0 then raise exception 'Amount must be greater than zero'; end if;

  update public.payments
     set due_date=p_due_date,
         company=p_company,
         beneficiary=p_beneficiary,
         amount=p_amount,
         bank_account_id=p_bank_account_id,
         priority=p_priority,
         documents_status=p_documents_status,
         purpose=nullif(trim(coalesce(p_purpose,'')),''),
         supervisor_status='معلق',
         supervisor_approved_by=null,
         supervisor_approved_at=null,
         cfo_status='معلق',
         cfo_approved_by=null,
         cfo_approved_at=null,
         updated_at=now()
   where id=p_payment_id;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'EDIT_UNAPPROVED_PAYMENT','payment',p_payment_id::text,
         jsonb_build_object('company',p_company,'beneficiary',p_beneficiary,'amount',p_amount,'bank_account_id',p_bank_account_id,'approval_reset',true));
end $$;

revoke all on function public.update_unapproved_payment(uuid,date,text,text,numeric,uuid,text,text,text) from public;
grant execute on function public.update_unapproved_payment(uuid,date,text,text,numeric,uuid,text,text,text) to authenticated;
