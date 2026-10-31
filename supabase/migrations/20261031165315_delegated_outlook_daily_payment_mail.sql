create table private.daily_payment_mail_config(
 singleton boolean primary key default true check(singleton),client_id uuid,tenant_id uuid,
 to_addresses text[] not null default '{}',cc_addresses text[] not null default '{}',
 enabled boolean not null default false,dispatch_secret_hash text,
 updated_at timestamptz not null default now(),updated_by uuid references public.profiles(id));
insert into private.daily_payment_mail_config(singleton) values(true);
revoke all on private.daily_payment_mail_config from public,anon,authenticated,service_role;
create table public.daily_payment_mail_dispatches(
 id uuid primary key default gen_random_uuid(),sender_id uuid not null references public.profiles(id),
 report_date date not null,snapshot_hash text not null,snapshot jsonb not null,
 request_id uuid not null unique,status text not null check(status in ('Sending','Accepted','Failed','Unknown')),
 provider_request_id text,error_code text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 unique(sender_id,report_date,snapshot_hash));
alter table public.daily_payment_mail_dispatches enable row level security;
revoke all on public.daily_payment_mail_dispatches from anon,authenticated;
grant select on public.daily_payment_mail_dispatches to authenticated;
create policy daily_payment_mail_own_history on public.daily_payment_mail_dispatches for select to authenticated
 using(sender_id=(select auth.uid()) and private.current_role() in ('Supervisor','BankAccountant'));
create or replace function public.get_daily_payment_mail_config()
returns jsonb language plpgsql stable security definer set search_path=public,private,pg_temp as $$
declare c private.daily_payment_mail_config%rowtype;
begin
 if coalesce(private.current_role(),'') not in ('CFO','Supervisor','BankAccountant') then raise exception 'NOT_AUTHORIZED';end if;
 select * into c from private.daily_payment_mail_config;
 return jsonb_build_object('client_id',c.client_id,'tenant_id',c.tenant_id,'to',c.to_addresses,'cc',c.cc_addresses,
 'enabled',c.enabled,'ready',c.enabled and c.client_id is not null and c.tenant_id is not null and c.dispatch_secret_hash is not null and cardinality(c.to_addresses)>0);
end$$;
create or replace function public.configure_daily_payment_mail(p_client_id uuid,p_tenant_id uuid,p_to text[],p_cc text[],p_enabled boolean)
returns void language plpgsql security definer set search_path=public,private,pg_temp as $$
declare address text;
begin
 if private.current_role() is distinct from 'CFO' then raise exception 'CFO_REQUIRED';end if;
 if coalesce(cardinality(p_to),0)>20 or coalesce(cardinality(p_cc),0)>20 then raise exception 'MAIL_TOO_MANY_RECIPIENTS';end if;
 foreach address in array coalesce(p_to,'{}'::text[])||coalesce(p_cc,'{}'::text[]) loop
  if address is null or address!~* '^[A-Z0-9.!#$%&''*+/=?^_`{|}~-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' then raise exception 'MAIL_INVALID_ADDRESS';end if;
 end loop;
 if p_enabled and (p_client_id is null or p_tenant_id is null or coalesce(cardinality(p_to),0)=0) then raise exception 'MAIL_CONNECTION_REQUIRED';end if;
 update private.daily_payment_mail_config set client_id=p_client_id,tenant_id=p_tenant_id,to_addresses=coalesce(p_to,'{}'),cc_addresses=coalesce(p_cc,'{}'),enabled=coalesce(p_enabled,false),updated_at=now(),updated_by=auth.uid();
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'DAILY_PAYMENT_MAIL_CONFIGURED','mail_config','daily_payments',jsonb_build_object('enabled',p_enabled,'to_count',cardinality(p_to),'cc_count',cardinality(p_cc)));
end$$;
create or replace function public.get_daily_payment_mail_preview(p_report_date date)
returns jsonb language plpgsql stable security definer set search_path=public,private,pg_temp as $$
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
 return payload||jsonb_build_object('snapshot_hash',encode(extensions.digest(payload::text,'sha256'),'hex'));
end$$;
create or replace function private.verify_mail_dispatch_secret(p_secret text)
returns void language plpgsql stable security definer set search_path=public,private,pg_temp as $$
declare expected text;
begin
 select dispatch_secret_hash into expected from private.daily_payment_mail_config;
 if p_secret is null or expected is null or encode(extensions.digest(p_secret,'sha256'),'hex')<>expected then raise exception 'MAIL_SERVER_REQUIRED';end if;
