
-- Payment post-execution segregation of duties + governed pending workflow.
-- Scope: GL Accountant may register accounting or mark pending; final posting is Supervisor/CFO only.

alter table public.payments add column if not exists pending_type text;
alter table public.payments add column if not exists pending_amount numeric(18,2) not null default 0;
alter table public.payments add column if not exists registered_amount numeric(18,2) not null default 0;
alter table public.payments add column if not exists pending_details text;
alter table public.payments add column if not exists pending_resolved_by uuid references public.profiles(id);
alter table public.payments add column if not exists pending_resolved_at timestamptz;
alter table public.payments add column if not exists pending_resolution_note text;

update public.payments
set
  pending_type = case when status='معلقة' then coalesce(pending_type,'FULL') else pending_type end,
  pending_amount = case when status='معلقة' then amount else coalesce(pending_amount,0) end,
  registered_amount = case
    when status='معلقة' then 0
    when accounting_registered_at is not null then amount
    else coalesce(registered_amount,0)
  end,
  pending_details = case
    when status='معلقة' then coalesce(nullif(trim(pending_details),''), nullif(trim(pending_action),''), nullif(trim(pending_reason),''))
    else pending_details
  end
where status='معلقة'
   or accounting_registered_at is not null;

do $$
begin
  if not exists(select 1 from pg_constraint where conname='payments_pending_type_check') then
    alter table public.payments
      add constraint payments_pending_type_check
      check (pending_type is null or pending_type in ('FULL','PARTIAL'));
  end if;
  if not exists(select 1 from pg_constraint where conname='payments_pending_amount_check') then
    alter table public.payments
      add constraint payments_pending_amount_check
      check (pending_amount >= 0 and pending_amount <= amount);
  end if;
  if not exists(select 1 from pg_constraint where conname='payments_registered_amount_check') then
    alter table public.payments
      add constraint payments_registered_amount_check
      check (registered_amount >= 0 and registered_amount <= amount);
  end if;
  if not exists(select 1 from pg_constraint where conname='payments_amount_split_check') then
    alter table public.payments
      add constraint payments_amount_split_check
      check (registered_amount + pending_amount <= amount);
  end if;
end $$;

