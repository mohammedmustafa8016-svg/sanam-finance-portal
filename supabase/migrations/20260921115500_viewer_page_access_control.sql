
-- CFO-controlled page visibility for read-only Viewer users.
-- Additive: finance-team behavior and existing workflow permissions remain unchanged.

alter table public.allowed_users
  add column if not exists page_permissions text[] not null default '{}'::text[];

update public.allowed_users
set page_permissions=array['page.dashboard']::text[]
where finance_team=false
  and coalesce(cardinality(page_permissions),0)=0;

create or replace function private.viewer_page_keys()
returns text[] language sql immutable set search_path=public,private,pg_temp as $$
select array[
  'page.dashboard','page.workcenter','page.banks','page.payments','page.executed',
  'page.posted','page.pending','page.close','page.imprest','page.performance',
  'page.ownership','page.exceptions','page.automation','page.audit'
]::text[];
$$;

create or replace function public.set_user_permission(p_user_id uuid,p_permission_key text,p_allowed boolean)
returns void language plpgsql security definer set search_path=public,private,pg_temp as $$
declare
  v_target_role text;
  v_finance_team boolean;
  v_target_email text;
  v_bank_data boolean;
  v_viewer_pages text[]:=private.viewer_page_keys();
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

  select role,finance_team,email into v_target_role,v_finance_team,v_target_email
  from public.profiles where id=p_user_id and active=true;
  if v_target_role is null then raise exception 'User not found'; end if;

  if p_permission_key='page.permissions' and p_user_id=auth.uid() and p_allowed=false then
    raise exception 'CFO cannot remove own permissions administration access';
  end if;

  if not v_finance_team then
    if p_permission_key='page.permissions' or p_permission_key in ('page.tasks','page.workflow','page.control','page.workload','page.escalations') then
      if p_allowed then raise exception 'VIEWER_PAGE_NOT_EXPOSABLE'; end if;
    elsif p_permission_key like 'page.%' and not (p_permission_key=any(v_viewer_pages)) then
      if p_allowed then raise exception 'VIEWER_PAGE_NOT_EXPOSABLE'; end if;
    elsif p_permission_key='data.bank_balances' then
      raise exception 'VIEWER_DATA_PERMISSION_IS_DERIVED';
    end if;
  end if;

  if v_finance_team and p_allowed and p_permission_key in ('page.banks','data.bank_balances')
     and v_target_role not in ('CFO','Supervisor','BankAccountant') then
    raise exception 'Liquidity and bank balances are restricted to authorized finance roles';
  end if;

  insert into public.user_permissions(user_id,permission_key,allowed,updated_by,updated_at)
  values(p_user_id,p_permission_key,p_allowed,auth.uid(),now())
  on conflict(user_id,permission_key) do update set
    allowed=excluded.allowed,updated_by=auth.uid(),updated_at=now();

  if not v_finance_team and (p_permission_key='page.banks' or p_permission_key in ('dashboard.liquidity','dashboard.reserves')) then
    select coalesce(bool_or(allowed),false) into v_bank_data
    from public.user_permissions
    where user_id=p_user_id
      and permission_key in ('page.banks','dashboard.liquidity','dashboard.reserves');

    insert into public.user_permissions(user_id,permission_key,allowed,updated_by,updated_at)
    values(p_user_id,'data.bank_balances',v_bank_data,auth.uid(),now())
    on conflict(user_id,permission_key) do update set
      allowed=excluded.allowed,updated_by=auth.uid(),updated_at=now();
  end if;

  if not v_finance_team and p_permission_key like 'page.%' then
    update public.allowed_users a
    set page_permissions=coalesce((
      select array_agg(up.permission_key order by up.permission_key)
      from public.user_permissions up
      where up.user_id=p_user_id and up.allowed=true and up.permission_key=any(v_viewer_pages)
    ),'{}'::text[])
    where lower(a.email)=lower(v_target_email);
  end if;

  if not v_finance_team and p_permission_key like 'dashboard.%' then
    update public.allowed_users a
    set dashboard_permissions=coalesce((
      select array_agg(up.permission_key order by up.permission_key)
      from public.user_permissions up
      where up.user_id=p_user_id and up.allowed=true and up.permission_key like 'dashboard.%'
    ),'{}'::text[])
    where lower(a.email)=lower(v_target_email);
  end if;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'SET_USER_PERMISSION','profile',p_user_id::text,
    jsonb_build_object('permission_key',p_permission_key,'allowed',p_allowed));
end $$;
revoke all on function public.set_user_permission(uuid,text,boolean) from public,anon;
grant execute on function public.set_user_permission(uuid,text,boolean) to authenticated;

drop function if exists public.cfo_add_portal_user(text,text,boolean,text,text[]);

