-- Reset approval chain correctly when CFO returns a payment to Supervisor review.
-- Additive corrective migration only; no UI, workflow structure, or unrelated behavior changes.

create or replace function public.cfo_override_payment_status(
  p_payment_id uuid,
  p_status text,
  p_reason text
)
returns public.payments
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
declare
  v public.payments;
  v_old text;
begin
  if private.current_role()<>'CFO' then raise exception 'Only CFO can override payment status'; end if;
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
      executed_at=case when p_status in ('منفذ','تم التسجيل','مرحّل') then coalesce(executed_at,now()) else executed_at end,
      executed_by=case when p_status in ('منفذ','تم التسجيل','مرحّل') then coalesce(executed_by,auth.uid()) else executed_by end,
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
      'approval_reset',case when p_status='بانتظار مراجعة المشرف' then 'SUPERVISOR_AND_CFO' else 'NONE' end
    )
  );

  perform private.ensure_payment_workflow_v3(v.id);
  return v;
end
$function$;

-- Correct only already-existing inconsistent rows produced by the old override behavior,
-- then resynchronize exactly those corrected rows to the existing V3 workflow.
do $
declare
  r record;
begin
  for r in
    update public.payments
    set supervisor_status='معلق',
        supervisor_approved_by=null,
        supervisor_approved_at=null,
        cfo_status='معلق',
        cfo_approved_by=null,
        cfo_approved_at=null,
        updated_at=now()
    where status='بانتظار مراجعة المشرف'
      and executed_at is null
      and accounting_registered_at is null
      and posted_at is null
      and (
        supervisor_status='موافق'
        or supervisor_approved_by is not null
        or supervisor_approved_at is not null
        or cfo_status='موافق'
        or cfo_approved_by is not null
        or cfo_approved_at is not null
      )
    returning id
  loop
    perform private.ensure_payment_workflow_v3(r.id);
  end loop;
end
$;
