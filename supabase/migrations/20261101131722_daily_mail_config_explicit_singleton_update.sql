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
 update private.daily_payment_mail_config set client_id=p_client_id,tenant_id=p_tenant_id,to_addresses=coalesce(p_to,'{}'),cc_addresses=coalesce(p_cc,'{}'),enabled=coalesce(p_enabled,false),updated_at=now(),updated_by=auth.uid() where singleton=true;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'DAILY_PAYMENT_MAIL_CONFIGURED','mail_config','daily_payments',jsonb_build_object('enabled',p_enabled,'to_count',cardinality(p_to),'cc_count',cardinality(p_cc)));
end$$;