create or replace function public.cfo_add_portal_user(
  p_email text,
  p_full_name text,
  p_finance_team boolean,
  p_role text default null,
  p_dashboard_permissions text[] default '{}'::text[],
  p_page_permissions text[] default array['page.dashboard']::text[]
)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare
  v_email text:=lower(trim(coalesce(p_email,'')));
  v_name text:=trim(coalesce(p_full_name,''));
  v_role text;
  v_profile_id uuid;
  v_pages text[]:=coalesce(p_page_permissions,'{}'::text[]);
  v_dashboard text[]:=coalesce(p_dashboard_permissions,'{}'::text[]);
  v_viewer_pages text[]:=private.viewer_page_keys();
  v_dashboard_keys constant text[]:=array[
    'dashboard.liquidity','dashboard.reserves','dashboard.payments','dashboard.tasks',
    'dashboard.close','dashboard.exceptions','dashboard.team','dashboard.automation'
  ];
  v_all_page_keys constant text[]:=array[
    'page.dashboard','page.banks','page.payments','page.executed','page.posted','page.pending','page.tasks','page.workflow',
    'page.workcenter','page.control','page.workload','page.escalations','page.automation','page.close','page.imprest',
    'page.performance','page.ownership','page.exceptions','page.audit','page.permissions'
  ];
  k text;
  v_bank_data boolean;
begin
  if private.current_role()<>'CFO' then raise exception 'Only CFO can add portal users'; end if;
  if v_name='' then raise exception 'FULL_NAME_REQUIRED'; end if;
  if v_email='' or v_email!~* '^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$' then raise exception 'VALID_EMAIL_REQUIRED'; end if;
  if exists(select 1 from unnest(v_dashboard) x where not (x=any(v_dashboard_keys))) then
    raise exception 'INVALID_DASHBOARD_PERMISSION';
  end if;

  if coalesce(p_finance_team,false) then
    v_role:=coalesce(nullif(trim(p_role),''),'APAccountant');
    if v_role not in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant') then
      raise exception 'INVALID_FINANCE_ROLE';
    end if;
    v_pages:='{}'::text[];
  else
    v_role:='Viewer';
    if exists(select 1 from unnest(v_pages) x where not (x=any(v_viewer_pages))) then
      raise exception 'INVALID_VIEWER_PAGE_PERMISSION';
    end if;
    if cardinality(v_pages)=0 then raise exception 'VIEWER_REQUIRES_AT_LEAST_ONE_PAGE'; end if;
  end if;

  insert into public.allowed_users(email,full_name,role,active,finance_team,dashboard_permissions,page_permissions)
  values(v_email,v_name,v_role,true,coalesce(p_finance_team,false),v_dashboard,v_pages)
  on conflict(email) do update set
    full_name=excluded.full_name,role=excluded.role,active=true,
    finance_team=excluded.finance_team,dashboard_permissions=excluded.dashboard_permissions,
    page_permissions=excluded.page_permissions;

  select id into v_profile_id from public.profiles where lower(email)=v_email limit 1;
  if v_profile_id is not null then
    update public.profiles set full_name=v_name,role=v_role,active=true,
      finance_team=coalesce(p_finance_team,false),updated_at=now()
    where id=v_profile_id;

    if coalesce(p_finance_team,false) then
      delete from public.user_permissions
      where user_id=v_profile_id
        and (permission_key=any(v_all_page_keys) or permission_key='data.bank_balances');
    else
      foreach k in array v_all_page_keys loop
        insert into public.user_permissions(user_id,permission_key,allowed,updated_by,updated_at)
        values(v_profile_id,k,k=any(v_pages),auth.uid(),now())
        on conflict(user_id,permission_key) do update set
          allowed=excluded.allowed,updated_by=auth.uid(),updated_at=now();
      end loop;
    end if;

    foreach k in array v_dashboard_keys loop
      insert into public.user_permissions(user_id,permission_key,allowed,updated_by,updated_at)
      values(v_profile_id,k,k=any(v_dashboard),auth.uid(),now())
      on conflict(user_id,permission_key) do update set
        allowed=excluded.allowed,updated_by=auth.uid(),updated_at=now();
    end loop;

    if not coalesce(p_finance_team,false) then
      v_bank_data:=('page.banks'=any(v_pages)
        or 'dashboard.liquidity'=any(v_dashboard)
        or 'dashboard.reserves'=any(v_dashboard));
      insert into public.user_permissions(user_id,permission_key,allowed,updated_by,updated_at)
      values(v_profile_id,'data.bank_balances',v_bank_data,auth.uid(),now())
      on conflict(user_id,permission_key) do update set
        allowed=excluded.allowed,updated_by=auth.uid(),updated_at=now();
    end if;
  end if;

  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'CFO_ADD_PORTAL_USER','allowed_user',v_email,
    jsonb_build_object('full_name',v_name,'finance_team',coalesce(p_finance_team,false),'role',v_role,
      'dashboard_permissions',v_dashboard,'page_permissions',v_pages,'activated',v_profile_id is not null));

  return jsonb_build_object('email',v_email,'full_name',v_name,'finance_team',coalesce(p_finance_team,false),
    'role',v_role,'activated',v_profile_id is not null,'profile_id',v_profile_id,
    'page_permissions',v_pages,'dashboard_permissions',v_dashboard);