create or replace function private.ensure_payment_workflow_v3(p_payment_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
declare
  p public.payments%rowtype;
  v_instance uuid;
  v_sup uuid;
  v_cfo uuid;
  v_bank uuid;
  v_gl uuid;
  v_step uuid;
  v_item uuid;
  v_status text;
  v_current text;
  v_title text;
begin
  if not private.workflow_v3_enabled() then return null; end if;
  select * into p from public.payments where id=p_payment_id;
  if not found then return null; end if;

  v_sup:=private.workflow_user_for_role('Supervisor');
  v_cfo:=private.workflow_user_for_role('CFO');
  v_bank:=private.workflow_user_for_role('BankAccountant');
  v_gl:=private.workflow_user_for_role('GLAccountant');
  v_title:='دفعة '||coalesce(p.beneficiary,'')||' — '||coalesce(p.company,'');

  insert into public.workflow_instances(workflow_type,source_entity_type,source_entity_id,status,current_step_key,created_by,metadata)
  values('PAYMENT','payment',p.id::text,case when p.posted_at is not null then 'Completed' else 'Active' end,null,p.requested_by,
         jsonb_build_object('beneficiary',p.beneficiary,'company',p.company,'amount',p.amount))
  on conflict(workflow_type,source_entity_type,source_entity_id) do update set
    status=excluded.status,
    metadata=public.workflow_instances.metadata||excluded.metadata,
    updated_at=now()
  returning id into v_instance;

  v_status:=case when p.supervisor_approved_at is not null or p.supervisor_status='موافق' then 'Completed' else 'Ready' end;
  v_step:=private.upsert_workflow_step(v_instance,'SUPERVISOR_APPROVAL',10,'مراجعة واعتماد المشرف','Supervisor',v_sup,v_cfo,v_status,null,null,p.supervisor_approved_at,p.supervisor_approved_by,'{}');
  v_item:=private.upsert_work_item(v_instance,v_step,'PAYMENT_SUPERVISOR_APPROVAL','payment',p.id::text,v_title||' — اعتماد المشرف','Supervisor',v_sup,v_cfo,v_status,p.priority,null,null,p.supervisor_approved_at,p.supervisor_approved_by,true,1,'{}');
  perform private.credit_work_item_completion(v_item);

  v_status:=case when p.cfo_approved_at is not null or p.cfo_status='موافق' then 'Completed'
                 when p.supervisor_approved_at is not null or p.supervisor_status='موافق' then 'Ready'
                 else 'Waiting' end;
  v_step:=private.upsert_workflow_step(v_instance,'CFO_APPROVAL',20,'اعتماد المدير المالي','CFO',v_cfo,null,v_status,null,null,p.cfo_approved_at,p.cfo_approved_by,'{}');
  v_item:=private.upsert_work_item(v_instance,v_step,'PAYMENT_CFO_APPROVAL','payment',p.id::text,v_title||' — اعتماد المدير المالي','CFO',v_cfo,null,v_status,p.priority,null,null,p.cfo_approved_at,p.cfo_approved_by,true,1,'{}');
  perform private.credit_work_item_completion(v_item);

  v_status:=case when p.executed_at is not null then 'Completed'
                 when p.cfo_approved_at is not null or p.cfo_status='موافق' then 'Ready'
                 else 'Waiting' end;
  v_step:=private.upsert_workflow_step(v_instance,'BANK_EXECUTION',30,'تنفيذ العملية البنكية','BankAccountant',v_bank,v_sup,v_status,null,null,p.executed_at,p.executed_by,'{}');
  v_item:=private.upsert_work_item(v_instance,v_step,'PAYMENT_BANK_EXECUTION','payment',p.id::text,v_title||' — تنفيذ بنكي','BankAccountant',v_bank,v_sup,v_status,p.priority,null,null,p.executed_at,p.executed_by,true,1,'{}');
  perform private.credit_work_item_completion(v_item);

  v_status:=case
    when p.accounting_registered_at is not null then 'Completed'
    when p.status='معلقة' then 'Blocked'
    when p.executed_at is not null then 'Ready'
    else 'Waiting'
  end;
  v_step:=private.upsert_workflow_step(
    v_instance,'ACCOUNTING_REGISTRATION',40,'التسجيل المحاسبي','GLAccountant',v_gl,v_sup,v_status,
    case when p.executed_at is null then null else p.executed_at+interval '48 hours' end,
    null,p.accounting_registered_at,p.accounting_registered_by,
    jsonb_build_object('pending_type',p.pending_type,'pending_amount',p.pending_amount)
  );
  v_item:=private.upsert_work_item(
    v_instance,v_step,'PAYMENT_ACCOUNTING_REGISTRATION','payment',p.id::text,v_title||' — تسجيل محاسبي',
    'GLAccountant',v_gl,v_sup,v_status,p.priority,
    case when p.executed_at is null then null else p.executed_at+interval '48 hours' end,
    null,p.accounting_registered_at,p.accounting_registered_by,true,1,
    jsonb_build_object('pending_type',p.pending_type,'pending_amount',p.pending_amount)
  );
  perform private.credit_work_item_completion(v_item);

  v_status:=case
    when p.posted_at is not null then 'Completed'
    when p.status='معلقة' then 'Blocked'
    when p.accounting_registered_at is not null then 'Ready'
    else 'Waiting'
  end;
  v_step:=private.upsert_workflow_step(
    v_instance,'POSTING_FINALIZATION',50,'الترحيل والإقفال','Supervisor',v_sup,v_cfo,v_status,
    null,null,p.posted_at,p.posted_by,
    jsonb_build_object('pending_type',p.pending_type,'pending_amount',p.pending_amount)
  );
  v_item:=private.upsert_work_item(
    v_instance,v_step,'PAYMENT_POSTING_FINALIZATION','payment',p.id::text,v_title||' — ترحيل وإقفال',
    'Supervisor',v_sup,v_cfo,v_status,p.priority,null,null,p.posted_at,p.posted_by,true,1,
    jsonb_build_object('pending_type',p.pending_type,'pending_amount',p.pending_amount)
  );
  perform private.credit_work_item_completion(v_item);

  select step_key into v_current
  from public.workflow_steps
  where workflow_instance_id=v_instance and status not in ('Completed','Cancelled')
  order by step_order
  limit 1;

  update public.workflow_instances
  set current_step_key=v_current,
      status=case when p.posted_at is not null then 'Completed' else 'Active' end,
      completed_at=case when p.posted_at is not null then p.posted_at else null end,
      updated_at=now()
  where id=v_instance;

  return v_instance;
end
$function$;

create or replace function public.register_payment_accounting(p_payment_id uuid)
returns public.payments
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
declare v public.payments;
begin
  if private.current_role()<>'GLAccountant' and not private.is_cfo() then
    raise exception 'Only GL Accountant can register the accounting entry';
  end if;

  update public.payments
  set status='تم التسجيل',
      accounting_registered_by=auth.uid(),
      accounting_registered_at=now(),
      registered_amount=amount,
      pending_amount=0,
      pending_type=null,
      pending_reason=null,
      pending_details=null,
      pending_action=null,
      pending_owner_id=null,
      pending_follow_up_date=null,
      pending_by=null,
      pending_at=null,
      pending_resolved_by=null,
      pending_resolved_at=null,
      pending_resolution_note=null,
      updated_at=now()
  where id=p_payment_id
    and status='منفذ'
    and executed_at is not null
    and posted_at is null
  returning * into v;

  if v.id is null then raise exception 'Payment must be executed and not already finalized'; end if;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'PAYMENT_ACCOUNTING_REGISTERED','payment',v.id::text,
         jsonb_build_object('status','تم التسجيل','registered_at',v.accounting_registered_at,'registered_amount',v.registered_amount));

  perform private.ensure_payment_workflow_v3(v.id);
  return v;
