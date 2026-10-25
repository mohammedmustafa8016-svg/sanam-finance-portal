\set ON_ERROR_STOP on
\pset pager off

create temp table security_findings(
  severity text not null,
  check_id text not null,
  object_name text not null,
  detail text not null
);

-- S01: every user-owned public table must have RLS enabled.
insert into security_findings
select 'FAIL','S01_PUBLIC_TABLE_RLS',format('%I.%I',n.nspname,c.relname),
       'public base/partitioned table has RLS disabled'
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public'
  and c.relkind in ('r','p')
  and not c.relrowsecurity
  and not exists (
    select 1 from pg_depend d
    where d.classid='pg_class'::regclass
      and d.objid=c.oid
      and d.deptype='e'
  );

-- S02: anon must have no direct DML/read privilege on finance tables.
insert into security_findings
select 'INFO','I01_ANON_TABLE_GRANT_RLS_GATED',format('%I.%I',n.nspname,c.relname),
       concat_ws(',',
         case when has_table_privilege('anon',c.oid,'SELECT') then 'SELECT' end,
         case when has_table_privilege('anon',c.oid,'INSERT') then 'INSERT' end,
         case when has_table_privilege('anon',c.oid,'UPDATE') then 'UPDATE' end,
         case when has_table_privilege('anon',c.oid,'DELETE') then 'DELETE' end,
         case when has_table_privilege('anon',c.oid,'TRUNCATE') then 'TRUNCATE' end,
         case when has_table_privilege('anon',c.oid,'REFERENCES') then 'REFERENCES' end,
         case when has_table_privilege('anon',c.oid,'TRIGGER') then 'TRIGGER' end
       )
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public'
  and c.relkind in ('r','p')
  and not exists (
    select 1 from pg_depend d
    where d.classid='pg_class'::regclass and d.objid=c.oid and d.deptype='e'
  )
  and (
    has_table_privilege('anon',c.oid,'SELECT') or
    has_table_privilege('anon',c.oid,'INSERT') or
    has_table_privilege('anon',c.oid,'UPDATE') or
    has_table_privilege('anon',c.oid,'DELETE') or
    has_table_privilege('anon',c.oid,'TRUNCATE') or
    has_table_privilege('anon',c.oid,'REFERENCES') or
    has_table_privilege('anon',c.oid,'TRIGGER')
  );

-- S02B: a policy directly applicable to anon/PUBLIC must never be unconditional.
insert into security_findings
select 'FAIL','S02_ANON_UNCONDITIONAL_POLICY',format('%I.%I/%I',schemaname,tablename,policyname),
       concat('cmd=',cmd,', roles=',roles::text,', qual=',coalesce(qual,''),', check=',coalesce(with_check,''))
from pg_policies
where schemaname='public'
  and (roles::text ilike '%anon%' or roles::text ilike '%public%')
  and (
    (cmd in ('SELECT','DELETE','ALL') and coalesce(qual,'') in ('true','(true)'))
    or
    (cmd in ('INSERT','UPDATE','ALL') and coalesce(with_check,'') in ('true','(true)'))
  );

-- S03: exposed views must not bypass underlying RLS.
insert into security_findings
select 'FAIL','S03_EXPOSED_VIEW_RLS_BYPASS',format('%I.%I',n.nspname,c.relname),
       concat('relkind=',c.relkind,', reloptions=',coalesce(array_to_string(c.reloptions,','),'(none)'))
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public'
  and c.relkind in ('v','m')
  and (
    has_table_privilege('anon',c.oid,'SELECT') or
    has_table_privilege('authenticated',c.oid,'SELECT')
  )
  and (
    c.relkind='m' or
    coalesce(array_to_string(c.reloptions,','),'') not like '%security_invoker=true%'
  );

-- S04: no exposed SECURITY DEFINER function may be executable by anon.
insert into security_findings
select 'FAIL','S04_ANON_SECURITY_DEFINER_EXECUTE',
       format('%I.%I(%s)',n.nspname,p.proname,pg_get_function_identity_arguments(p.oid)),
       'anon can EXECUTE an exposed SECURITY DEFINER function'
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where p.prokind='f'
  and n.nspname='public'
  and p.prosecdef
  and has_function_privilege('anon',p.oid,'EXECUTE');

-- S05: SECURITY DEFINER must pin search_path.
insert into security_findings
select 'FAIL','S05_SECURITY_DEFINER_MUTABLE_SEARCH_PATH',
       format('%I.%I(%s)',n.nspname,p.proname,pg_get_function_identity_arguments(p.oid)),
       'SECURITY DEFINER function has no SET search_path'
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where p.prokind='f'
  and n.nspname in ('public','private')
  and p.prosecdef
  and not exists (
    select 1 from unnest(coalesce(p.proconfig,array[]::text[])) cfg
    where cfg like 'search_path=%'
  );