end $$;
revoke all on function public.cfo_add_portal_user(text,text,boolean,text,text[],text[]) from public,anon;
grant execute on function public.cfo_add_portal_user(text,text,boolean,text,text[],text[]) to authenticated;

drop function if exists public.get_portal_users_admin();
create or replace function public.get_portal_users_admin()
returns table(
  email text,full_name text,role text,finance_team boolean,active boolean,activated boolean,
  profile_id uuid,dashboard_permissions text[],page_permissions text[]
)
language sql stable security definer set search_path=public,private,pg_temp as $$
select a.email,a.full_name,a.role,a.finance_team,a.active,(p.id is not null),p.id,
       a.dashboard_permissions,a.page_permissions
from public.allowed_users a
left join public.profiles p on lower(p.email)=lower(a.email)
where private.current_role()='CFO'
order by a.finance_team desc,a.full_name;
$$;
revoke all on function public.get_portal_users_admin() from public,anon;
grant execute on function public.get_portal_users_admin() to authenticated;

create or replace function private.handle_new_user()
returns trigger language plpgsql security definer set search_path=public,private,pg_temp as $$
declare
  a public.allowed_users%rowtype;
  v_dashboard_keys constant text[]:=array[
    'dashboard.liquidity','dashboard.reserves','dashboard.payments','dashboard.tasks',
    'dashboard.close','dashboard.exceptions','dashboard.team','dashboard.automation'
  ];
  v_all_page_keys constant text[]:=array[
    'page.dashboard','page.banks','page.payments','page.executed','page.posted','page.pending','page.tasks','page.workflow',
    'page.workcenter','page.control','page.workload','page.escalations','page.automation','page.close','page.imprest',
    'page.performance','page.ownership','page.exceptions','page.audit','page.permissions'
  ];
  k text;
  v_bank_data boolean;
begin
  select * into a from public.allowed_users where lower(email)=lower(new.email) and active=true;
  if not found then raise exception 'User email is not authorized for Sanam Finance Portal'; end if;

  insert into public.profiles(id,email,full_name,role,active,finance_team)
  values(new.id,lower(new.email),a.full_name,a.role,true,a.finance_team)
  on conflict(id) do update set email=excluded.email,full_name=excluded.full_name,role=excluded.role,
    active=true,finance_team=excluded.finance_team,updated_at=now();

  if not a.finance_team then
    foreach k in array v_all_page_keys loop
      insert into public.user_permissions(user_id,permission_key,allowed,updated_at)
      values(new.id,k,k=any(coalesce(a.page_permissions,array['page.dashboard']::text[])),now())
      on conflict(user_id,permission_key) do update set allowed=excluded.allowed,updated_at=now();
    end loop;
  end if;

  foreach k in array v_dashboard_keys loop
    insert into public.user_permissions(user_id,permission_key,allowed,updated_at)
    values(new.id,k,k=any(coalesce(a.dashboard_permissions,'{}'::text[])),now())
    on conflict(user_id,permission_key) do update set allowed=excluded.allowed,updated_at=now();
  end loop;

  if not a.finance_team then
    v_bank_data:=('page.banks'=any(coalesce(a.page_permissions,'{}'::text[]))
      or 'dashboard.liquidity'=any(coalesce(a.dashboard_permissions,'{}'::text[]))
      or 'dashboard.reserves'=any(coalesce(a.dashboard_permissions,'{}'::text[])));
    insert into public.user_permissions(user_id,permission_key,allowed,updated_at)
    values(new.id,'data.bank_balances',v_bank_data,now())
    on conflict(user_id,permission_key) do update set allowed=excluded.allowed,updated_at=now();
  end if;
  return new;
end $$;
revoke all on function private.handle_new_user() from public,anon,authenticated;

-- Restrict direct Viewer reads while preserving every existing finance-role policy path.
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select
using (private.current_role()<>'Viewer' or id=auth.uid());

drop policy if exists close_select on public.monthly_close_tasks;
create policy close_select on public.monthly_close_tasks for select
using (private.current_role()<>'Viewer' or public.has_user_permission('page.close'));

drop policy if exists imprest_select on public.imprest_funds;
create policy imprest_select on public.imprest_funds for select
using (private.current_role()<>'Viewer' or public.has_user_permission('page.imprest'));