end$$;
revoke all on function private.verify_mail_dispatch_secret(text) from public,anon,authenticated;
create or replace function public.claim_daily_payment_mail(p_report_date date,p_snapshot_hash text,p_request_id uuid,p_server_secret text)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare preview jsonb;prior public.daily_payment_mail_dispatches%rowtype;dispatch_id uuid;
begin
 perform private.verify_mail_dispatch_secret(p_server_secret);
 preview:=public.get_daily_payment_mail_preview(p_report_date);
 if not (public.get_daily_payment_mail_config()->>'ready')::boolean then raise exception 'MAIL_CONNECTION_REQUIRED';end if;
 if preview->>'snapshot_hash' is distinct from p_snapshot_hash then raise exception 'MAIL_PREVIEW_CHANGED_REFRESH';end if;
 if jsonb_array_length(preview->'items')=0 then raise exception 'MAIL_NO_APPROVED_EXECUTED_PAYMENTS';end if;
 if p_request_id is null then raise exception 'MAIL_REQUEST_REQUIRED';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_report_date::text,0));
 if exists(select 1 from public.daily_payment_mail_dispatches where sender_id=auth.uid() and report_date=p_report_date and status in ('Sending','Unknown')) then raise exception 'MAIL_PREVIOUS_ATTEMPT_UNCERTAIN';end if;
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
end$$;
create or replace function public.finish_daily_payment_mail(p_dispatch_id uuid,p_status text,p_provider_request_id text,p_error_code text,p_server_secret text)
returns void language plpgsql security definer set search_path=public,private,pg_temp as $$
begin
 perform private.verify_mail_dispatch_secret(p_server_secret);
 if coalesce(private.current_role(),'') not in ('Supervisor','BankAccountant') then raise exception 'MAIL_SENDER_ROLE_REQUIRED';end if;
 if p_status is null or p_status not in ('Accepted','Failed','Unknown') then raise exception 'MAIL_INVALID_STATUS';end if;
 update public.daily_payment_mail_dispatches set status=p_status,provider_request_id=left(p_provider_request_id,200),error_code=left(p_error_code,100),updated_at=now()
 where id=p_dispatch_id and sender_id=auth.uid() and status='Sending';
 if not found then raise exception 'MAIL_DISPATCH_STATE_CONFLICT';end if;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'DAILY_PAYMENT_MAIL_'||upper(p_status),'mail_dispatch',p_dispatch_id::text,jsonb_build_object('status',p_status,'provider_request_id',left(p_provider_request_id,200)));
end$$;
revoke all on function public.get_daily_payment_mail_config(),public.configure_daily_payment_mail(uuid,uuid,text[],text[],boolean),public.get_daily_payment_mail_preview(date),public.claim_daily_payment_mail(date,text,uuid,text),public.finish_daily_payment_mail(uuid,text,text,text,text) from public,anon;
grant execute on function public.get_daily_payment_mail_config(),public.configure_daily_payment_mail(uuid,uuid,text[],text[],boolean),public.get_daily_payment_mail_preview(date),public.claim_daily_payment_mail(date,text,uuid,text),public.finish_daily_payment_mail(uuid,text,text,text,text) to authenticated;
create or replace function public.get_uncertain_daily_payment_mail()
returns table(dispatch_id uuid,report_date date,sender_name text,sender_email text,status text,attempted_at timestamptz)
language plpgsql stable security definer set search_path=public,private,pg_temp as $$
begin
 if private.current_role() is distinct from 'CFO' then raise exception 'CFO_REQUIRED';end if;
 return query select d.id,d.report_date,p.full_name,p.email,d.status,d.created_at from public.daily_payment_mail_dispatches d join public.profiles p on p.id=d.sender_id where d.status in ('Sending','Unknown') order by d.created_at;
end$$;
create or replace function public.resolve_daily_payment_mail_attempt(p_dispatch_id uuid,p_confirmed_sent boolean,p_reason text)
returns void language plpgsql security definer set search_path=public,private,pg_temp as $$
declare d public.daily_payment_mail_dispatches%rowtype;
begin
 if private.current_role() is distinct from 'CFO' then raise exception 'CFO_REQUIRED';end if;
 if p_confirmed_sent is null or length(trim(coalesce(p_reason,''))) not between 20 and 2000 then raise exception 'MAIL_RECONCILIATION_EVIDENCE_REQUIRED';end if;
 select * into d from public.daily_payment_mail_dispatches where id=p_dispatch_id for update;
 if not found or d.status not in ('Sending','Unknown') then raise exception 'MAIL_DISPATCH_STATE_CONFLICT';end if;
 if d.updated_at>now()-interval '5 minutes' then raise exception 'MAIL_ATTEMPT_STILL_RECENT';end if;
 update public.daily_payment_mail_dispatches set status=case when p_confirmed_sent then 'Accepted' else 'Failed' end,error_code='MANUALLY_RECONCILED',updated_at=now() where id=p_dispatch_id;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'DAILY_PAYMENT_MAIL_RECONCILED','mail_dispatch',p_dispatch_id::text,jsonb_build_object('previous_status',d.status,'confirmed_sent',p_confirmed_sent,'evidence_note',trim(p_reason)));
end$$;
revoke all on function public.get_uncertain_daily_payment_mail(),public.resolve_daily_payment_mail_attempt(uuid,boolean,text) from public,anon;
grant execute on function public.get_uncertain_daily_payment_mail(),public.resolve_daily_payment_mail_attempt(uuid,boolean,text) to authenticated;
