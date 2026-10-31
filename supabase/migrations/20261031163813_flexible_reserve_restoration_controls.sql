-- One restoration receipt, many allocations; preserve the existing reserve movement ledger.
alter table public.bank_reserve_movements add column restoration_request_id uuid;
create unique index bank_reserve_restoration_request_unique on public.bank_reserve_movements(restoration_request_id) where restoration_request_id is not null;
alter table public.bank_reserve_movements drop constraint bank_reserve_movements_recovery_shape_chk;
alter table public.bank_reserve_movements add constraint bank_reserve_movements_recovery_shape_chk check(
 (movement_type='Support Draw' and requires_restoration is not null and restores_movement_id is null and restores_payment_id is null and restoration_request_id is null)
 or (movement_type='Restoration' and requires_restoration is null and (
  (restoration_request_id is null and ((restores_movement_id is not null)::int+(restores_payment_id is not null)::int)=1)
  or (restoration_request_id is not null and restores_movement_id is null and restores_payment_id is null))));
create table public.reserve_recovery_allocations_v3(
 id uuid primary key default gen_random_uuid(),
 restoration_movement_id uuid not null references public.bank_reserve_movements(id) on delete restrict,
 draw_movement_id uuid references public.bank_reserve_movements(id) on delete restrict,
 payment_id uuid references public.payments(id) on delete restrict,
 amount numeric(18,2) not null check(amount>0),
 allocated_by uuid not null references public.profiles(id),created_at timestamptz not null default now(),
 check(((draw_movement_id is not null)::int+(payment_id is not null)::int)=1));
create unique index reserve_recovery_draw_unique on public.reserve_recovery_allocations_v3(restoration_movement_id,draw_movement_id) where draw_movement_id is not null;
create unique index reserve_recovery_payment_unique on public.reserve_recovery_allocations_v3(restoration_movement_id,payment_id) where payment_id is not null;
create index reserve_recovery_draw_lookup on public.reserve_recovery_allocations_v3(draw_movement_id) where draw_movement_id is not null;
create index reserve_recovery_payment_lookup on public.reserve_recovery_allocations_v3(payment_id) where payment_id is not null;
alter table public.reserve_recovery_allocations_v3 enable row level security;
revoke all on public.reserve_recovery_allocations_v3 from anon,authenticated;
grant select on public.reserve_recovery_allocations_v3 to authenticated;
create policy reserve_recovery_read on public.reserve_recovery_allocations_v3 for select to authenticated using(
 public.has_user_permission('data.bank_balances') and private.current_role() in ('CFO','Supervisor','BankAccountant'));
revoke insert,update,delete on public.bank_reserve_movements from authenticated;
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
    where p.bank_account_id=p_bank_account_id and p.company=b.company and p.executed_at is not null and b.account_type<>'Operational'
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

CREATE OR REPLACE FUNCTION public.get_reserve_account_monitor()
 RETURNS TABLE(bank_account_id uuid, company text, bank_name text, account_name text, account_no_last4 text, account_type text, reference_balance numeric, balance numeric, reserved_balance numeric, available_balance numeric, executed_outflows numeric, manual_support_draws numeric, restorations numeric, outstanding_restoration numeric, amount_to_restore_reference numeric, variance_to_reference numeric, last_movement_at timestamp with time zone, last_movement_type text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
with payment_uses as (
  select p.bank_account_id,p.id,p.amount,(coalesce((select sum(r.amount) from public.bank_reserve_movements r where r.movement_type='Restoration' and r.restores_payment_id=p.id),0)+coalesce((select sum(a.amount) from public.reserve_recovery_allocations_v3 a where a.payment_id=p.id),0)) restored
  from public.payments p join public.bank_accounts b on b.id=p.bank_account_id where p.executed_at is not null and b.account_type<>'Operational'
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
  if coalesce(private.current_role(),'') not in ('Supervisor','BankAccountant') then
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
revoke all on function public.record_reserve_restoration_v3(uuid,numeric,date,text,jsonb,uuid) from public,anon;
grant execute on function public.record_reserve_restoration_v3(uuid,numeric,date,text,jsonb,uuid) to authenticated;
create or replace function private.protect_reserve_balance_mutation()
returns trigger language plpgsql security definer set search_path=public,private,pg_temp as $$
begin
 if private.current_role()='CFO' then return new;end if;
 if tg_op='INSERT' then
  if new.account_type<>'Operational' and (new.balance<>0 or new.reference_balance is not null) then raise exception 'RESERVE_BALANCE_CFO_ONLY';end if;
  return new;
 end if;
 if old.account_type<>'Operational' or new.account_type<>'Operational' then
  if old.account_type is distinct from new.account_type or old.reference_balance is distinct from new.reference_balance then raise exception 'RESERVE_BALANCE_CFO_ONLY';end if;
  if old.balance is distinct from new.balance and not (pg_trigger_depth()>1 and coalesce(current_setting('app.auto_payment_balance',true),'')='1') then raise exception 'RESERVE_BALANCE_CFO_ONLY';end if;
 end if;
 return new;
end$$;
revoke all on function private.protect_reserve_balance_mutation() from public,anon,authenticated;
create trigger protect_reserve_balance before insert or update on public.bank_accounts for each row execute function private.protect_reserve_balance_mutation();
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
$function$;
