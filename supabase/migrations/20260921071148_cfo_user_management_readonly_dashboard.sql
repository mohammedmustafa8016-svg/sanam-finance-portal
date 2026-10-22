-- Additive user administration and dashboard visibility controls.
-- Existing finance roles, permissions and operational workflows are preserved.

alter table public.allowed_users
  add column if not exists finance_team boolean not null default true,
  add column if not exists dashboard_permissions text[] not null default '{}'::text[];

alter table public.profiles
  add column if not exists finance_team boolean not null default true;

update public.allowed_users set finance_team=(role<>'Viewer') where finance_team is distinct from (role<>'Viewer');
update public.profiles set finance_team=(role<>'Viewer') where finance_team is distinct from (role<>'Viewer');

alter table public.allowed_users drop constraint if exists allowed_users_role_check;
alter table public.allowed_users add constraint allowed_users_role_check
  check(role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant','Viewer'));

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check(role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant','Viewer'));

create or replace function private.default_permission_for_role(p_role text,p_key text)
returns boolean language sql immutable set search_path=public,private,pg_temp as $$
select case p_key
  when 'page.dashboard' then p_role in ('CFO','Supervisor','BankAccountant','Viewer')
  when 'page.banks' then p_role in ('CFO','Supervisor','BankAccountant')
  when 'page.payments' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','APAccountant')
  when 'page.executed' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant')
  when 'page.posted' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','APAccountant')
  when 'page.pending' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant')
  when 'page.tasks' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
  when 'page.workflow' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
  when 'page.workcenter' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
  when 'page.control' then p_role in ('CFO','Supervisor')
  when 'page.workload' then p_role in ('CFO','Supervisor')
  when 'page.escalations' then p_role in ('CFO','Supervisor')
  when 'page.automation' then p_role='CFO'
  when 'page.close' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
  when 'page.imprest' then p_role in ('CFO','Supervisor','BankAccountant','APAccountant')
  when 'page.performance' then p_role in ('CFO','Supervisor','ARAccountant','APAccountant')
  when 'page.ownership' then p_role in ('CFO','Supervisor')
  when 'page.exceptions' then p_role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
  when 'page.audit' then p_role='CFO'
  when 'page.permissions' then p_role='CFO'
  when 'data.bank_balances' then p_role in ('CFO','Supervisor','BankAccountant')
  when 'dashboard.liquidity' then p_role in ('CFO','Supervisor','BankAccountant')
  when 'dashboard.reserves' then p_role in ('CFO','Supervisor','BankAccountant')
  when 'dashboard.payments' then p_role in ('CFO','Supervisor','BankAccountant')
  when 'dashboard.tasks' then p_role in ('CFO','Supervisor','BankAccountant')
  when 'dashboard.close' then p_role in ('CFO','Supervisor','BankAccountant')
  when 'dashboard.exceptions' then p_role in ('CFO','Supervisor','BankAccountant')
  when 'dashboard.team' then p_role in ('CFO','Supervisor','BankAccountant')
  when 'dashboard.automation' then p_role='CFO'
  else false end;
$$;

create or replace function public.get_my_permissions()
returns table(permission_key text,allowed boolean)
language sql stable security definer set search_path=public,private,pg_temp as $$
with keys(permission_key) as (values
  ('page.dashboard'),('page.banks'),('page.payments'),('page.executed'),('page.posted'),('page.pending'),
  ('page.tasks'),('page.workflow'),('page.workcenter'),('page.control'),('page.workload'),('page.escalations'),
  ('page.automation'),('page.close'),('page.imprest'),('page.performance'),('page.ownership'),('page.exceptions'),
  ('page.audit'),('page.permissions'),('data.bank_balances'),
  ('dashboard.liquidity'),('dashboard.reserves'),('dashboard.payments'),('dashboard.tasks'),
  ('dashboard.close'),('dashboard.exceptions'),('dashboard.team'),('dashboard.automation')
)
select k.permission_key,public.has_user_permission(k.permission_key) from keys k;
$$;
revoke all on function public.get_my_permissions() from public,anon;
grant execute on function public.get_my_permissions() to authenticated;

create or replace function public.set_user_permission(p_user_id uuid,p_permission_key text,p_allowed boolean)
returns void language plpgsql security definer set search_path=public,private,pg_temp as $$
declare
  v_target_role text;
  v_finance_team boolean;
  v_bank_data boolean;
  v_allowed_keys constant text[]:=array[
    'page.dashboard','page.banks','page.payments','page.executed','page.posted','page.pending','page.tasks',
    'page.workflow','page.workcenter','page.control','page.workload','page.escalations','page.automation',
    'page.close','page.imprest','page.performance','page.ownership','page.exceptions','page.audit','page.permissions',
    'data.bank_balances','dashboard.liquidity','dashboard.reserves','dashboard.payments','dashboard.tasks',
    'dashboard.close','dashboard.exceptions','dashboard.team','dashboard.automation'
  ];
begin
  if private.current_role()<>'CFO' then raise exception 'Only CFO can manage visibility permissions'; end if;
  if not (p_permission_key=any(v_allowed_keys)) then raise exception 'UNKNOWN_PERMISSION_KEY'; end if;

  select role,finance_team into v_target_role,v_finance_team
    from public.profiles where id=p_user_id and active=true;
  if v_target_role is null then raise exception 'User not found'; end if;

  if p_permission_key='page.permissions' and p_user_id=auth.uid() and p_allowed=false then
    raise exception 'CFO cannot remove own permissions administration access';
  end if;

  if not v_finance_team and p_allowed
     and p_permission_key<>'page.dashboard'
     and p_permission_key not like 'dashboard.%' then
    raise exception 'READ_ONLY_USER_DASHBOARD_ONLY';
  end if;

  if p_allowed and p_permission_key in ('page.banks','data.bank_balances')
     and v_target_role not in ('CFO','Supervisor','BankAccountant') then
    raise exception 'Liquidity and bank balances are restricted to authorized finance roles';
  end if;

  insert into public.user_permissions(user_id,permission_key,allowed,updated_by,updated_at)
  values(p_user_id,p_permission_key,p_allowed,auth.uid(),now())
  on conflict(user_id,permission_key) do update set
    allowed=excluded.allowed,updated_by=auth.uid(),updated_at=now();

  if not v_finance_team and p_permission_key in ('dashboard.liquidity','dashboard.reserves') then
    select coalesce(bool_or(allowed),false) into v_bank_data
      from public.user_permissions
     where user_id=p_user_id and permission_key in ('dashboard.liquidity','dashboard.reserves');
    insert into public.user_permissions(user_id,permission_key,allowed,updated_by,updated_at)
    values(p_user_id,'data.bank_balances',v_bank_data,auth.uid(),now())
    on conflict(user_id,permission_key) do update set
      allowed=excluded.allowed,updated_by=auth.uid(),updated_at=now();
  end if;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'SET_USER_PERMISSION','profile',p_user_id::text,
    jsonb_build_object('permission_key',p_permission_key,'allowed',p_allowed));
end $$;
revoke all on function public.set_user_permission(uuid,text,boolean) from public,anon;
grant execute on function public.set_user_permission(uuid,text,boolean) to authenticated;

create or replace function public.cfo_add_portal_user(
  p_email text,
  p_full_name text,
  p_finance_team boolean,
  p_role text default null,
  p_dashboard_permissions text[] default '{}'::text[]
)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare
  v_email text:=lower(trim(coalesce(p_email,'')));
  v_name text:=trim(coalesce(p_full_name,''));
  v_role text;
  v_profile_id uuid;
  v_dashboard_keys constant text[]:=array[
    'dashboard.liquidity','dashboard.reserves','dashboard.payments','dashboard.tasks',
    'dashboard.close','dashboard.exceptions','dashboard.team','dashboard.automation'
  ];
  v_page_keys constant text[]:=array[
    'page.banks','page.payments','page.executed','page.posted','page.pending','page.tasks','page.workflow',
    'page.workcenter','page.control','page.workload','page.escalations','page.automation','page.close','page.imprest',
    'page.performance','page.ownership','page.exceptions','page.audit','page.permissions'
  ];
  k text;
begin
  if private.current_role()<>'CFO' then raise exception 'Only CFO can add portal users'; end if;
  if v_name='' then raise exception 'FULL_NAME_REQUIRED'; end if;
  if v_email='' or v_email!~* '^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$' then raise exception 'VALID_EMAIL_REQUIRED'; end if;
  if exists(select 1 from unnest(coalesce(p_dashboard_permissions,'{}'::text[])) x where not (x=any(v_dashboard_keys))) then
    raise exception 'INVALID_DASHBOARD_PERMISSION';
  end if;

  if coalesce(p_finance_team,false) then
    v_role:=coalesce(nullif(trim(p_role),''),'APAccountant');
    if v_role not in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant') then
      raise exception 'INVALID_FINANCE_ROLE';
    end if;
  else
    v_role:='Viewer';
  end if;

  insert into public.allowed_users(email,full_name,role,active,finance_team,dashboard_permissions)
  values(v_email,v_name,v_role,true,coalesce(p_finance_team,false),coalesce(p_dashboard_permissions,'{}'::text[]))
  on conflict(email) do update set
    full_name=excluded.full_name,role=excluded.role,active=true,
    finance_team=excluded.finance_team,dashboard_permissions=excluded.dashboard_permissions;

  select id into v_profile_id from public.profiles where lower(email)=v_email limit 1;
  if v_profile_id is not null then
    update public.profiles set full_name=v_name,role=v_role,active=true,
      finance_team=coalesce(p_finance_team,false),updated_at=now()
    where id=v_profile_id;

    delete from public.user_permissions where user_id=v_profile_id;

    if not coalesce(p_finance_team,false) then
      insert into public.user_permissions(user_id,permission_key,allowed,updated_by,updated_at)
      values(v_profile_id,'page.dashboard',true,auth.uid(),now());
      foreach k in array v_page_keys loop
        insert into public.user_permissions(user_id,permission_key,allowed,updated_by,updated_at)
        values(v_profile_id,k,false,auth.uid(),now());
      end loop;
    end if;

    foreach k in array v_dashboard_keys loop
      insert into public.user_permissions(user_id,permission_key,allowed,updated_by,updated_at)
      values(v_profile_id,k,k=any(coalesce(p_dashboard_permissions,'{}'::text[])),auth.uid(),now())
      on conflict(user_id,permission_key) do update set
        allowed=excluded.allowed,updated_by=auth.uid(),updated_at=now();
    end loop;

    if not coalesce(p_finance_team,false) then
      insert into public.user_permissions(user_id,permission_key,allowed,updated_by,updated_at)
      values(v_profile_id,'data.bank_balances',
        ('dashboard.liquidity'=any(coalesce(p_dashboard_permissions,'{}'::text[]))
         or 'dashboard.reserves'=any(coalesce(p_dashboard_permissions,'{}'::text[]))),auth.uid(),now());
    end if;
  end if;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'CFO_ADD_PORTAL_USER','allowed_user',v_email,
    jsonb_build_object('full_name',v_name,'finance_team',coalesce(p_finance_team,false),'role',v_role,
      'dashboard_permissions',coalesce(p_dashboard_permissions,'{}'::text[]),'activated',v_profile_id is not null));

  return jsonb_build_object('email',v_email,'full_name',v_name,'finance_team',coalesce(p_finance_team,false),
    'role',v_role,'activated',v_profile_id is not null,'profile_id',v_profile_id);