end
$function$;

create or replace function public.mark_payment_pending(
  p_payment_id uuid,
  p_pending_type text,
  p_pending_amount numeric,
  p_reason text,
  p_details text,
  p_pending_action text default null,
  p_pending_owner_id uuid default null,
  p_follow_up_date date default null
)
returns public.payments
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
declare
  v public.payments;
  v_role text:=private.current_role();
  v_type text:=upper(trim(coalesce(p_pending_type,'')));
  v_pending numeric(18,2);
begin
  if v_role not in ('GLAccountant','Supervisor','CFO') then
    raise exception 'NOT_AUTHORIZED_TO_MARK_PAYMENT_PENDING';
  end if;
  if v_type not in ('FULL','PARTIAL') then raise exception 'INVALID_PENDING_TYPE'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Pending justification is required'; end if;
  if nullif(trim(coalesce(p_details,'')),'') is null then raise exception 'Pending notes are required'; end if;

  select * into v from public.payments where id=p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if v.executed_at is null or v.posted_at is not null then raise exception 'PAYMENT_NOT_ELIGIBLE_FOR_PENDING'; end if;

  if v_role='GLAccountant' then
    if v.status<>'منفذ' or v.accounting_registered_at is not null then
      raise exception 'GL_CAN_MARK_PENDING_ONLY_BEFORE_ACCOUNTING_REGISTRATION';
    end if;
  else
    if v.status<>'تم التسجيل' or v.accounting_registered_at is null then
      raise exception 'SUPERVISOR_CFO_CAN_MARK_PENDING_ONLY_AFTER_ACCOUNTING_REGISTRATION';
    end if;
  end if;

  if v_type='FULL' then
    v_pending:=v.amount;
  else
    v_pending:=coalesce(p_pending_amount,0);
    if v_pending<=0 or v_pending>=v.amount then
      raise exception 'PARTIAL_PENDING_AMOUNT_MUST_BE_GREATER_THAN_ZERO_AND_LESS_THAN_PAYMENT';
    end if;
  end if;

  update public.payments
  set status='معلقة',
      pending_type=v_type,
      pending_amount=v_pending,
      registered_amount=(amount-v_pending)::numeric(18,2),
      pending_by=auth.uid(),
      pending_at=now(),
      pending_reason=trim(p_reason),
      pending_details=trim(p_details),
      pending_action=nullif(trim(coalesce(p_pending_action,'')),''),
      pending_owner_id=p_pending_owner_id,
      pending_follow_up_date=p_follow_up_date,
      pending_resolved_by=null,
      pending_resolved_at=null,
      pending_resolution_note=null,
      updated_at=now()
  where id=p_payment_id
  returning * into v;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(
    auth.uid(),
    case v_role
      when 'GLAccountant' then 'PAYMENT_MARKED_PENDING_BY_GL'
      when 'Supervisor' then 'PAYMENT_MARKED_PENDING_BY_SUPERVISOR'
      else 'PAYMENT_MARKED_PENDING_BY_CFO'
    end,
    'payment',v.id::text,
    jsonb_build_object(
      'actor_role',v_role,
      'pending_type',v.pending_type,
      'payment_amount',v.amount,
      'pending_amount',v.pending_amount,
      'registered_amount',v.registered_amount,
      'reason',v.pending_reason,
      'details',v.pending_details,
      'required_action',v.pending_action,
      'pending_owner_id',v.pending_owner_id,
      'follow_up_date',v.pending_follow_up_date
    )
  );

  perform private.ensure_payment_workflow_v3(v.id);
  return v;