drop policy if exists ownership_select on public.ownership_matrix;
create policy ownership_select on public.ownership_matrix for select
using (private.current_role()<>'Viewer' or public.has_user_permission('page.ownership'));

drop policy if exists exceptions_read on public.exceptions;
create policy exceptions_read on public.exceptions for select
using (private.current_role()<>'Viewer' or public.has_user_permission('page.exceptions'));

drop policy if exists finance_policies_read on public.finance_policies;
create policy finance_policies_read on public.finance_policies for select
using (
  exists(select 1 from public.profiles p where p.id=auth.uid() and p.active=true)
  and (status<>'Draft' or private.current_role()='CFO')
  and (private.current_role()<>'Viewer' or public.has_user_permission('page.exceptions'))
);

create or replace function public.get_bank_account_directory()
returns table(id uuid,company text,bank_name text,account_name text,account_no_last4 text,account_type text)
language sql stable security definer set search_path=public,private,pg_temp as $$
select b.id,b.company,b.bank_name,b.account_name,
       case when coalesce(b.account_no,'')='' then null else right(regexp_replace(b.account_no,'\s+','','g'),4) end,
       b.account_type
from public.bank_accounts b
where private.current_role()<>'Viewer'
   or public.has_user_permission('page.banks')
   or public.has_user_permission('page.payments')
   or public.has_user_permission('page.executed')
   or public.has_user_permission('page.posted')
   or public.has_user_permission('page.pending')
order by b.company,b.bank_name,b.account_name;
$$;

create or replace function public.get_imprest_fund_summary()
returns table(imprest_fund_id uuid,under_settlement numeric,approved_settlements numeric,available_to_settle numeric)
language sql stable security definer set search_path=public,private,pg_temp as $$
select f.id,
       coalesce(sum(s.amount) filter(where s.status in ('In Progress','Pending Review','Returned for Rework')),0)::numeric,
       coalesce(sum(s.amount) filter(where s.status='Approved'),0)::numeric,
       greatest(coalesce(f.unsettled,0)-coalesce(sum(s.amount) filter(where s.status in ('In Progress','Pending Review','Returned for Rework')),0),0)::numeric
from public.imprest_funds f
left join public.imprest_settlements s on s.imprest_fund_id=f.id
where exists(select 1 from public.profiles p where p.id=auth.uid() and p.active=true)
  and (private.current_role()<>'Viewer' or public.has_user_permission('page.imprest'))
group by f.id,f.unsettled;
$$;

create or replace function public.get_imprest_settlement_register()
returns table(
  settlement_id uuid,imprest_fund_id uuid,imprest_name text,company text,custodian_name text,
  handler_id uuid,handler_name text,amount numeric,invoice_count integer,received_at timestamptz,
  settlement_status text,task_id uuid,task_status text,due_date date,due_time time,
  submitted_at timestamptz,reviewed_at timestamptz,reviewer_name text,review_note text,notes text
)
language sql stable security definer set search_path=public,private,pg_temp as $$
select s.id,f.id,f.name,f.company,c.full_name,s.handler_id,h.full_name,s.amount,s.invoice_count,s.received_at,
       s.status,t.id,t.status,t.due_date,t.due_time,s.submitted_at,s.reviewed_at,r.full_name,s.review_note,s.notes
from public.imprest_settlements s
join public.imprest_funds f on f.id=s.imprest_fund_id
left join public.tasks t on t.id=s.task_id
left join public.profiles h on h.id=s.handler_id
left join public.profiles c on c.id=f.custodian_id
left join public.profiles r on r.id=s.reviewed_by
where exists(select 1 from public.profiles p where p.id=auth.uid() and p.active=true)
  and (private.current_role()<>'Viewer' or public.has_user_permission('page.imprest'))
order by s.created_at desc;
$$;

create or replace function public.get_finance_policy_register()
returns table(
  id uuid,policy_code text,title text,category text,purpose text,scope text,policy_text text,procedures text,
  responsibilities text,exceptions_text text,effective_date date,status text,current_version integer,
  created_at timestamptz,updated_at timestamptz,acknowledged_current boolean,acknowledged_count bigint,active_team_count bigint
)
language sql stable security definer set search_path=public,private,pg_temp as $$
with team as (select count(*)::bigint c from public.profiles where active=true and finance_team=true),
acks as (
 select a.policy_id,a.version_no,count(distinct a.user_id)::bigint c
 from public.finance_policy_acknowledgements a
 join public.profiles p on p.id=a.user_id and p.active=true and p.finance_team=true
 group by a.policy_id,a.version_no
)
select p.id,p.policy_code,p.title,p.category,p.purpose,p.scope,p.policy_text,p.procedures,p.responsibilities,
       p.exceptions_text,p.effective_date,p.status,p.current_version,p.created_at,p.updated_at,
       exists(select 1 from public.finance_policy_acknowledgements a
              where a.policy_id=p.id and a.user_id=auth.uid() and a.version_no=p.current_version),
       coalesce(a.c,0),team.c