end $$;
revoke all on function public.cfo_add_portal_user(text,text,boolean,text,text[]) from public,anon;
grant execute on function public.cfo_add_portal_user(text,text,boolean,text,text[]) to authenticated;

create or replace function public.get_portal_users_admin()
returns table(email text,full_name text,role text,finance_team boolean,active boolean,activated boolean,profile_id uuid,dashboard_permissions text[])
language sql stable security definer set search_path=public,private,pg_temp as $$
select a.email,a.full_name,a.role,a.finance_team,a.active,(p.id is not null),p.id,a.dashboard_permissions
from public.allowed_users a
left join public.profiles p on lower(p.email)=lower(a.email)
where private.current_role()='CFO'
order by a.finance_team desc,a.full_name;
$$;
revoke all on function public.get_portal_users_admin() from public,anon;
grant execute on function public.get_portal_users_admin() to authenticated;

create or replace function public.get_user_permissions_admin()
returns table(user_id uuid,permission_key text,allowed boolean,explicit_override boolean)
language sql stable security definer set search_path=public,private,pg_temp as $$
with keys(permission_key) as (values
  ('page.dashboard'),('page.banks'),('page.payments'),('page.executed'),('page.posted'),('page.pending'),
  ('page.tasks'),('page.workflow'),('page.workcenter'),('page.control'),('page.workload'),('page.escalations'),
  ('page.automation'),('page.close'),('page.imprest'),('page.performance'),('page.ownership'),('page.exceptions'),
  ('page.audit'),('page.permissions'),('data.bank_balances'),
  ('dashboard.liquidity'),('dashboard.reserves'),('dashboard.payments'),('dashboard.tasks'),
  ('dashboard.close'),('dashboard.exceptions'),('dashboard.team'),('dashboard.automation')
)
select p.id,k.permission_key,coalesce(up.allowed,private.default_permission_for_role(p.role,k.permission_key),false),up.user_id is not null
from public.profiles p cross join keys k
left join public.user_permissions up on up.user_id=p.id and up.permission_key=k.permission_key
where p.active and private.current_role()='CFO'
order by p.full_name,k.permission_key;
$$;
revoke all on function public.get_user_permissions_admin() from public,anon;
grant execute on function public.get_user_permissions_admin() to authenticated;

