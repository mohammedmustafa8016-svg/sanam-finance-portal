begin;

-- Resume at the correct accounting stage; never execute a payment or finalize posting here.
create function public.resume_pending_payment(p_payment_id uuid,p_resolution_note text,p_expected_updated_at timestamptz)
returns public.payments language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v public.payments; before_row public.payments; actor_role text:=private.current_role();
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and active)
 or coalesce(actor_role,'') not in ('GLAccountant','Supervisor','CFO')
 or not coalesce(public.has_user_permission('page.payments'),false) then raise exception 'PENDING_NOT_AUTHORIZED';end if;
 if length(trim(coalesce(p_resolution_note,''))) not between 10 and 2000 then raise exception 'PENDING_RESOLUTION_NOTE_REQUIRED';end if;
 if p_expected_updated_at is null then raise exception 'PENDING_VERSION_REQUIRED';end if;
 select * into v from public.payments where id=p_payment_id for update;
 if not found then raise exception 'PAYMENT_NOT_FOUND';end if;
 if v.updated_at is distinct from p_expected_updated_at then raise exception 'PENDING_STALE_RECORD_REFRESH';end if;
 if v.status<>'معلقة' or v.executed_at is null or v.posted_at is not null then raise exception 'PAYMENT_IS_NOT_ACTIVE_PENDING';end if;
 if v.accounting_registered_at is null and actor_role<>'GLAccountant' then raise exception 'PENDING_REQUIRES_GL_REGISTRATION';end if;
 if v.accounting_registered_at is not null and actor_role not in ('Supervisor','CFO') then raise exception 'PENDING_REQUIRES_SUPERVISOR_REVIEW';end if;
 if v.pending_amount<=0 or v.pending_amount>v.amount then raise exception 'PENDING_AMOUNT_REQUIRES_REVIEW';end if;
 before_row=v;
 update public.payments set status='تم التسجيل',
  accounting_registered_by=coalesce(accounting_registered_by,auth.uid()),
  accounting_registered_at=coalesce(accounting_registered_at,now()),
  registered_amount=amount,pending_amount=0,pending_resolved_by=auth.uid(),pending_resolved_at=now(),
  pending_resolution_note=trim(p_resolution_note),updated_at=clock_timestamp()
 where id=p_payment_id returning * into v;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'PAYMENT_PENDING_RESOLVED','payment',v.id::text,
  jsonb_build_object('actor_role',actor_role,'had_prior_accounting_registration',before_row.accounting_registered_at is not null,
   'previous_pending_type',before_row.pending_type,'previous_pending_amount',before_row.pending_amount,
   'previous_registered_amount',before_row.registered_amount,'previous_reason',before_row.pending_reason,
   'previous_details',before_row.pending_details,'previous_pending_owner_id',before_row.pending_owner_id,
   'previous_follow_up_date',before_row.pending_follow_up_date,'resolution_note',trim(p_resolution_note),
   'status',v.status,'registered_amount',v.registered_amount,'automatic_posting',false));
 perform private.ensure_payment_workflow_v3(v.id);
 return v;
end$$;

-- Compatibility for the previous GL client, restricted to its own pre-registration stage.
create or replace function public.resolve_payment_pending_and_register(p_payment_id uuid,p_resolution_note text)
returns public.payments language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v public.payments;
begin
 if auth.uid() is null or coalesce(private.current_role(),'')<>'GLAccountant' then raise exception 'PENDING_NOT_AUTHORIZED';end if;
 select * into v from public.payments where id=p_payment_id for update;
 if not found then raise exception 'PAYMENT_NOT_FOUND';end if;
 return public.resume_pending_payment(p_payment_id,p_resolution_note,v.updated_at);
end$$;