end
$function$;

revoke all on function public.mark_payment_pending(uuid,text,numeric,text,text,text,uuid,date) from public,anon;
grant execute on function public.mark_payment_pending(uuid,text,numeric,text,text,text,uuid,date) to authenticated;

create or replace function public.resolve_payment_pending_and_register(
  p_payment_id uuid,
  p_resolution_note text
)
returns public.payments
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
declare
  v public.payments;
  v_had_registration boolean;
begin
  if private.current_role()<>'GLAccountant' then
    raise exception 'Only GL Accountant can complete pending accounting registration';
  end if;
  if nullif(trim(coalesce(p_resolution_note,'')),'') is null then
    raise exception 'Resolution note is required';
  end if;

  select * into v from public.payments where id=p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if v.status<>'معلقة' or v.executed_at is null or v.posted_at is not null then
    raise exception 'PAYMENT_IS_NOT_ACTIVE_PENDING';
  end if;

  v_had_registration:=v.accounting_registered_at is not null;

  update public.payments
  set status='تم التسجيل',
      accounting_registered_by=coalesce(accounting_registered_by,auth.uid()),
      accounting_registered_at=coalesce(accounting_registered_at,now()),
      pending_amount=0,
      registered_amount=amount,
      pending_resolved_by=auth.uid(),
      pending_resolved_at=now(),
      pending_resolution_note=trim(p_resolution_note),
      updated_at=now()
  where id=p_payment_id
  returning * into v;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(
    auth.uid(),'PAYMENT_PENDING_RESOLVED','payment',v.id::text,
    jsonb_build_object(
      'had_prior_accounting_registration',v_had_registration,
      'status','تم التسجيل',
      'registered_amount',v.registered_amount,
      'resolution_note',v.pending_resolution_note,
      'previous_pending_type',v.pending_type,
      'previous_reason',v.pending_reason,
      'previous_details',v.pending_details
    )
  );

  perform private.ensure_payment_workflow_v3(v.id);
  return v;
end
$function$;

revoke all on function public.resolve_payment_pending_and_register(uuid,text) from public,anon;
grant execute on function public.resolve_payment_pending_and_register(uuid,text) to authenticated;

create or replace function public.supervisor_finalize_registered_payment(
  p_payment_id uuid,
  p_action text,
  p_reason text default null,
  p_pending_action text default null,
  p_pending_owner_id uuid default null,
  p_follow_up_date date default null
)
returns public.payments
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
declare
  v public.payments;
  v_role text:=private.current_role();
begin
  if v_role not in ('Supervisor','CFO') then
    raise exception 'FINAL_POSTING_RESTRICTED_TO_SUPERVISOR_OR_CFO';
  end if;
  if p_action='Pending' then
    raise exception 'USE_GOVERNED_PAYMENT_PENDING_WORKFLOW';
  end if;
  if p_action<>'Posted' then raise exception 'Invalid action'; end if;

  select * into v from public.payments where id=p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;

  if v.status<>'تم التسجيل'
     or v.accounting_registered_at is null
     or v.posted_at is not null
     or coalesce(v.pending_amount,0)>0 then
    raise exception 'PAYMENT_NOT_READY_FOR_FINAL_POSTING';
  end if;

  update public.payments
  set status='مرحّل',
      posted_by=auth.uid(),
      posted_at=now(),
      registered_amount=amount,
      updated_at=now()
  where id=p_payment_id
  returning * into v;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(
    auth.uid(),
    case when v_role='CFO' then 'PAYMENT_POSTED_BY_CFO' else 'PAYMENT_POSTED_BY_SUPERVISOR' end,
    'payment',v.id::text,
    jsonb_build_object('status','مرحّل','actor_role',v_role,'registered_amount',v.registered_amount)
  );

  perform private.ensure_payment_workflow_v3(v.id);
  return v;
