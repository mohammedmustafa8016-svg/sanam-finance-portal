-- Eligible 24-hour days in Riyadh; Friday/Saturday excluded. Holds never pause either phase.
create or replace function private.payment_sla_seconds(p_start timestamptz,p_end timestamptz)
returns numeric language plpgsql immutable strict set search_path=pg_catalog as $$
declare a timestamp:=least(p_start,p_end) at time zone 'Asia/Riyadh'; b timestamp:=greatest(p_start,p_end) at time zone 'Asia/Riyadh'; d date; total numeric:=0;
begin
 d:=a::date;
 while d<=b::date loop
  if extract(isodow from d) not in (5,6) then total:=total+greatest(extract(epoch from least(b,(d+1)::timestamp)-greatest(a,d::timestamp)),0);end if;
  d:=d+1;
 end loop;
 return case when p_end<p_start then -total else total end;
end$$;
create or replace function private.payment_sla_deadline(p_start timestamptz)
returns timestamptz language plpgsql immutable strict set search_path=pg_catalog as $$
declare cursor_local timestamp:=p_start at time zone 'Asia/Riyadh'; remaining_seconds numeric:=172800; available_seconds numeric;
begin
 while remaining_seconds>0 loop
  if extract(isodow from cursor_local) in (5,6) then cursor_local:=(cursor_local::date+1)::timestamp;continue;end if;
  available_seconds:=extract(epoch from ((cursor_local::date+1)::timestamp-cursor_local));
  if remaining_seconds<=available_seconds then
   cursor_local:=cursor_local+remaining_seconds*interval '1 second';
   while extract(isodow from cursor_local) in (5,6) loop cursor_local:=(cursor_local::date+1)::timestamp;end loop;
   return cursor_local at time zone 'Asia/Riyadh';
  end if;
  remaining_seconds:=remaining_seconds-available_seconds;cursor_local:=(cursor_local::date+1)::timestamp;
 end loop;
 return cursor_local at time zone 'Asia/Riyadh';