from public.finance_policies p
left join acks a on a.policy_id=p.id and a.version_no=p.current_version
cross join team
where private.current_role() is not null
  and (p.status<>'Draft' or private.current_role()='CFO')
  and (private.current_role()<>'Viewer' or public.has_user_permission('page.exceptions'))
order by case p.status when 'Active' then 1 when 'Draft' then 2 when 'Suspended' then 3 else 4 end,p.category,p.policy_code;
$$;

create or replace function public.get_readonly_page_snapshot(p_page text)
returns jsonb language plpgsql stable security definer
set search_path=public,private,cron,pg_temp as $$
declare
  v_key text:='page.'||coalesce(p_page,'');
  v_result jsonb:='{}'::jsonb;
begin
  if private.current_role()<>'Viewer' then raise exception 'READ_ONLY_VIEWER_REQUIRED'; end if;
  if not (v_key=any(private.viewer_page_keys())) then raise exception 'READ_ONLY_PAGE_NOT_SUPPORTED'; end if;
  if not public.has_user_permission(v_key) then raise exception 'READ_ONLY_PAGE_NOT_AUTHORIZED'; end if;

  if p_page='banks' then
    select jsonb_build_object(
      'banks',coalesce((select jsonb_agg(to_jsonb(x) order by x.company,x.bank_name,x.account_name) from public.get_visible_bank_liquidity() x),'[]'::jsonb),
      'reserves',coalesce((select jsonb_agg(to_jsonb(x) order by x.company,x.bank_name) from public.get_reserve_account_monitor() x),'[]'::jsonb)
    ) into v_result;

  elsif p_page in ('payments','executed','posted','pending') then
    with rows as (
      select to_jsonb(p) || jsonb_build_object(
        'bank_accounts',case when b.id is null then null else jsonb_build_object(
          'id',b.id,'company',b.company,'bank_name',b.bank_name,'account_name',b.account_name,
          'account_type',b.account_type,'account_no',case when coalesce(b.account_no,'')='' then null else right(regexp_replace(b.account_no,'\s+','','g'),4) end
        ) end
      ) row_data
      from public.payments p
      left join public.bank_accounts b on b.id=p.bank_account_id
      where case p_page
        when 'payments' then (p.executed_at is null and p.posted_at is null and p.status<>'معلقة' and p.status<>'مرحّل')
        when 'executed' then (p.executed_at is not null and p.posted_at is null and p.status<>'معلقة')
        when 'posted' then (p.posted_at is not null or p.status='مرحّل')
        when 'pending' then (p.status='معلقة')
        else false end
    )
    select jsonb_build_object(
      'payments',coalesce((select jsonb_agg(row_data) from rows),'[]'::jsonb),
      'profiles',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'full_name',p.full_name,'role',p.role))
                           from public.profiles p where p.active=true and p.finance_team=true),'[]'::jsonb)
    ) into v_result;

  elsif p_page='close' then
    select jsonb_build_object('close_tasks',
      coalesce(jsonb_agg(to_jsonb(m) || jsonb_build_object(
        'owner',case when p.id is null then null else jsonb_build_object('full_name',p.full_name) end
      ) order by m.due_date,m.code),'[]'::jsonb))
    into v_result
    from public.monthly_close_tasks m
    left join public.profiles p on p.id=m.owner_id;

  elsif p_page='imprest' then
    select jsonb_build_object(
      'imprest',coalesce((
        select jsonb_agg(to_jsonb(f) || jsonb_build_object(
          'custodian',case when c.id is null then null else jsonb_build_object('full_name',c.full_name) end
        ) order by f.created_at desc)
        from public.imprest_funds f left join public.profiles c on c.id=f.custodian_id
      ),'[]'::jsonb),
      'settlements',coalesce((select jsonb_agg(to_jsonb(x)) from public.get_imprest_settlement_register() x),'[]'::jsonb),
      'summary',coalesce((select jsonb_agg(to_jsonb(x)) from public.get_imprest_fund_summary() x),'[]'::jsonb)
    ) into v_result;

  elsif p_page='performance' then
    with ctx as (
      select (now() at time zone 'Asia/Riyadh')::date today,
             date_trunc('month',now() at time zone 'Asia/Riyadh')::date month_start,
             coalesce((select trim(both '"' from setting_value::text)::date from public.finance_settings where setting_key='daily_plan_go_live_date'),'2026-09-17'::date) go_live
    ),
    people as (
      select p.id,p.full_name,p.role from public.profiles p
      where p.active=true and p.finance_team=true and p.role in ('Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
    ),
    task_stats as (
      select pe.id,
        count(t.id) filter(where t.due_date=c.today and t.due_date>=c.go_live)::int today_total,
        count(t.id) filter(where t.due_date=c.today and t.due_date>=c.go_live and t.status='مكتمل')::int today_completed,
        count(t.id) filter(where t.due_date>=c.go_live and t.status not in ('مكتمل','بانتظار المراجعة') and private.task_deadline(t.due_date,t.due_time)<now())::int today_overdue,
        count(t.id) filter(where t.due_date>=c.go_live and t.status not in ('مكتمل','بانتظار المراجعة') and ((private.task_deadline(t.due_date,t.due_time)<now()) or t.justification_requested_at is not null) and nullif(trim(coalesce(t.delay_justification,'')),'') is null)::int pending_justifications,
        count(t.id) filter(where t.due_date>=c.go_live and t.status='بانتظار المراجعة')::int pending_review,
        count(t.id) filter(where t.due_date between greatest(c.month_start,c.go_live) and c.today)::int month_total,
        count(t.id) filter(where t.due_date between greatest(c.month_start,c.go_live) and c.today and t.status='مكتمل')::int month_completed,
        count(t.id) filter(where t.due_date between greatest(c.month_start,c.go_live) and c.today and t.status='مكتمل' and t.review_requested_at is not null)::int tracked_completed,
        count(t.id) filter(where t.due_date between greatest(c.month_start,c.go_live) and c.today and t.status='مكتمل' and t.review_requested_at is not null and t.review_requested_at<=private.task_deadline(t.due_date,t.due_time))::int tracked_on_time
      from people pe cross join ctx c left join public.tasks t on t.owner_id=pe.id group by pe.id
    ),
    close_stats as (
      select pe.id,count(m.id)::int close_total,
             count(m.id) filter(where m.status='مكتمل' or coalesce(m.progress,0)>=100)::int close_completed
      from people pe cross join ctx c
      left join public.monthly_close_tasks m on m.owner_id=pe.id and m.close_period=c.month_start
      group by pe.id
    ),
    activity_stats as (
      select pe.id,count(a.id) filter(where a.activity_date=c.today)::int today_ops,
             count(a.id) filter(where a.activity_date between c.month_start and c.today)::int month_ops
      from people pe cross join ctx c
      left join public.finance_activity_log a on a.employee_id=pe.id group by pe.id
    ),
    sla as (
      select pe.id,case when pe.role='GLAccountant' then
        count(p.id) filter(where p.executed_at is not null and p.posted_at is null and p.status in ('منفذ','تم التسجيل') and now()>p.executed_at+interval '48 hours')::int
        else 0 end overdue
      from people pe left join public.payments p on pe.role='GLAccountant'
      group by pe.id,pe.role
    ),
    result as (
      select pe.id user_id,pe.full_name,pe.role,
        coalesce(ts.today_total,0) today_total,coalesce(ts.today_completed,0) today_completed,
        coalesce(ts.today_overdue,0) today_overdue,coalesce(ts.pending_justifications,0) pending_justifications,
        coalesce(ts.pending_review,0) pending_review,coalesce(ts.month_total,0) month_total,
        coalesce(ts.month_completed,0) month_completed,
        case when coalesce(ts.month_total,0)=0 then 0 else round(ts.month_completed*100.0/ts.month_total,1) end month_completion_rate,
        case when coalesce(ts.tracked_completed,0)=0 then 0 else round(ts.tracked_on_time*100.0/ts.tracked_completed,1) end tracked_on_time_rate,
        coalesce(cs.close_total,0) close_total,coalesce(cs.close_completed,0) close_completed,
        case when coalesce(cs.close_total,0)=0 then 0 else round(cs.close_completed*100.0/cs.close_total,1) end close_completion_rate,
        coalesce(ac.today_ops,0) today_operational_activities,coalesce(ac.month_ops,0) month_operational_activities,
        coalesce(sl.overdue,0) payment_sla_overdue
      from people pe
      left join task_stats ts on ts.id=pe.id left join close_stats cs on cs.id=pe.id
      left join activity_stats ac on ac.id=pe.id left join sla sl on sl.id=pe.id
    )
    select jsonb_build_object('performance',coalesce(jsonb_agg(to_jsonb(result) order by full_name),'[]'::jsonb))
    into v_result from result;

  elsif p_page='ownership' then
    select jsonb_build_object('ownership',coalesce(jsonb_agg(to_jsonb(o) order by o.sort_order),'[]'::jsonb))
    into v_result from public.ownership_matrix o;

  elsif p_page='exceptions' then
    select jsonb_build_object(
      'exceptions',coalesce((
        select jsonb_agg(to_jsonb(e) || jsonb_build_object(
          'leave_delegations',case when ld.id is null then null else
            to_jsonb(ld) || jsonb_build_object(
              'absent',jsonb_build_object('full_name',pa.full_name),
              'substitute',jsonb_build_object('full_name',ps.full_name)
            ) end
        ) order by e.created_at desc)
        from public.exceptions e
        left join public.leave_delegations ld on ld.id=e.leave_delegation_id
        left join public.profiles pa on pa.id=ld.absent_user_id
        left join public.profiles ps on ps.id=ld.substitute_user_id
      ),'[]'::jsonb),
      'policies',coalesce((select jsonb_agg(to_jsonb(x)) from public.get_finance_policy_register() x),'[]'::jsonb)
    ) into v_result;

  elsif p_page='automation' then
    with jobs as (
      select j.jobid,j.jobname,j.active,j.schedule
      from cron.job j
      where j.jobname in ('sanam_generate_daily_tasks','sanam_generate_monthly_close_tasks','sanam_task_v2_deadline_monitor')
    ), latest as (
      select j.*,r.start_time,r.status,r.return_message
      from jobs j left join lateral(
        select d.start_time,d.status,d.return_message
        from cron.job_run_details d where d.jobid=j.jobid order by d.start_time desc limit 1
      ) r on true
    )
    select jsonb_build_object('automation',coalesce(jsonb_agg(jsonb_build_object(
      'system_name',case jobname when 'sanam_generate_daily_tasks' then 'تجديد المهام اليومية'
        when 'sanam_generate_monthly_close_tasks' then 'تجديد الإقفال الشهري'
        else 'مراقبة مواعيد المهام والتنبيهات' end,
      'job_name',jobname,'active',active,'schedule',schedule,'last_run_at',start_time,
      'last_status',status,'next_run_at',null,'missing_count',0,'detail',coalesce(return_message,'—')
    ) order by jobname),'[]'::jsonb))
    into v_result from latest;

  elsif p_page='audit' then
    select jsonb_build_object('audit',coalesce(jsonb_agg(jsonb_build_object(
      'created_at',a.created_at,
      'actor',jsonb_build_object('full_name',coalesce(p.full_name,p.email,'—')),
      'action',a.action,'entity_type',a.entity_type,'entity_id',a.entity_id
    ) order by a.created_at desc),'[]'::jsonb))
    into v_result
    from (select * from public.audit_log order by created_at desc limit 200) a
    left join public.profiles p on p.id=a.actor_id;
  else
    raise exception 'READ_ONLY_PAGE_NOT_SUPPORTED';
  end if;

  return coalesce(v_result,'{}'::jsonb);
end $$;
revoke all on function public.get_readonly_page_snapshot(text) from public,anon;
grant execute on function public.get_readonly_page_snapshot(text) to authenticated;

create or replace function public.get_readonly_workcenter_dashboard_v1(p_filters jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer
set search_path=public,private,pg_temp as $$
declare
  c private.workcenter_cycles%rowtype;
  items jsonb;
  people jsonb;
  stats jsonb;
  date_from date;
  date_to date;
begin
  if private.current_role()<>'Viewer' or not public.has_user_permission('page.workcenter') then
    raise exception 'READ_ONLY_WORKCENTER_NOT_AUTHORIZED';
  end if;

  select * into c from private.workcenter_cycles where active;
  if not found then
    return jsonb_build_object('cycle',null,'items','[]'::jsonb,'team','[]'::jsonb,'summary','{}'::jsonb);
  end if;

  date_from:=coalesce(nullif(p_filters->>'from','')::date,(c.started_at at time zone 'Asia/Riyadh')::date);
  date_to:=coalesce(nullif(p_filters->>'to','')::date,(now() at time zone 'Asia/Riyadh')::date);
  if date_from>date_to then raise exception 'INVALID_DATE_RANGE'; end if;

  with base as (
    select w.*,m.entered_at,pa.full_name assignee_name,pr.full_name reviewer_name,
      case when w.status='Completed' then w.completed_by else w.assignee_id end owner_id,
      coalesce(t.assigned_at,m.entered_at) assigned_at,t.result_description,t.quality_score,t.rework_count,
      t.blocker_note,t.review_requested_at,t.original_due_date,t.original_due_time,t.output task_description,
      t.source_entity_type task_source_type,
      w.status='Completed' is_completed,
      (w.status in ('Pending Review','Extension Requested')
        or (w.item_type in ('PAYMENT_SUPERVISOR_APPROVAL','PAYMENT_CFO_APPROVAL') and w.status in ('Ready','Assigned'))) is_review,
      (w.due_at<now() and w.status not in ('Completed','Closed','Cancelled','Waiting')) is_overdue
    from private.workcenter_cycle_items m
    join public.work_items w on w.id=m.work_item_id
    left join public.tasks t on w.source_entity_type='task' and t.id::text=w.source_entity_id
    left join public.profiles pa on pa.id=w.assignee_id
    left join public.profiles pr on pr.id=w.reviewer_id
    where m.cycle_id=c.id and w.performance_credit and w.status not in ('Waiting','Cancelled','Closed')
      and (nullif(p_filters->>'item_type','') is null or w.item_type=p_filters->>'item_type')
      and (nullif(p_filters->>'priority','') is null or w.priority=p_filters->>'priority')
      and (nullif(p_filters->>'search','') is null or w.title ilike '%'||(p_filters->>'search')||'%')
      and (w.status<>'Completed' or (w.completed_at at time zone 'Asia/Riyadh')::date between date_from and date_to)
  ), classified as (
    select b.*,
      case when is_completed then 'completed' when is_review then 'reviews'
           when status in ('Blocked','Paused','Returned for Rework') then 'attention' else 'execution' end bucket,
      coalesce(is_overdue,false) or status in ('Blocked','Paused','Returned for Rework') is_attention,
      case when is_completed and due_at is not null then coalesce(review_requested_at,completed_at)<=due_at else null end on_time
    from base b
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'work_item_id',id,'source_type',source_entity_type,'source_id',source_entity_id,'item_type',item_type,
    'title',title,'assignee_id',assignee_id,'owner_id',owner_id,'assignee_name',assignee_name,
    'reviewer_id',reviewer_id,'reviewer_name',reviewer_name,'status',status,'priority',priority,'bucket',bucket,
    'is_overdue',coalesce(is_overdue,false),'is_attention',is_attention,'is_review',is_review,
    'requires_my_decision',false,'assigned_at',assigned_at,'entered_at',entered_at,'due_at',due_at,
    'started_at',started_at,'completed_at',completed_at,'completed_by',completed_by,'quality_score',quality_score,
    'on_time',on_time,'rework_count',coalesce(rework_count,0),'result_description',result_description,
    'blocker_note',blocker_note,'task_description',task_description,'task_source_type',task_source_type,
    'available_actions','[]'::jsonb,
    'remaining_minutes',case when due_at is null or is_completed then null else floor(extract(epoch from (due_at-now()))/60) end
  ) order by is_attention desc,due_at nulls last,entered_at),'[]'::jsonb)
  into items from classified;

  select jsonb_build_object(
    'total',count(*),
    'execution',count(*) filter(where x->>'bucket'='execution'),
    'reviews',count(*) filter(where (x->>'is_review')::boolean),
    'attention',count(*) filter(where (x->>'is_attention')::boolean),
    'completed',count(*) filter(where x->>'bucket'='completed'),
    'ready',count(*) filter(where x->>'status' in ('Ready','Assigned') and x->>'bucket'='execution'),
    'in_progress',count(*) filter(where x->>'status' in ('Started','In Progress') and x->>'bucket'='execution'),
    'overdue',count(*) filter(where (x->>'is_overdue')::boolean),
    'my_decisions',0
  ) into stats
  from jsonb_array_elements(items) x;

  select coalesce(jsonb_agg(z order by z->>'full_name'),'[]'::jsonb) into people
  from (
    select jsonb_build_object(
      'user_id',p.id,'full_name',p.full_name,'role',p.role,
      'ready',count(x) filter(where x->>'bucket'='execution' and x->>'status' in ('Assigned','Ready')),
      'in_progress',count(x) filter(where x->>'bucket'='execution' and x->>'status' in ('Started','In Progress')),
      'reviews',count(x) filter(where (x->>'is_review')::boolean),
      'attention',count(x) filter(where (x->>'is_attention')::boolean),
      'overdue',count(x) filter(where (x->>'is_overdue')::boolean),
      'completed',count(x) filter(where x->>'bucket'='completed'),
      'total',count(x),
      'quality_avg',round(avg((x->>'quality_score')::numeric) filter(where x->>'bucket'='completed'),1),
      'quality_count',count(x->>'quality_score') filter(where x->>'bucket'='completed'),
      'on_time_count',count(x) filter(where (x->>'on_time')::boolean),
      'timed_count',count(x->>'on_time'),
      'on_time_rate',round(100.0*count(x) filter(where (x->>'on_time')::boolean)/nullif(count(x->>'on_time'),0),1)
    ) z
    from public.profiles p
    left join jsonb_array_elements(items) x on x->>'owner_id'=p.id::text
    where p.active and p.finance_team=true
      and p.role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
    group by p.id,p.full_name,p.role
  ) q;

  return jsonb_build_object(
    'cycle',jsonb_build_object('id',c.id,'label',c.label,'started_at',c.started_at),
    'as_of',now(),'from',date_from,'to',date_to,'scope','team',
    'items',items,'summary',stats,'team',people
  );
end $$;
revoke all on function public.get_readonly_workcenter_dashboard_v1(jsonb) from public,anon;
grant execute on function public.get_readonly_workcenter_dashboard_v1(jsonb) to authenticated;