-- S06: authorization policies must not depend on user-editable metadata.
insert into security_findings
select 'FAIL','S06_RLS_USER_METADATA',format('%I.%I/%I',schemaname,tablename,policyname),
       concat('qual=',coalesce(qual,''),' check=',coalesce(with_check,''))
from pg_policies
where schemaname='public'
  and (
    coalesce(qual,'') ilike '%raw_user_meta_data%' or
    coalesce(with_check,'') ilike '%raw_user_meta_data%' or
    coalesce(qual,'') ilike '%user_metadata%' or
    coalesce(with_check,'') ilike '%user_metadata%'
  );

-- S07: auth.role() is deprecated and unsafe for anonymous-auth distinction.
insert into security_findings
select 'FAIL','S07_DEPRECATED_AUTH_ROLE',format('%I.%I/%I',schemaname,tablename,policyname),
       concat('qual=',coalesce(qual,''),' check=',coalesce(with_check,''))
from pg_policies
where schemaname='public'
  and (
    coalesce(qual,'') ilike '%auth.role(%' or
    coalesce(with_check,'') ilike '%auth.role(%'
  );

-- S08: exposed auth.users-derived views are not permitted.
insert into security_findings
select 'FAIL','S08_AUTH_USERS_EXPOSED_VIEW',format('%I.%I',n.nspname,c.relname),
       'view definition references auth.users and is readable by Data API roles'
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public'
  and c.relkind='v'
  and pg_get_viewdef(c.oid,true) ilike '%auth.users%'
  and (
    has_table_privilege('anon',c.oid,'SELECT') or
    has_table_privilege('authenticated',c.oid,'SELECT')
  );

-- Advisory findings: UPDATE policies lacking explicit WITH CHECK.
insert into security_findings
select 'WARN','W01_UPDATE_POLICY_NO_WITH_CHECK',format('%I.%I/%I',schemaname,tablename,policyname),
       concat('cmd=',cmd,', qual=',coalesce(qual,''))
from pg_policies
where schemaname='public'
  and cmd in ('UPDATE','ALL')
  and with_check is null;

-- Advisory: permissive TRUE read policies for authenticated users.
insert into security_findings
select 'WARN','W02_AUTHENTICATED_USING_TRUE',format('%I.%I/%I',schemaname,tablename,policyname),
       concat('cmd=',cmd,', roles=',roles::text)
from pg_policies
where schemaname='public'
  and coalesce(qual,'') in ('true','(true)')
  and roles::text ilike '%authenticated%';

-- Critical explicit checks.
do $$
declare t text;
begin
  foreach t in array array[
    'profiles','bank_accounts','payments','tasks','leave_delegations','exceptions','audit_log',
    'monthly_close_tasks','imprest_funds','workflow_instances','workflow_steps','work_items','work_item_events'
  ] loop
    if to_regclass('public.'||t) is null then
      raise exception 'SECURITY_CRITICAL_TABLE_MISSING:%',t;
    end if;
    if not (select relrowsecurity from pg_class where oid=to_regclass('public.'||t)) then
      raise exception 'SECURITY_CRITICAL_RLS_DISABLED:%',t;
    end if;
  end loop;

  if has_table_privilege('authenticated','public.finance_settings','SELECT')
     or has_table_privilege('authenticated','public.finance_settings','INSERT')
     or has_table_privilege('authenticated','public.finance_settings','UPDATE')
     or has_table_privilege('authenticated','public.finance_settings','DELETE') then
    raise exception 'FINANCE_SETTINGS_DIRECT_ACCESS_EXPOSED';
  end if;
end $$;

-- Policy and privilege inventory for the signed report.
select 'SECURITY_SUMMARY' marker,
       (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
          where n.nspname='public' and c.relkind in ('r','p')
            and not exists(select 1 from pg_depend d where d.classid='pg_class'::regclass and d.objid=c.oid and d.deptype='e')) public_tables,
       (select count(*) from pg_policies where schemaname='public') public_policies,
       (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
          where n.nspname='public' and p.prosecdef) public_security_definer,
       (select count(*) from security_findings where severity='FAIL') hard_failures,
       (select count(*) from security_findings where severity='WARN') warnings;

select 'SECURITY_FINDING' marker,severity,check_id,object_name,detail
from security_findings
order by case severity when 'FAIL' then 0 else 1 end,check_id,object_name;