create or replace function private.handle_new_user()
returns trigger language plpgsql security definer set search_path=public,private,pg_temp as $$
declare
  a public.allowed_users%rowtype;
  v_dashboard_keys constant text[]:=array[
    'dashboard.liquidity','dashboard.reserves','dashboard.payments','dashboard.tasks',
    'dashboard.close','dashboard.exceptions','dashboard.team','dashboard.automation'
  ];
  v_page_keys constant text[]:=array[
    'page.banks','page.payments','page.executed','page.posted','page.pending','page.tasks','page.workflow',
    'page.workcenter','page.control','page.workload','page.escalations','page.automation','page.close','page.imprest',
    'page.performance','page.ownership','page.exceptions','page.audit','page.permissions'
  ];
  k text;
begin
  select * into a from public.allowed_users where lower(email)=lower(new.email) and active=true;
  if not found then raise exception 'User email is not authorized for Sanam Finance Portal'; end if;

  insert into public.profiles(id,email,full_name,role,active,finance_team)
  values(new.id,lower(new.email),a.full_name,a.role,true,a.finance_team)
  on conflict(id) do update set email=excluded.email,full_name=excluded.full_name,role=excluded.role,
    active=true,finance_team=excluded.finance_team,updated_at=now();

  if not a.finance_team then
    insert into public.user_permissions(user_id,permission_key,allowed,updated_at)
    values(new.id,'page.dashboard',true,now())
    on conflict(user_id,permission_key) do update set allowed=true,updated_at=now();
    foreach k in array v_page_keys loop
      insert into public.user_permissions(user_id,permission_key,allowed,updated_at)
      values(new.id,k,false,now())
      on conflict(user_id,permission_key) do update set allowed=false,updated_at=now();
    end loop;
  end if;

  foreach k in array v_dashboard_keys loop
    insert into public.user_permissions(user_id,permission_key,allowed,updated_at)
    values(new.id,k,k=any(coalesce(a.dashboard_permissions,'{}'::text[])),now())
    on conflict(user_id,permission_key) do update set allowed=excluded.allowed,updated_at=now();
  end loop;

  if not a.finance_team then
    insert into public.user_permissions(user_id,permission_key,allowed,updated_at)
    values(new.id,'data.bank_balances',
      ('dashboard.liquidity'=any(coalesce(a.dashboard_permissions,'{}'::text[]))
       or 'dashboard.reserves'=any(coalesce(a.dashboard_permissions,'{}'::text[]))),now())
    on conflict(user_id,permission_key) do update set allowed=excluded.allowed,updated_at=now();
  end if;
  return new;
