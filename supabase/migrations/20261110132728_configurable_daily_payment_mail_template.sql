alter table private.daily_payment_mail_config add column template jsonb;

create function public.save_daily_payment_mail_template(p_template jsonb, p_expected jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare
  current_template jsonb;
begin
  if auth.uid() is null or private.current_role() is distinct from 'CFO' then
    raise exception 'CFO_REQUIRED';
  end if;

  if p_template is not null then
    if jsonb_typeof(p_template) <> 'object' then
      raise exception 'MAIL_TEMPLATE_INVALID';
    end if;
    if p_template - array['subject','greeting','intro','closing'] <> '{}'::jsonb
       or jsonb_typeof(p_template->'subject') is distinct from 'string'
       or jsonb_typeof(p_template->'greeting') is distinct from 'string'
       or jsonb_typeof(p_template->'intro') is distinct from 'string'
       or jsonb_typeof(p_template->'closing') is distinct from 'string'
       or char_length(btrim(p_template->>'subject')) not between 1 and 200
       or char_length(p_template->>'subject') > 200
       or (p_template->>'subject') ~ '[[:cntrl:]]'
       or char_length(p_template->>'greeting') > 500
       or char_length(p_template->>'intro') > 2000
       or char_length(p_template->>'closing') > 1000 then
      raise exception 'MAIL_TEMPLATE_INVALID';
    end if;
  end if;

  select template into strict current_template
  from private.daily_payment_mail_config where singleton for update;
  if current_template is distinct from p_expected then
    raise exception 'MAIL_TEMPLATE_CHANGED_REFRESH';
  end if;
  if current_template is not distinct from p_template then
    return;
  end if;

  update private.daily_payment_mail_config
  set template=p_template, updated_at=now(), updated_by=auth.uid()
  where singleton;
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'DAILY_PAYMENT_MAIL_TEMPLATE_CHANGED','mail_config','daily_payments',
    jsonb_build_object('previous_template',current_template,'template',p_template));
end $$;

revoke all on function public.save_daily_payment_mail_template(jsonb,jsonb) from public,anon;
grant execute on function public.save_daily_payment_mail_template(jsonb,jsonb) to authenticated;

-- A copy change alone does not create a second dispatch of the same report.
create function private.find_accepted_daily_payment_report(p_report_date date, p_payload jsonb)
returns uuid language sql stable set search_path='' as $$
  select d.id
  from public.daily_payment_mail_dispatches d
  where d.sender_id=auth.uid() and d.report_date=p_report_date and d.status='Accepted'
    and d.snapshot - array['subject','template','snapshot_hash','already_accepted']
        = p_payload - array['subject','template','snapshot_hash','already_accepted']
  order by d.created_at desc
  limit 1
$$;
revoke all on function private.find_accepted_daily_payment_report(date,jsonb) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION public.get_daily_payment_mail_config()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare c private.daily_payment_mail_config%rowtype;
begin
 if coalesce(private.current_role(),'') not in ('CFO','Supervisor','BankAccountant') then raise exception 'NOT_AUTHORIZED';end if;
 select * into c from private.daily_payment_mail_config;
 return jsonb_build_object('client_id',c.client_id,'tenant_id',c.tenant_id,'to',c.to_addresses,'cc',c.cc_addresses,
 'enabled',c.enabled,'template',c.template,'ready',c.enabled and c.client_id is not null and c.tenant_id is not null and c.dispatch_secret_hash is not null and cardinality(c.to_addresses)>0);
end$function$;

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
 where (p.executed_at at time zone 'Asia/Riyadh')::date=p_report_date and p.supervisor_status='موافق' and p.cfo_status='موافق';
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

CREATE OR REPLACE FUNCTION public.claim_daily_payment_mail(p_report_date date, p_snapshot_hash text, p_request_id uuid, p_server_secret text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare preview jsonb;prior public.daily_payment_mail_dispatches%rowtype;dispatch_id uuid;
begin
 perform private.verify_mail_dispatch_secret(p_server_secret);
 preview:=public.get_daily_payment_mail_preview(p_report_date)-'already_accepted';
 if not (public.get_daily_payment_mail_config()->>'ready')::boolean then raise exception 'MAIL_CONNECTION_REQUIRED';end if;
 if preview->>'snapshot_hash' is distinct from p_snapshot_hash then raise exception 'MAIL_PREVIEW_CHANGED_REFRESH';end if;
 if jsonb_array_length(preview->'items')=0 then raise exception 'MAIL_NO_APPROVED_EXECUTED_PAYMENTS';end if;
 if p_request_id is null then raise exception 'MAIL_REQUEST_REQUIRED';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_report_date::text,0));
 if exists(select 1 from public.daily_payment_mail_dispatches where sender_id=auth.uid() and report_date=p_report_date and status in ('Sending','Unknown')) then raise exception 'MAIL_PREVIOUS_ATTEMPT_UNCERTAIN';end if;
 dispatch_id:=private.find_accepted_daily_payment_report(p_report_date,preview);
 if dispatch_id is not null then
  select * into strict prior from public.daily_payment_mail_dispatches where id=dispatch_id;
  return jsonb_build_object('duplicate',true,'id',prior.id,'snapshot',prior.snapshot,'status',prior.status);
 end if;
 select * into prior from public.daily_payment_mail_dispatches where sender_id=auth.uid() and report_date=p_report_date and snapshot_hash=p_snapshot_hash for update;
 if found then
  if prior.status='Accepted' then return jsonb_build_object('duplicate',true,'id',prior.id,'snapshot',prior.snapshot,'status',prior.status);end if;
  update public.daily_payment_mail_dispatches set status='Sending',request_id=p_request_id,provider_request_id=null,error_code=null,updated_at=now() where id=prior.id;
  dispatch_id:=prior.id;
 else
  insert into public.daily_payment_mail_dispatches(sender_id,report_date,snapshot_hash,snapshot,request_id,status)
  values(auth.uid(),p_report_date,p_snapshot_hash,preview,p_request_id,'Sending') returning id into dispatch_id;
 end if;
 return jsonb_build_object('duplicate',false,'id',dispatch_id,'snapshot',preview,'status','Sending');
end$function$;