select 'RLS_POLICY' marker,schemaname,tablename,policyname,permissive,roles,cmd,
       coalesce(qual,'') qual,coalesce(with_check,'') with_check
from pg_policies
where schemaname='public'
order by tablename,policyname;

select 'EXPOSED_VIEW' marker,n.nspname schemaname,c.relname,
       c.relkind,coalesce(array_to_string(c.reloptions,','),'') reloptions,
       has_table_privilege('anon',c.oid,'SELECT') anon_select,
       has_table_privilege('authenticated',c.oid,'SELECT') authenticated_select
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind in ('v','m')
order by c.relname;

select 'AUTH_SECURITY_DEFINER' marker,
       format('%I.%I(%s)',n.nspname,p.proname,pg_get_function_identity_arguments(p.oid)) function_name,
       has_function_privilege('anon',p.oid,'EXECUTE') anon_execute,
       has_function_privilege('authenticated',p.oid,'EXECUTE') authenticated_execute,
       exists(select 1 from unnest(coalesce(p.proconfig,array[]::text[])) cfg where cfg like 'search_path=%') pinned_search_path,
       (pg_get_functiondef(p.oid) ilike '%auth.uid()%'
         or pg_get_functiondef(p.oid) ilike '%current_role()%'
         or pg_get_functiondef(p.oid) ilike '%is_cfo()%'
         or pg_get_functiondef(p.oid) ilike '%is_supervisor%') inline_auth_signal
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.prosecdef and has_function_privilege('authenticated',p.oid,'EXECUTE')
order by p.proname,pg_get_function_identity_arguments(p.oid);

-- Behavioral RLS fixtures: all changes are rolled back.
begin;

select id cfo_id from public.profiles where role='CFO' and active limit 1 \gset
select id bank_id from public.profiles where role='BankAccountant' and active limit 1 \gset
select id ar_id from public.profiles where role='ARAccountant' and active limit 1 \gset
select id ap_id from public.profiles where role='APAccountant' and active limit 1 \gset

select set_config('request.jwt.claim.sub',:'cfo_id',true);
select public.set_workflow_v3_enabled(true,'CI Security/RLS fixture');
select public.set_workcenter_rule_engine_enabled(true,'CI Security/RLS fixture');

insert into public.tasks(name,owner_id,reviewer_id,due_date,due_time,status,priority,created_by)
values('SEC_RLS_BANK_TASK',:'bank_id',:'cfo_id',(now() at time zone 'Asia/Riyadh')::date+7,'17:00','لم يبدأ','عادي',:'cfo_id')
returning id bank_task_id \gset

insert into public.tasks(name,owner_id,reviewer_id,due_date,due_time,status,priority,created_by)
values('SEC_RLS_AR_TASK',:'ar_id',:'cfo_id',(now() at time zone 'Asia/Riyadh')::date+7,'17:00','لم يبدأ','عادي',:'cfo_id')
returning id ar_task_id \gset

select id bank_work_item_id from public.work_items where source_entity_type='task' and source_entity_id=:'bank_task_id' \gset
select id ar_work_item_id from public.work_items where source_entity_type='task' and source_entity_id=:'ar_task_id' \gset

insert into public.bank_accounts(company,bank_name,account_name,account_no,balance,created_by)
values('LOCAL SECURITY TEST','LOCAL BANK','LOCAL ACCOUNT','0000',1000,:'cfo_id')
returning id security_bank_account_id \gset

insert into public.payments(due_date,company,beneficiary,amount,bank_account_id,purpose,requested_by)
values((now() at time zone 'Asia/Riyadh')::date+7,'LOCAL SECURITY TEST','LOCAL BENEFICIARY',100,:'security_bank_account_id','RLS TEST',:'ap_id')
returning id security_payment_id \gset

-- Effective anonymous access: secure outcome may be either permission denial or zero visible rows.
set local role anon;
select set_config('request.jwt.claim.sub','',true);