end$$;
revoke all on function private.payment_sla_seconds(timestamptz,timestamptz),private.payment_sla_deadline(timestamptz) from public,anon;
CREATE OR REPLACE FUNCTION private.ensure_payment_workflow_v3(p_payment_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
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
    case when p.executed_at is null then null else private.payment_sla_deadline(p.executed_at) end,
    null,p.accounting_registered_at,p.accounting_registered_by,
    jsonb_build_object('pending_type',p.pending_type,'pending_amount',p.pending_amount)
  );
  v_item:=private.upsert_work_item(
    v_instance,v_step,'PAYMENT_ACCOUNTING_REGISTRATION','payment',p.id::text,v_title||' — تسجيل محاسبي',
    'GLAccountant',v_gl,v_sup,v_status,p.priority,
    case when p.executed_at is null then null else private.payment_sla_deadline(p.executed_at) end,
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
    private.payment_sla_deadline(p.accounting_registered_at),null,p.posted_at,p.posted_by,
    jsonb_build_object('pending_type',p.pending_type,'pending_amount',p.pending_amount)
  );
  v_item:=private.upsert_work_item(
    v_instance,v_step,'PAYMENT_POSTING_FINALIZATION','payment',p.id::text,v_title||' — ترحيل وإقفال',
    'Supervisor',v_sup,v_cfo,v_status,p.priority,private.payment_sla_deadline(p.accounting_registered_at),null,p.posted_at,p.posted_by,true,1,
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
$function$

CREATE OR REPLACE FUNCTION public.get_finance_team_performance()
 RETURNS TABLE(user_id uuid, full_name text, role text, today_total integer, today_completed integer, today_overdue integer, pending_justifications integer, pending_review integer, month_total integer, month_completed integer, month_completion_rate numeric, tracked_on_time_rate numeric, close_total integer, close_completed integer, close_completion_rate numeric, today_operational_activities integer, month_operational_activities integer, payment_sla_overdue integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
with ctx as(
  select
    (now() at time zone 'Asia/Riyadh')::date today,
    date_trunc('month',now() at time zone 'Asia/Riyadh')::date month_start,
    private.current_role() current_role,
    auth.uid() current_uid,
    (select max(close_period) from public.monthly_close_tasks) active_close_period
),
people as(
  select p.id,p.full_name,p.role
  from public.profiles p,ctx c
  where p.active=true
    and p.role in ('Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
    and (c.current_role in ('CFO','Supervisor') or p.id=c.current_uid)
),
work_stats as(
  select
    pe.id,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status<>'Waiting'
        and (
          w.status in ('Assigned','Ready','Started','In Progress','Paused','Blocked','Extension Requested','Returned for Rework','Pending Review')
          or (w.status='Completed' and (w.completed_at at time zone 'Asia/Riyadh')::date=c.today)
        )
    )::int today_total,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status='Completed'
        and (w.completed_at at time zone 'Asia/Riyadh')::date=c.today
    )::int today_completed,
    count(w.id) filter(
      where w.performance_credit=true
        and private.task_effective_due_at(w.due_at)<now()
        and w.status not in ('Completed','Closed','Cancelled','Waiting')
    )::int today_overdue,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status='Pending Review'
    )::int pending_review,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status<>'Waiting'
        and (
          (w.created_at at time zone 'Asia/Riyadh')::date between c.month_start and c.today
          or (w.completed_at at time zone 'Asia/Riyadh')::date between c.month_start and c.today
        )
    )::int month_total,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status='Completed'
        and (w.completed_at at time zone 'Asia/Riyadh')::date between c.month_start and c.today
    )::int month_completed,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status='Completed'
        and w.due_at is not null
        and (w.completed_at at time zone 'Asia/Riyadh')::date between c.month_start and c.today
    )::int tracked_completed,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status='Completed'
        and w.due_at is not null
        and w.completed_at<=private.task_effective_due_at(w.due_at)
        and (w.completed_at at time zone 'Asia/Riyadh')::date between c.month_start and c.today
    )::int tracked_on_time,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status='Completed'
        and w.item_type<>'MANUAL_TASK'
        and (w.completed_at at time zone 'Asia/Riyadh')::date=c.today
    )::int today_ops,
    count(w.id) filter(
      where w.performance_credit=true
        and w.status='Completed'
        and w.item_type<>'MANUAL_TASK'
        and (w.completed_at at time zone 'Asia/Riyadh')::date between c.month_start and c.today
    )::int month_ops
  from people pe
  cross join ctx c
  left join public.work_items w on w.assignee_id=pe.id
  group by pe.id
),
just_stats as(
  select
    pe.id,
    count(t.id) filter(
      where t.status not in ('مكتمل','بانتظار المراجعة')
        and (
          private.task_deadline(t.due_date,t.due_time)<now()
          or t.justification_requested_at is not null
        )
        and nullif(trim(coalesce(t.delay_justification,'')),'') is null
    )::int pending_justifications
  from people pe
  left join public.tasks t on t.owner_id=pe.id
  group by pe.id
),
close_stats as(
  select
    pe.id,
    count(m.id)::int close_total,
    count(m.id) filter(where m.status='مكتمل' or coalesce(m.progress,0)>=100)::int close_completed
  from people pe
  cross join ctx c
  left join public.monthly_close_tasks m
    on m.owner_id=pe.id
   and m.close_period=c.active_close_period
  group by pe.id
),
sla as(
  select
    pe.id,
    case when pe.role in ('GLAccountant','Supervisor') then
      count(p.id) filter(
        where p.executed_at is not null
          and p.posted_at is null
          and p.status in ('منفذ','تم التسجيل','معلقة')
          and now()>private.payment_sla_deadline(coalesce(p.accounting_registered_at,p.executed_at))
      )::int
    else 0 end overdue
  from people pe
  left join public.payments p on (pe.role='GLAccountant' and p.accounting_registered_at is null) or (pe.role='Supervisor' and p.accounting_registered_at is not null)
  group by pe.id,pe.role
)
select
  pe.id,
  pe.full_name,
  pe.role,
  coalesce(ws.today_total,0),
  coalesce(ws.today_completed,0),
  coalesce(ws.today_overdue,0),
  coalesce(js.pending_justifications,0),
  coalesce(ws.pending_review,0),
  coalesce(ws.month_total,0),
  coalesce(ws.month_completed,0),
  case when coalesce(ws.month_total,0)=0 then 0
       else round(ws.month_completed*100.0/ws.month_total,1) end,
  case when coalesce(ws.tracked_completed,0)=0 then 0
       else round(ws.tracked_on_time*100.0/ws.tracked_completed,1) end,
  coalesce(cs.close_total,0),
  coalesce(cs.close_completed,0),
  case when coalesce(cs.close_total,0)=0 then 0
       else round(cs.close_completed*100.0/cs.close_total,1) end,
  coalesce(ws.today_ops,0),
  coalesce(ws.month_ops,0),
  coalesce(sl.overdue,0)
