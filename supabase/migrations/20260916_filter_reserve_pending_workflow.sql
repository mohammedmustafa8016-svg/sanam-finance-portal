-- Additive workflow: reserve support-draw reclassification + accounting registration/pending flow.

alter table public.payments add column if not exists accounting_registered_by uuid references public.profiles(id);
alter table public.payments add column if not exists accounting_registered_at timestamptz;
alter table public.payments add column if not exists pending_by uuid references public.profiles(id);
alter table public.payments add column if not exists pending_at timestamptz;
alter table public.payments add column if not exists pending_reason text;
alter table public.payments add column if not exists pending_action text;
alter table public.payments add column if not exists pending_owner_id uuid references public.profiles(id);
alter table public.payments add column if not exists pending_follow_up_date date;

create or replace function public.register_payment_accounting(p_payment_id uuid)
returns public.payments
language plpgsql security definer set search_path='public','private','pg_temp'
as $$
declare v public.payments;
begin
  if private.current_role()<>'GLAccountant' and not private.is_cfo() then raise exception 'Only GL Accountant can register the accounting entry'; end if;
  update public.payments set status='تم التسجيل',accounting_registered_by=auth.uid(),accounting_registered_at=now(),updated_at=now()
   where id=p_payment_id and status='منفذ' and executed_at is not null and posted_at is null returning * into v;
  if v.id is null then raise exception 'Payment must be executed and not already finalized'; end if;
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'PAYMENT_ACCOUNTING_REGISTERED','payment',v.id::text,jsonb_build_object('status','تم التسجيل','registered_at',v.accounting_registered_at));
  return v;
end $$;

create or replace function public.supervisor_finalize_registered_payment(p_payment_id uuid,p_action text,p_reason text default null,p_pending_action text default null,p_pending_owner_id uuid default null,p_follow_up_date date default null)
returns public.payments
language plpgsql security definer set search_path='public','private','pg_temp'
as $$
declare v public.payments; v_role text:=private.current_role(); v_prev text;
begin
  if v_role not in ('Supervisor','CFO') then raise exception 'Only Supervisor or CFO can finalize registered payments'; end if;
  if p_action not in ('Posted','Pending') then raise exception 'Invalid action'; end if;
  select * into v from public.payments where id=p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if v.status not in ('تم التسجيل','معلقة') or v.posted_at is not null then raise exception 'Payment must be registered and not already posted'; end if;
  v_prev:=v.status;
  if p_action='Posted' then
    update public.payments set status='مرحّل',posted_by=auth.uid(),posted_at=now(),pending_by=null,pending_at=null,pending_reason=null,pending_action=null,pending_owner_id=null,pending_follow_up_date=null,updated_at=now() where id=p_payment_id returning * into v;
    insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'PAYMENT_POSTED_BY_SUPERVISOR','payment',v.id::text,jsonb_build_object('previous_status',v_prev,'status','مرحّل'));
  else
    if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Pending justification is required'; end if;
    update public.payments set status='معلقة',pending_by=auth.uid(),pending_at=now(),pending_reason=trim(p_reason),pending_action=nullif(trim(coalesce(p_pending_action,'')),''),pending_owner_id=p_pending_owner_id,pending_follow_up_date=p_follow_up_date,updated_at=now() where id=p_payment_id returning * into v;
    insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'PAYMENT_MARKED_PENDING','payment',v.id::text,jsonb_build_object('reason',v.pending_reason,'required_action',v.pending_action,'pending_owner_id',v.pending_owner_id,'follow_up_date',v.pending_follow_up_date));
  end if;
  return v;
end $$;

create or replace function public.post_payment(p_payment_id uuid)
returns public.payments
language plpgsql security definer set search_path='public','private','pg_temp'
as $$
declare v public.payments;
begin
  if not private.is_cfo() then raise exception 'Direct posting is disabled; use Supervisor finalization after accounting registration'; end if;
  update public.payments set status='مرحّل',posted_by=auth.uid(),posted_at=now(),updated_at=now() where id=p_payment_id and status in ('تم التسجيل','معلقة') and posted_at is null returning * into v;
  if v.id is null then raise exception 'Payment must be accounting-registered first'; end if;
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'PAYMENT_POSTED_CFO_OVERRIDE','payment',v.id::text,jsonb_build_object('status','مرحّل'));
  return v;
end $$;

create or replace function public.reclassify_reserve_support_draw(p_movement_id uuid,p_requires_restoration boolean,p_reason text)
returns public.bank_reserve_movements
language plpgsql security definer set search_path='public','private','pg_temp'
as $$
declare v public.bank_reserve_movements; v_old boolean; v_restored numeric;
begin
  if not private.is_cfo() then raise exception 'Only CFO can reclassify reserve support draws'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Reclassification reason is required'; end if;
  select * into v from public.bank_reserve_movements where id=p_movement_id for update;
  if not found or v.movement_type<>'Support Draw' then raise exception 'Support draw not found'; end if;
  v_old:=coalesce(v.requires_restoration,true);
  if v_old=p_requires_restoration then return v; end if;
  select coalesce(sum(amount),0) into v_restored from public.bank_reserve_movements where movement_type='Restoration' and restores_movement_id=v.id;
  update public.bank_reserve_movements set requires_restoration=p_requires_restoration where id=v.id returning * into v;
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'RESERVE_DRAW_RECLASSIFIED','bank_reserve_movement',v.id::text,jsonb_build_object('before_requires_restoration',v_old,'after_requires_restoration',p_requires_restoration,'reason',trim(p_reason),'linked_restorations',v_restored));
  return v;
end $$;

create or replace function public.get_reserve_account_monitor()
returns table(bank_account_id uuid, company text, bank_name text, account_name text, account_no_last4 text, account_type text, reference_balance numeric, balance numeric, reserved_balance numeric, available_balance numeric, executed_outflows numeric, manual_support_draws numeric, restorations numeric, outstanding_restoration numeric, amount_to_restore_reference numeric, variance_to_reference numeric, last_movement_at timestamptz, last_movement_type text)
language sql stable security definer set search_path='public','private','pg_temp'
as $$
with payment_uses as (
  select p.bank_account_id,p.id,p.amount,coalesce((select sum(r.amount) from public.bank_reserve_movements r where r.movement_type='Restoration' and r.restores_payment_id=p.id),0) restored
  from public.payments p join public.bank_accounts b on b.id=p.bank_account_id where p.executed_at is not null and b.account_type<>'Operational'
), manual_uses as (
  select m.bank_account_id,m.id,m.amount,m.requires_restoration,m.created_at,coalesce((select sum(r.amount) from public.bank_reserve_movements r where r.movement_type='Restoration' and r.restores_movement_id=m.id),0) restored
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
$$;

grant execute on function public.register_payment_accounting(uuid) to authenticated;
grant execute on function public.supervisor_finalize_registered_payment(uuid,text,text,text,uuid,date) to authenticated;
grant execute on function public.reclassify_reserve_support_draw(uuid,boolean,text) to authenticated;