end
$function$;

create or replace function public.post_payment(p_payment_id uuid)
returns public.payments
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
declare v public.payments;
begin
  if not private.is_cfo() then raise exception 'Direct posting is restricted to CFO'; end if;

  update public.payments
  set status='مرحّل',
      posted_by=auth.uid(),
      posted_at=now(),
      registered_amount=amount,
      updated_at=now()
  where id=p_payment_id
    and status='تم التسجيل'
    and accounting_registered_at is not null
    and posted_at is null
    and coalesce(pending_amount,0)=0
  returning * into v;

  if v.id is null then raise exception 'PAYMENT_NOT_READY_FOR_FINAL_POSTING'; end if;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'PAYMENT_POSTED_CFO_OVERRIDE','payment',v.id::text,
         jsonb_build_object('status','مرحّل','registered_amount',v.registered_amount));

  perform private.ensure_payment_workflow_v3(v.id);
  return v;
end
$function$;

create or replace function public.cfo_override_payment_status(p_payment_id uuid,p_status text,p_reason text)
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
  values(auth.uid(),'CFO_PAYMENT_STATUS_OVERRIDE','payment',p_payment_id::text,
         jsonb_build_object('old_status',v_old,'new_status',p_status,'reason',trim(p_reason)));

  perform private.ensure_payment_workflow_v3(v.id);
  return v;
end
$function$;

update public.workcenter_action_rules
set active=false,updated_at=now()
where rule_id='GL_PAYMENT_POST';

insert into public.workcenter_action_rules(
  rule_id,role_key,status_key,action_key,item_type_key,authorization_scope,next_status,audit_event,
  requires_reason,handler_key,sort_order,active,effect,source_guard_key
)
values(
  'GL_PAYMENT_POST_DENY','GLAccountant','*','FINALIZE_POSTING','PAYMENT_POSTING_FINALIZATION',
  'EXACT_ROLE',null,'PAYMENT_POST_DENIED',false,'PAYMENT_POST',0,true,'DENY','ANY'
)
on conflict(rule_id) do update set
  role_key=excluded.role_key,
  status_key=excluded.status_key,
  action_key=excluded.action_key,
  item_type_key=excluded.item_type_key,
  authorization_scope=excluded.authorization_scope,
  next_status=excluded.next_status,
  audit_event=excluded.audit_event,
  requires_reason=excluded.requires_reason,
  handler_key=excluded.handler_key,
  sort_order=excluded.sort_order,
  active=true,
  effect='DENY',
  source_guard_key='ANY',
  updated_at=now();

update public.workcenter_action_rules
set active=true,updated_at=now()
where rule_id in ('SUP_PAYMENT_POST','CFO_PAYMENT_POST');

revoke all on function public.register_payment_accounting(uuid) from public,anon;
grant execute on function public.register_payment_accounting(uuid) to authenticated;
revoke all on function public.supervisor_finalize_registered_payment(uuid,text,text,text,uuid,date) from public,anon;
grant execute on function public.supervisor_finalize_registered_payment(uuid,text,text,text,uuid,date) to authenticated;
revoke all on function public.post_payment(uuid) from public,anon;
grant execute on function public.post_payment(uuid) to authenticated;
revoke all on function public.cfo_override_payment_status(uuid,text,text) from public,anon;
grant execute on function public.cfo_override_payment_status(uuid,text,text) to authenticated;

-- Reassign only currently active, unposted payment workflow items.
-- Historical posted transactions remain untouched.
select private.ensure_payment_workflow_v3(id)
from public.payments
where posted_at is null;