from people pe
left join work_stats ws on ws.id=pe.id
left join just_stats js on js.id=pe.id
left join close_stats cs on cs.id=pe.id
left join sla sl on sl.id=pe.id
order by case pe.role
  when 'Supervisor' then 1
  when 'BankAccountant' then 2
  when 'GLAccountant' then 3
  when 'ARAccountant' then 4
  when 'APAccountant' then 5
  else 9 end,pe.full_name;
$function$

CREATE OR REPLACE FUNCTION public.get_readonly_page_snapshot(p_page text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'cron', 'pg_temp'
AS $function$
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
        count(t.id) filter(where private.task_effective_due_date(t.due_date)=c.today and t.due_date>=c.go_live)::int today_total,
        count(t.id) filter(where private.task_effective_due_date(t.due_date)=c.today and t.due_date>=c.go_live and t.status='مكتمل')::int today_completed,
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
        count(p.id) filter(where p.executed_at is not null and p.posted_at is null and p.status in ('منفذ','تم التسجيل') and now()>private.payment_sla_deadline(coalesce(p.accounting_registered_at,p.executed_at)))::int
        else 0 end overdue
      from people pe left join public.payments p on (pe.role='GLAccountant' and p.accounting_registered_at is null) or (pe.role='Supervisor' and p.accounting_registered_at is not null)
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
end $function$

create or replace function public.get_payment_accounting_queue()
returns table(payment_id uuid,company text,beneficiary text,amount numeric,status text,executed_at timestamptz,accounting_registered_at timestamptz,deadline_at timestamptz,hours_elapsed numeric,hours_remaining numeric,sla_status text,purpose text,bank_account_id uuid)
language sql stable security definer set search_path=public,private,pg_temp as $$
select p.id,p.company,p.beneficiary,p.amount,p.status,p.executed_at,p.accounting_registered_at,private.payment_sla_deadline(coalesce(p.accounting_registered_at,p.executed_at)),
round(private.payment_sla_seconds(coalesce(p.accounting_registered_at,p.executed_at),now())/3600,1),
round(48-private.payment_sla_seconds(coalesce(p.accounting_registered_at,p.executed_at),now())/3600,1),
case when private.payment_sla_seconds(coalesce(p.accounting_registered_at,p.executed_at),now())>172800 then 'Overdue'
when private.payment_sla_seconds(coalesce(p.accounting_registered_at,p.executed_at),now())>=129600 then 'Due Soon' else 'Within SLA' end,p.purpose,p.bank_account_id
from public.payments p where private.current_role() in ('CFO','Supervisor','GLAccountant') and p.executed_at is not null and p.posted_at is null and p.status in ('منفذ','تم التسجيل','معلقة') order by p.executed_at;
$$;
CREATE OR REPLACE FUNCTION private.capture_payment_activity()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare v_role text;
begin
 if tg_op='INSERT' then
   select role into v_role from public.profiles where id=new.requested_by;
   if v_role='BankAccountant' then perform private.log_employee_activity(new.requested_by,'PAYMENT_CREATED','payment',new.id::text,'PAYMENT_CREATED:'||new.id::text,null,jsonb_build_object('amount',new.amount,'beneficiary',new.beneficiary),coalesce(new.created_at,now())); end if;
   return new;
 end if;
 if old.executed_at is null and new.executed_at is not null then
   select role into v_role from public.profiles where id=new.executed_by;
   if v_role='BankAccountant' then perform private.log_employee_activity(new.executed_by,'PAYMENT_EXECUTED','payment',new.id::text,'PAYMENT_EXECUTED:'||new.id::text,'Within SLA',jsonb_build_object('amount',new.amount,'beneficiary',new.beneficiary),new.executed_at); end if;
 end if;
 if old.accounting_registered_at is null and new.accounting_registered_at is not null then
   select role into v_role from public.profiles where id=new.accounting_registered_by;
   if v_role='GLAccountant' then perform private.log_employee_activity(new.accounting_registered_by,'PAYMENT_ACCOUNTING_REGISTERED','payment',new.id::text,'PAYMENT_ACCOUNTING_REGISTERED:'||new.id::text,case when new.executed_at is not null and new.accounting_registered_at>private.payment_sla_deadline(new.executed_at) then 'Overdue' else 'Within SLA' end,jsonb_build_object('amount',new.amount,'beneficiary',new.beneficiary),new.accounting_registered_at); end if;
 end if;
 if old.status is distinct from new.status and new.status='مرحّل' then
   select role into v_role from public.profiles where id=new.posted_by;
   if v_role='GLAccountant' then perform private.log_employee_activity(new.posted_by,'PAYMENT_POSTED','payment',new.id::text,'PAYMENT_POSTED:'||new.id::text,case when new.executed_at is not null and coalesce(new.posted_at,now())>private.payment_sla_deadline(new.accounting_registered_at) then 'Overdue' else 'Within SLA' end,jsonb_build_object('amount',new.amount,'beneficiary',new.beneficiary),coalesce(new.posted_at,now())); end if;
 end if;
 if old.status is distinct from new.status and new.status='معلقة' then
   select role into v_role from public.profiles where id=new.pending_by;
   if v_role='GLAccountant' then perform private.log_employee_activity(new.pending_by,'PAYMENT_MARKED_PENDING','payment',new.id::text,'PAYMENT_MARKED_PENDING:'||new.id::text,case when new.executed_at is not null and coalesce(new.pending_at,now())>private.payment_sla_deadline(coalesce(new.accounting_registered_at,new.executed_at)) then 'Overdue' else 'Within SLA' end,jsonb_build_object('reason',new.pending_reason,'required_action',new.pending_action),coalesce(new.pending_at,now())); end if;
 end if;
 return new;
end $function$

create or replace function public.mark_task_notifications_read(p_notification_ids uuid[])
returns integer language plpgsql security definer set search_path=public,private,pg_temp as $$
declare changed integer;
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and active) then raise exception 'NOT_AUTHORIZED';end if;
 if coalesce(cardinality(p_notification_ids),0)>500 then raise exception 'NOTIFICATION_SELECTION_TOO_LARGE';end if;
 update public.task_notifications set read_at=now() where user_id=auth.uid() and id=any(p_notification_ids) and read_at is null;
 get diagnostics changed=row_count;
 return changed;
end$$;
revoke all on function public.mark_task_notifications_read(uuid[]) from public,anon;
grant execute on function public.mark_task_notifications_read(uuid[]) to authenticated;

-- Refresh workflow deadlines only. Original financial records and timestamps stay intact.
update public.work_items w set due_at=case when w.item_type='PAYMENT_ACCOUNTING_REGISTRATION' then private.payment_sla_deadline(p.executed_at) else private.payment_sla_deadline(p.accounting_registered_at) end
from public.payments p where w.source_entity_type='payment' and w.source_entity_id=p.id::text and w.item_type in ('PAYMENT_ACCOUNTING_REGISTRATION','PAYMENT_POSTING_FINALIZATION');
update public.workflow_steps s set due_at=case when s.step_key='ACCOUNTING_REGISTRATION' then private.payment_sla_deadline(p.executed_at) else private.payment_sla_deadline(p.accounting_registered_at) end
from public.workflow_instances i,public.payments p where s.workflow_instance_id=i.id and i.source_entity_type='payment' and i.source_entity_id=p.id::text and s.step_key in ('ACCOUNTING_REGISTRATION','POSTING_FINALIZATION');