create function public.update_pending_payment_followup(p_payment_id uuid,p_required_action text,p_owner_id uuid,p_follow_up_date date,p_change_note text,p_expected_updated_at timestamptz)
returns public.payments language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v public.payments; old_row public.payments;
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and active)
 or coalesce(private.current_role(),'') not in ('Supervisor','CFO')
 or not coalesce(public.has_user_permission('page.payments'),false) then raise exception 'PENDING_NOT_AUTHORIZED';end if;
 if length(trim(coalesce(p_required_action,''))) not between 3 and 1000 or length(trim(coalesce(p_change_note,''))) not between 10 and 2000 then raise exception 'PENDING_FOLLOWUP_DETAILS_REQUIRED';end if;
 if p_owner_id is null or not exists(select 1 from public.profiles where id=p_owner_id and active and finance_team and role in ('CFO','Supervisor','BankAccountant','GLAccountant','APAccountant')) then raise exception 'PENDING_ACTIVE_FINANCE_OWNER_REQUIRED';end if;
 if p_follow_up_date is null or p_follow_up_date<(now() at time zone 'Asia/Riyadh')::date then raise exception 'PENDING_FOLLOWUP_DATE_REQUIRED';end if;
 if p_expected_updated_at is null then raise exception 'PENDING_VERSION_REQUIRED';end if;
 select * into v from public.payments where id=p_payment_id for update;
 if not found then raise exception 'PAYMENT_NOT_FOUND';end if;
 if v.updated_at is distinct from p_expected_updated_at then raise exception 'PENDING_STALE_RECORD_REFRESH';end if;
 if v.status<>'معلقة' or v.executed_at is null or v.posted_at is not null then raise exception 'PAYMENT_IS_NOT_ACTIVE_PENDING';end if;
 old_row=v;
 update public.payments set pending_action=trim(p_required_action),pending_owner_id=p_owner_id,
 pending_follow_up_date=p_follow_up_date,updated_at=clock_timestamp() where id=p_payment_id returning * into v;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'PAYMENT_PENDING_FOLLOWUP_UPDATED','payment',v.id::text,
 jsonb_build_object('previous_action',old_row.pending_action,'previous_owner_id',old_row.pending_owner_id,
  'previous_follow_up_date',old_row.pending_follow_up_date,'required_action',v.pending_action,
  'pending_owner_id',v.pending_owner_id,'follow_up_date',v.pending_follow_up_date,'change_note',trim(p_change_note)));
 return v;
end$$;

create function public.get_pending_payment_history(p_payment_id uuid) returns jsonb
language plpgsql stable security definer set search_path=public,private,pg_temp as $$
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and active)
 or coalesce(private.current_role(),'') not in ('CFO','Supervisor','BankAccountant','GLAccountant','APAccountant')
 or not coalesce(public.has_user_permission('page.payments'),false) then raise exception 'PENDING_NOT_AUTHORIZED';end if;
 if not exists(select 1 from public.payments where id=p_payment_id) then raise exception 'PAYMENT_NOT_FOUND';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id desc) from (
  select a.id,a.created_at,a.action,p.full_name as actor_name,a.details from public.audit_log a
  left join public.profiles p on p.id=a.actor_id where a.entity_type='payment' and a.entity_id=p_payment_id::text
  and a.action in ('PAYMENT_MARKED_PENDING_BY_GL','PAYMENT_MARKED_PENDING_BY_SUPERVISOR','PAYMENT_MARKED_PENDING_BY_CFO','PAYMENT_PENDING_RESOLVED','PAYMENT_PENDING_FOLLOWUP_UPDATED')
  order by a.created_at desc,a.id desc limit 50)x),'[]'::jsonb);
end$$;

revoke all on function public.resume_pending_payment(uuid,text,timestamptz),public.resolve_payment_pending_and_register(uuid,text),public.update_pending_payment_followup(uuid,text,uuid,date,text,timestamptz),public.get_pending_payment_history(uuid) from public,anon;
grant execute on function public.resume_pending_payment(uuid,text,timestamptz),public.resolve_payment_pending_and_register(uuid,text),public.update_pending_payment_followup(uuid,text,uuid,date,text,timestamptz),public.get_pending_payment_history(uuid) to authenticated;
commit;