do $$
declare n bigint;
begin
  begin
    select count(*) into n from public.profiles;
    if n<>0 then raise exception 'ANON_PROFILES_VISIBLE:%',n; end if;
  exception when insufficient_privilege then null; end;

  begin
    select count(*) into n from public.tasks where name in ('SEC_RLS_BANK_TASK','SEC_RLS_AR_TASK');
    if n<>0 then raise exception 'ANON_TASKS_VISIBLE:%',n; end if;
  exception when insufficient_privilege then null; end;

  begin
    select count(*) into n from public.work_items where title in ('SEC_RLS_BANK_TASK','SEC_RLS_AR_TASK');
    if n<>0 then raise exception 'ANON_WORK_ITEMS_VISIBLE:%',n; end if;
  exception when insufficient_privilege then null; end;

  begin
    select count(*) into n from public.payments where purpose='RLS TEST' and company='LOCAL SECURITY TEST';
    if n<>0 then raise exception 'ANON_PAYMENT_VISIBLE:%',n; end if;
  exception when insufficient_privilege then null; end;

  begin
    select count(*) into n from public.bank_accounts where company='LOCAL SECURITY TEST' and bank_name='LOCAL BANK';
    if n<>0 then raise exception 'ANON_BANK_VISIBLE:%',n; end if;
  exception when insufficient_privilege then null; end;

  begin
    select count(*) into n from public.audit_log;
    if n<>0 then raise exception 'ANON_AUDIT_VISIBLE:%',n; end if;
  exception when insufficient_privilege then null; end;

  begin
    insert into public.tasks(name,status) values('ANON_INSERT_MUST_FAIL','لم يبدأ');
    raise exception 'ANON_TASK_INSERT_SUCCEEDED';
  exception when insufficient_privilege then null; end;
end $$;

reset role;

-- Bank accountant: own task/work item only; cannot read audit; can read payment.
set local role authenticated;
select set_config('request.jwt.claim.sub',:'bank_id',true);
select (count(*)=1)::text bank_own_task_visible from public.tasks where id=:'bank_task_id' \gset
select (count(*)=0)::text bank_ar_task_hidden from public.tasks where id=:'ar_task_id' \gset
select (count(*)=1)::text bank_own_work_visible from public.work_items where id=:'bank_work_item_id' \gset
select (count(*)=0)::text bank_ar_work_hidden from public.work_items where id=:'ar_work_item_id' \gset
select (count(*)=0)::text bank_audit_hidden from public.audit_log \gset
select (count(*)=1)::text bank_payment_visible from public.payments where id=:'security_payment_id' \gset
\if :bank_own_task_visible
\else
  \quit 31
\endif
\if :bank_ar_task_hidden
\else
  \quit 32
\endif
\if :bank_own_work_visible
\else
  \quit 33
\endif
\if :bank_ar_work_hidden
\else
  \quit 34
\endif
\if :bank_audit_hidden
\else
  \quit 35
\endif
\if :bank_payment_visible
\else
  \quit 36
\endif

-- AR accountant: own task visible; payment hidden by RLS.
select set_config('request.jwt.claim.sub',:'ar_id',true);
select (count(*)=1)::text ar_own_task_visible from public.tasks where id=:'ar_task_id' \gset
select (count(*)=0)::text ar_bank_task_hidden from public.tasks where id=:'bank_task_id' \gset
select (count(*)=0)::text ar_payment_hidden from public.payments where id=:'security_payment_id' \gset
\if :ar_own_task_visible
\else
  \quit 41
\endif
\if :ar_bank_task_hidden
\else
  \quit 42
\endif
\if :ar_payment_hidden
\else
  \quit 43
\endif

-- AP accountant: payment readable by intended policy.
select set_config('request.jwt.claim.sub',:'ap_id',true);
select (count(*)=1)::text ap_payment_visible from public.payments where id=:'security_payment_id' \gset
\if :ap_payment_visible
\else
  \quit 51
\endif

-- CFO: team-wide task/work item visibility and audit visibility.
select set_config('request.jwt.claim.sub',:'cfo_id',true);
select (count(*)=2)::text cfo_tasks_visible from public.tasks where id in (:'bank_task_id',:'ar_task_id') \gset
select (count(*)=2)::text cfo_work_visible from public.work_items where id in (:'bank_work_item_id',:'ar_work_item_id') \gset
select (count(*)>0)::text cfo_audit_visible from public.audit_log \gset
\if :cfo_tasks_visible
\else
  \quit 61
\endif
\if :cfo_work_visible
\else
  \quit 62
\endif
\if :cfo_audit_visible
\else
  \quit 63
\endif

reset role;
rollback;

select 'RLS_BEHAVIOR' marker,
       'PASS' result,
       'Bank/AR cross-user isolation; AP/Bank payment visibility; AR payment denial; CFO team/audit visibility' detail;

do $$
begin
  if exists(select 1 from security_findings where severity='FAIL') then
    raise exception 'SECURITY_RLS_GATE_FAILED: % hard findings',
      (select count(*) from security_findings where severity='FAIL');
  end if;
end $$;

select 'SECURITY_RLS_GATE' marker,'PASS' result;