end $$;
revoke all on function private.handle_new_user() from public,anon,authenticated;

create or replace function public.get_readonly_dashboard_snapshot(
  p_company text default null,
  p_from date default null,
  p_to date default null
)
returns jsonb language plpgsql stable security definer set search_path=public,private,cron,pg_temp as $$
declare
  v_today date:=(now() at time zone 'Asia/Riyadh')::date;
  v_company text:=nullif(trim(coalesce(p_company,'')),'');
  v_liquidity jsonb;
  v_reserves jsonb;
  v_payments jsonb;
  v_tasks jsonb;
  v_close jsonb;
  v_exceptions jsonb;
  v_team jsonb;
  v_automation jsonb;
  v_companies jsonb:='[]'::jsonb;
begin
  if private.current_role()<>'Viewer' or not public.has_user_permission('page.dashboard') then
    raise exception 'READ_ONLY_DASHBOARD_NOT_AUTHORIZED';
  end if;
  if p_from is not null and p_to is not null and p_from>p_to then raise exception 'INVALID_DATE_RANGE'; end if;

  if public.has_user_permission('dashboard.liquidity') then
    select jsonb_build_object(
      'total_cash',coalesce(sum(balance),0),
      'operational_cash',coalesce(sum(balance) filter(where coalesce(account_type,'Operational')='Operational'),0),
      'working_capital',coalesce(sum(balance) filter(where account_type='Working Capital Reserve'),0),
      'vat_reserve',coalesce(sum(balance) filter(where account_type='VAT Reserve'),0),
      'pending_reserved',coalesce(sum(reserved_balance),0),
      'net_operational',coalesce(sum(available_balance) filter(where coalesce(account_type,'Operational')='Operational'),0)
    ) into v_liquidity from public.bank_liquidity;
  end if;

  if public.has_user_permission('dashboard.reserves') then
    select coalesce(jsonb_agg(to_jsonb(r) order by r.company,r.bank_name),'[]'::jsonb)
      into v_reserves from public.get_reserve_account_monitor() r;
  end if;

  if public.has_user_permission('dashboard.payments') then
    with filtered as (
      select p.*,b.account_type
      from public.payments p left join public.bank_accounts b on b.id=p.bank_account_id
      where (v_company is null or p.company=v_company)
        and (p_from is null or p.due_date>=p_from)
        and (p_to is null or p.due_date<=p_to)
    ), active as (select * from filtered where status<>'مرحّل')
    select jsonb_build_object(
      'count',(select count(*) from filtered),
      'total_amount',(select coalesce(sum(amount),0) from filtered),
      'awaiting_supervisor',count(*) filter(where supervisor_status='معلق'),
      'awaiting_cfo',count(*) filter(where supervisor_status='موافق' and cfo_status='معلق'),
      'ready_bank',count(*) filter(where cfo_status='موافق' and executed_at is null),
      'executed_unposted',count(*) filter(where executed_at is not null and posted_at is null),
      'protected_active',count(*) filter(where coalesce(account_type,'Operational')<>'Operational')
    ) into v_payments from active;
    select coalesce(jsonb_agg(x.company order by x.company),'[]'::jsonb) into v_companies
      from (select distinct company from public.payments where company is not null) x;
  end if;

  if public.has_user_permission('dashboard.tasks') then
    with filtered as (
      select * from public.tasks
      where (p_from is null or due_date>=p_from) and (p_to is null or due_date<=p_to)
    )
    select jsonb_build_object(
      'total',count(*),
      'today',count(*) filter(where due_date=v_today),
      'completed',count(*) filter(where status='مكتمل'),
      'overdue',count(*) filter(where status not in ('مكتمل','بانتظار المراجعة') and private.task_deadline(due_date,due_time)<now()),
      'blocked',count(*) filter(where nullif(trim(coalesce(blocker_note,'')),'') is not null),
      'pending_review',count(*) filter(where status='بانتظار المراجعة'),
      'justification_required',count(*) filter(where justification_requested_at is not null and nullif(trim(coalesce(delay_justification,'')),'') is null)
    ) into v_tasks from filtered;
  end if;

  if public.has_user_permission('dashboard.close') then
    with latest as (select max(close_period) period from public.monthly_close_tasks), cycle as (
      select m.* from public.monthly_close_tasks m,latest l where m.close_period=l.period
    )
    select jsonb_build_object(
      'period',(select period from latest),
      'total',count(*),
      'completed',count(*) filter(where status='مكتمل' or coalesce(progress,0)>=100),
      'completion_rate',case when count(*)=0 then 0 else round(count(*) filter(where status='مكتمل' or coalesce(progress,0)>=100)*100.0/count(*),1) end,
      'overdue',count(*) filter(where due_date<v_today and status<>'مكتمل' and coalesce(progress,0)<100),
      'next_due',(select jsonb_build_object('code',code,'due_date',due_date) from cycle where status<>'مكتمل' and coalesce(progress,0)<100 and due_date is not null order by due_date limit 1)
    ) into v_close from cycle;
  end if;

  if public.has_user_permission('dashboard.exceptions') then
    select jsonb_build_object(
      'open_count',count(*) filter(where status not in ('مغلق','Closed')),
      'items',coalesce(jsonb_agg(jsonb_build_object('type',type,'severity',severity,'detail',detail,'status',status,'created_at',created_at)
        order by created_at desc) filter(where status not in ('مغلق','Closed')),'[]'::jsonb)
    ) into v_exceptions from public.exceptions;
  end if;

  if public.has_user_permission('dashboard.team') then
    with team as (
      select id,full_name,role from public.profiles where active and finance_team and role<>'CFO'
    ), stats as (
      select p.id,p.full_name,p.role,
        count(t.id) filter(where (p_from is null or t.due_date>=p_from) and (p_to is null or t.due_date<=p_to))::int total,
        count(t.id) filter(where t.status='مكتمل' and (p_from is null or t.due_date>=p_from) and (p_to is null or t.due_date<=p_to))::int completed,
        count(t.id) filter(where t.status='بانتظار المراجعة')::int pending_review,
        count(t.id) filter(where t.status not in ('مكتمل','بانتظار المراجعة') and private.task_deadline(t.due_date,t.due_time)<now())::int overdue,
        count(t.id) filter(where nullif(trim(coalesce(t.blocker_note,'')),'') is not null)::int blocked
      from team p left join public.tasks t on t.owner_id=p.id group by p.id,p.full_name,p.role
    )
    select coalesce(jsonb_agg(jsonb_build_object('user_id',id,'full_name',full_name,'role',role,'total',total,
      'completed',completed,'pending_review',pending_review,'overdue',overdue,'blocked',blocked,
      'completion_rate',case when total=0 then 0 else round(completed*100.0/total,1) end)
      order by full_name),'[]'::jsonb) into v_team from stats;
  end if;

  if public.has_user_permission('dashboard.automation') then
    with jobs as (
      select j.jobid,j.jobname,j.active,j.schedule from cron.job j
      where j.jobname in ('sanam_generate_daily_tasks','sanam_generate_monthly_close_tasks','sanam_task_v2_deadline_monitor')
    ), latest as (
      select j.*,r.start_time,r.status from jobs j left join lateral(
        select d.start_time,d.status from cron.job_run_details d where d.jobid=j.jobid order by d.start_time desc limit 1
      ) r on true
    )
    select coalesce(jsonb_agg(jsonb_build_object('job_name',jobname,'active',active,'schedule',schedule,
      'last_run_at',start_time,'last_status',status) order by jobname),'[]'::jsonb) into v_automation from latest;
  end if;

  return jsonb_build_object(
    'filters',jsonb_build_object('company',v_company,'from',p_from,'to',p_to,'companies',v_companies),
    'liquidity',v_liquidity,'reserves',v_reserves,'payments',v_payments,'tasks',v_tasks,
    'close',v_close,'exceptions',v_exceptions,'team',v_team,'automation',v_automation
  );
end $$;
revoke all on function public.get_readonly_dashboard_snapshot(text,date,date) from public,anon;
grant execute on function public.get_readonly_dashboard_snapshot(text,date,date) to authenticated;

create or replace function private.reject_readonly_viewer_mutation()
returns trigger language plpgsql security definer set search_path=public,private,pg_temp as $$
begin
  if private.current_role()='Viewer' then raise exception 'READ_ONLY_USER_MUTATION_DENIED'; end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
revoke all on function private.reject_readonly_viewer_mutation() from public,anon,authenticated;

do $$
declare r record;
begin
  for r in
    select tablename from pg_tables
    where schemaname='public'
      and tablename not in ('profiles','allowed_users','user_permissions','audit_log')
  loop
    execute format('drop trigger if exists reject_readonly_viewer_mutation on public.%I',r.tablename);
    execute format('create trigger reject_readonly_viewer_mutation before insert or update or delete on public.%I for each row execute function private.reject_readonly_viewer_mutation()',r.tablename);
  end loop;
end $$;
