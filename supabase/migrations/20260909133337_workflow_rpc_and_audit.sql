create or replace function private.audit_change() returns trigger language plpgsql security definer set search_path=public,private as $$
begin
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),tg_op,lower(tg_table_name),coalesce(new.id,old.id)::text,
         jsonb_build_object('old',case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end,'new',case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end));
  return coalesce(new,old);
end $$;
revoke all on function private.audit_change() from public,anon,authenticated;

drop trigger if exists audit_bank_accounts on public.bank_accounts;
create trigger audit_bank_accounts after insert or update or delete on public.bank_accounts for each row execute function private.audit_change();
drop trigger if exists audit_payments on public.payments;
create trigger audit_payments after insert or update or delete on public.payments for each row execute function private.audit_change();
drop trigger if exists audit_tasks on public.tasks;
create trigger audit_tasks after insert or update or delete on public.tasks for each row execute function private.audit_change();
drop trigger if exists audit_exceptions on public.exceptions;
create trigger audit_exceptions after insert or update or delete on public.exceptions for each row execute function private.audit_change();
drop trigger if exists audit_leave_delegations on public.leave_delegations;
create trigger audit_leave_delegations after insert or update or delete on public.leave_delegations for each row execute function private.audit_change();

create or replace function public.approve_payment_supervisor(p_payment_id uuid) returns public.payments
language plpgsql security definer set search_path=public,private as $$
declare p public.payments;
begin
  if not private.is_supervisor_or_delegate() then raise exception 'Not authorized for supervisor approval'; end if;
  update public.payments set supervisor_status='موافق',status='بانتظار اعتماد CFO',supervisor_approved_by=auth.uid(),supervisor_approved_at=now(),updated_at=now()
  where id=p_payment_id and supervisor_status='معلق' returning * into p;
  if p.id is null then raise exception 'Payment not found or already processed'; end if;
  return p;
end $$;

create or replace function public.approve_payment_cfo(p_payment_id uuid) returns public.payments
language plpgsql security definer set search_path=public,private as $$
declare p public.payments;
begin
  if not private.is_cfo() then raise exception 'CFO approval requires CFO account'; end if;
  update public.payments set cfo_status='موافق',status='معتمد للدفع',cfo_approved_by=auth.uid(),cfo_approved_at=now(),updated_at=now()
  where id=p_payment_id and supervisor_status='موافق' and cfo_status='معلق' returning * into p;
  if p.id is null then raise exception 'Payment not found or supervisor approval missing'; end if;
  return p;
end $$;

create or replace function public.execute_payment(p_payment_id uuid) returns public.payments
language plpgsql security definer set search_path=public,private as $$
declare p public.payments;
begin
  if private.current_role()<>'BankAccountant' and not private.is_cfo() then raise exception 'Only Bank Accountant can execute payment'; end if;
  update public.payments set status='منفذ',executed_by=auth.uid(),executed_at=now(),updated_at=now()
  where id=p_payment_id and cfo_status='موافق' and status='معتمد للدفع' returning * into p;
  if p.id is null then raise exception 'Payment is not approved for execution'; end if;
  return p;
end $$;

create or replace function public.post_payment(p_payment_id uuid) returns public.payments
language plpgsql security definer set search_path=public,private as $$
declare p public.payments;
begin
  if private.current_role()<>'GLAccountant' and not private.is_cfo() then raise exception 'Only GL Accountant can post payment'; end if;
  update public.payments set status='مرحّل',posted_by=auth.uid(),posted_at=now(),updated_at=now()
  where id=p_payment_id and status='منفذ' returning * into p;
  if p.id is null then raise exception 'Payment must be executed first'; end if;
  return p;
end $$;

revoke all on function public.approve_payment_supervisor(uuid) from public,anon;
revoke all on function public.approve_payment_cfo(uuid) from public,anon;
revoke all on function public.execute_payment(uuid) from public,anon;
revoke all on function public.post_payment(uuid) from public,anon;
grant execute on function public.approve_payment_supervisor(uuid) to authenticated;
grant execute on function public.approve_payment_cfo(uuid) to authenticated;
grant execute on function public.execute_payment(uuid) to authenticated;
grant execute on function public.post_payment(uuid) to authenticated;