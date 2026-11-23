-- Additive access layer. Leave, profile, permission and transaction rows are not rewritten.
create function private.active_supervisor_delegations()
returns table(id uuid,absent_user_id uuid,substitute_user_id uuid,full_name text,date_from date,date_to date)
language sql stable security definer set search_path='' as $$
 select ld.id,ld.absent_user_id,ld.substitute_user_id,absent.full_name,ld.date_from,ld.date_to
 from public.leave_delegations ld
 join public.profiles absent on absent.id=ld.absent_user_id and absent.active and absent.role='Supervisor'
 join public.profiles substitute on substitute.id=ld.substitute_user_id and substitute.active
 where ld.substitute_user_id=auth.uid() and ld.absent_user_id<>auth.uid()
   and substitute.role in ('Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
   and ld.active
   and (now() at time zone 'Asia/Riyadh')::date between ld.date_from and ld.date_to
 order by ld.created_at desc,ld.id
$$;
revoke all on function private.active_supervisor_delegations() from public,anon,authenticated;

create function private.effective_supervisor_role()
returns text language sql stable security definer set search_path='' as $$
 select case when p.role not in ('CFO','Supervisor')
     and exists(select 1 from private.active_supervisor_delegations()) then 'Supervisor'
   else p.role end
 from public.profiles p where p.id=auth.uid() and p.active
$$;
revoke all on function private.effective_supervisor_role() from public,anon;
grant execute on function private.effective_supervisor_role() to authenticated;

create or replace function private.current_role()
returns text language sql stable security definer set search_path='' as $$
 select case when exists(
   select 1 from private.active_supervisor_delegations() d
   where d.id::text=current_setting('sanam.supervisor_delegation',true)
 ) then 'Supervisor' else p.role end
 from public.profiles p where p.id=auth.uid() and p.active
$$;

create or replace function private.is_supervisor_or_delegate()
returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(private.current_role()='Supervisor',false)
   or exists(select 1 from private.active_supervisor_delegations())
$$;

create or replace function public.has_user_permission(p_key text)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles p where p.id=auth.uid() and p.active)
 and (
   coalesce((select up.allowed from public.user_permissions up where up.user_id=auth.uid() and up.permission_key=p_key),
     private.default_permission_for_role((select role from public.profiles where id=auth.uid() and active),p_key),false)
   or exists(
    select 1 from private.active_supervisor_delegations() d
    where coalesce((select up.allowed from public.user_permissions up where up.user_id=d.absent_user_id and up.permission_key=p_key),
      private.default_permission_for_role('Supervisor',p_key),false)
      and coalesce(private.default_permission_for_role('Supervisor',p_key),false)
   )
 )
$$;

create function public.get_my_leave_delegation_context()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
   'user_id',auth.uid(),
   'roles',case when exists(select 1 from private.active_supervisor_delegations()) then jsonb_build_array('Supervisor') else '[]'::jsonb end,
   'delegations',coalesce((select jsonb_agg(to_jsonb(d)||jsonb_build_object(
      'expires_at',(d.date_to+1)::timestamp at time zone 'Asia/Riyadh'
    )) from private.active_supervisor_delegations() d),'[]'::jsonb),
   'functions',jsonb_build_array('get_supervisor_control_center','get_workload_capacity','get_escalation_center','get_workcenter_dashboard_v5','get_workcenter_detail_v5','get_workflow_timeline','get_payment_accounting_queue','get_finance_team_performance','get_finance_team_kpi_report','get_employee_performance_report_v4','get_adhoc_activities','get_visible_bank_liquidity','get_bank_account_directory','get_reserve_account_monitor','get_reserve_account_movement_report_v2','get_imprest_fund_summary','get_imprest_settlement_register','get_imprest_funding_overview','get_imprest_funding_requests','get_imprest_ledger_entries','get_recoverable_reserve_uses','get_task_thread','supervisor_approve_payment','approve_payment_supervisor','supervisor_finalize_registered_payment','create_finance_task_v2','create_finance_task_template','update_finance_task_v2','update_finance_task_management','reassign_finance_task','review_finance_task','review_finance_task_scored','request_task_justification','decide_task_extension','set_team_capacity','save_manual_daily_plan','save_flexible_daily_plan','save_enhanced_daily_plan','supervisor_open_daily_plan','approve_adhoc_activity','approve_all_adhoc_activities_today','delete_requested_payment','delete_bank_account','create_imprest_fund_v2','update_imprest_fund','delete_imprest_fund','request_imprest_funding','open_imprest_settlement_task','record_imprest_refund','update_unapproved_payment','resume_pending_payment','update_pending_payment_followup','mark_payment_pending','start_finance_task','submit_finance_task_result','add_task_comment','request_task_extension','mark_task_blocker','submit_task_justification','clear_task_blocker','try_perform_work_item_action_v5')
 )
$$;
revoke all on function public.get_my_leave_delegation_context() from public,anon;
grant execute on function public.get_my_leave_delegation_context() to authenticated;

create function public.perform_supervisor_delegated_rpc(p_function text,p_arguments jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 delegation record;
 target record;
 argument record;
 arguments_sql text:='';
 result jsonb;
 old_context text:=current_setting('sanam.supervisor_delegation',true);
 payment_id uuid;
 task_id uuid;
 work_item record;
begin
 if auth.uid() is null then raise exception 'AUTHENTICATION_REQUIRED';end if;
 select * into delegation from private.active_supervisor_delegations() limit 1;
 if not found then raise exception 'SUPERVISOR_DELEGATION_INACTIVE';end if;
 if p_function is null or p_function<>all(array['get_supervisor_control_center','get_workload_capacity','get_escalation_center','get_workcenter_dashboard_v5','get_workcenter_detail_v5','get_workflow_timeline','get_payment_accounting_queue','get_finance_team_performance','get_finance_team_kpi_report','get_employee_performance_report_v4','get_adhoc_activities','get_visible_bank_liquidity','get_bank_account_directory','get_reserve_account_monitor','get_reserve_account_movement_report_v2','get_imprest_fund_summary','get_imprest_settlement_register','get_imprest_funding_overview','get_imprest_funding_requests','get_imprest_ledger_entries','get_recoverable_reserve_uses','get_task_thread','supervisor_approve_payment','approve_payment_supervisor','supervisor_finalize_registered_payment','create_finance_task_v2','create_finance_task_template','update_finance_task_v2','update_finance_task_management','reassign_finance_task','review_finance_task','review_finance_task_scored','request_task_justification','decide_task_extension','set_team_capacity','save_manual_daily_plan','save_flexible_daily_plan','save_enhanced_daily_plan','supervisor_open_daily_plan','approve_adhoc_activity','approve_all_adhoc_activities_today','delete_requested_payment','delete_bank_account','create_imprest_fund_v2','update_imprest_fund','delete_imprest_fund','request_imprest_funding','open_imprest_settlement_task','record_imprest_refund','update_unapproved_payment','resume_pending_payment','update_pending_payment_followup','mark_payment_pending','start_finance_task','submit_finance_task_result','add_task_comment','request_task_extension','mark_task_blocker','submit_task_justification','clear_task_blocker','try_perform_work_item_action_v5']) then
   raise exception 'DELEGATED_FUNCTION_NOT_ALLOWED';
 end if;
 if jsonb_typeof(p_arguments) is distinct from 'object' or octet_length(p_arguments::text)>524288 then
   raise exception 'DELEGATED_ARGUMENTS_INVALID';
 end if;
 select p.* into target from pg_catalog.pg_proc p
 where p.pronamespace='public'::regnamespace and p.proname=p_function
   and p.prokind='f' and p.provariadic=0
   and pg_catalog.has_function_privilege('authenticated',p.oid,'EXECUTE')
   and not exists(select 1 from jsonb_object_keys(p_arguments) k where k<>all(coalesce(p.proargnames,'{}')))
   and not exists(
     select 1 from generate_series(0,p.pronargs-p.pronargdefaults-1) i
     where not p_arguments ? p.proargnames[i+1]
   );
 if not found then raise exception 'DELEGATED_ARGUMENTS_INVALID';end if;

 -- Resolve only named, typed arguments of an explicitly allowed function.
 for argument in
   select target.proargnames[i+1] as name,pg_catalog.format_type(target.proargtypes[i],null) as type,
      (select typcategory='A' from pg_catalog.pg_type where oid=target.proargtypes[i]) as is_array
   from generate_series(0,target.pronargs-1) i
 loop
   if p_arguments ? argument.name then
    if arguments_sql<>'' then arguments_sql:=arguments_sql||',';end if;
    if argument.is_array and jsonb_typeof(p_arguments->argument.name)='array' then
      arguments_sql:=arguments_sql||format('%I => ARRAY(select jsonb_array_elements_text(%L::jsonb))::%s',argument.name,(p_arguments->argument.name)::text,argument.type);
    else
      arguments_sql:=arguments_sql||format('%I => %L::%s',argument.name,p_arguments->>argument.name,argument.type);
    end if;
   end if;
 end loop;

 if p_function in ('supervisor_approve_payment','approve_payment_supervisor','supervisor_finalize_registered_payment') then
   payment_id:=(p_arguments->>'p_payment_id')::uuid;
 end if;
 if p_function in ('review_finance_task','review_finance_task_scored','decide_task_extension') then
   task_id:=(p_arguments->>'p_task_id')::uuid;
   if p_function='decide_task_extension' then
     select r.task_id into task_id from public.task_extension_requests r where r.id=(p_arguments->>'p_request_id')::uuid;
   end if;
 end if;
 if p_function='try_perform_work_item_action_v5' then
   select * into work_item from public.work_items where id=(p_arguments->>'p_work_item_id')::uuid;
   if p_arguments->>'p_action' in ('APPROVE_PAYMENT_SUPERVISOR','PAYMENT_SUPERVISOR_APPROVE','POST_PAYMENT') and work_item.source_entity_type='payment' then
     payment_id:=work_item.source_entity_id::uuid;
   end if;
   if p_arguments->>'p_action' in ('APPROVE_COMPLETION','RETURN_REWORK','APPROVE_EXTENSION','REJECT_EXTENSION','REQUEST_EXTENSION_INFO') and work_item.source_entity_type='task' then
     task_id:=work_item.source_entity_id::uuid;
   end if;
 end if;
 if payment_id is not null and exists(
    select 1 from public.payments p where p.id=payment_id
      and auth.uid() in (p.requested_by,p.executed_by,p.accounting_registered_by)
 ) then raise exception 'DELEGATED_SELF_REVIEW_DENIED';end if;
 if task_id is not null and (
 exists(select 1 from public.tasks t where t.id=task_id and t.owner_id=auth.uid())
 or exists(select 1 from public.task_activity_events e where e.id=(
   select last_event.id from public.task_activity_events last_event
   where last_event.task_id=task_id and last_event.event_type='TASK_SUBMITTED_FOR_REVIEW'
   order by last_event.created_at desc,last_event.id desc limit 1
 ) and e.actor_id=auth.uid())
 or (p_function='decide_task_extension' and exists(
   select 1 from public.task_extension_requests r where r.id=(p_arguments->>'p_request_id')::uuid and r.requested_by=auth.uid()
 ))
 ) then
   raise exception 'DELEGATED_SELF_REVIEW_DENIED';
 end if;

 perform set_config('sanam.supervisor_delegation',delegation.id::text,true);
 if target.proretset then
   execute format('select coalesce(jsonb_agg(to_jsonb(r)),''[]''::jsonb) from public.%I(%s) r',p_function,arguments_sql) into result;
 else
   execute format('select to_jsonb(public.%I(%s))',p_function,arguments_sql) into result;
 end if;
 if p_function not in ('get_supervisor_control_center','get_workload_capacity','get_escalation_center','get_workcenter_dashboard_v5','get_workcenter_detail_v5','get_workflow_timeline','get_payment_accounting_queue','get_finance_team_performance','get_finance_team_kpi_report','get_employee_performance_report_v4','get_adhoc_activities','get_visible_bank_liquidity','get_bank_account_directory','get_reserve_account_monitor','get_reserve_account_movement_report_v2','get_imprest_fund_summary','get_imprest_settlement_register','get_imprest_funding_overview','get_imprest_funding_requests','get_imprest_ledger_entries','get_recoverable_reserve_uses','get_task_thread') then
   insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
   values(auth.uid(),'SUPERVISOR_DELEGATED_ACTION','leave_delegation',delegation.id::text,
    jsonb_build_object('delegation_id',delegation.id,'absent_user_id',delegation.absent_user_id,
      'actor_id',auth.uid(),'actor_original_role',(select role from public.profiles where id=auth.uid()),
      'acting_role','Supervisor','function',p_function,
      'task_id',task_id,'payment_id',payment_id,'work_item_id',p_arguments->>'p_work_item_id'));
 end if;
 perform set_config('sanam.supervisor_delegation',coalesce(old_context,''),true);
 return result;
end $$;
revoke all on function public.perform_supervisor_delegated_rpc(text,jsonb) from public,anon;
grant execute on function public.perform_supervisor_delegated_rpc(text,jsonb) to authenticated;

create function private.is_delegated_supervisor_for(p_user_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.active_supervisor_delegations() where absent_user_id=p_user_id)
$$;
revoke all on function private.is_delegated_supervisor_for(uuid) from public,anon;
grant execute on function private.is_delegated_supervisor_for(uuid) to authenticated;

CREATE OR REPLACE FUNCTION private.workcenter_scope_allowed(p_scope text, p_actor uuid, p_actor_role text, p_assignee uuid, p_reviewer uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$ select case p_scope when 'ASSIGNEE' then p_actor is not null and (p_actor=p_assignee or (p_actor=auth.uid() and private.is_delegated_supervisor_for(p_assignee))) when 'ACCESS' then p_actor_role in ('CFO','Supervisor') or (p_actor=p_assignee or (p_actor=auth.uid() and private.is_delegated_supervisor_for(p_assignee))) or (p_actor=p_reviewer or (p_actor=auth.uid() and private.is_delegated_supervisor_for(p_reviewer))) when 'MANAGER' then p_actor_role in ('CFO','Supervisor') when 'REVIEWER_OR_MANAGER' then (p_actor=p_reviewer or (p_actor=auth.uid() and private.is_delegated_supervisor_for(p_reviewer))) or (p_actor_role in ('CFO','Supervisor') and p_actor is distinct from p_assignee) when 'CFO' then p_actor_role='CFO' when 'EXACT_ROLE' then true when 'MANAGER_OR_ASSIGNEE' then p_actor_role in ('CFO','Supervisor') or (p_actor=p_assignee or (p_actor=auth.uid() and private.is_delegated_supervisor_for(p_assignee))) else false end; $function$;

CREATE OR REPLACE FUNCTION public.approve_payment_supervisor(p_payment_id uuid)
 RETURNS payments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare p public.payments;
begin
  if not private.is_supervisor_or_delegate() then raise exception 'Not authorized for supervisor approval'; end if;
  if exists(select 1 from private.active_supervisor_delegations()) and exists(select 1 from public.payments where id=p_payment_id and requested_by=auth.uid()) then
    raise exception 'DELEGATED_SELF_REVIEW_DENIED';
  end if;
  update public.payments set supervisor_status='موافق',status='بانتظار اعتماد CFO',supervisor_approved_by=auth.uid(),supervisor_approved_at=now(),updated_at=now()
  where id=p_payment_id and supervisor_status='معلق' returning * into p;
  if p.id is null then raise exception 'Payment not found or already processed'; end if;
  return p;
end $function$;

CREATE OR REPLACE FUNCTION private.audit_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
begin
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),tg_op,lower(tg_table_name),coalesce(new.id,old.id)::text,
         jsonb_build_object('delegation',(select to_jsonb(d) from private.active_supervisor_delegations() d limit 1),'actor_original_role',(select role from public.profiles where id=auth.uid()),'old',case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end,'new',case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end));
  return coalesce(new,old);
end $function$;

CREATE OR REPLACE FUNCTION public.get_workcenter_dashboard_v5(p_scope text DEFAULT 'mine'::text, p_filters jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  uid uuid:=auth.uid();
  actor_role text:=private.current_role();
  actor_family text;
  engine_enabled boolean;
  c private.workcenter_cycles%rowtype;
  items jsonb;
  people jsonb;
  stats jsonb;
  date_from date;
  date_to date;
begin
  if uid is null or actor_role is null then raise exception 'NOT_AUTHORIZED'; end if;
  if p_scope not in ('mine','team') then raise exception 'INVALID_SCOPE'; end if;
  if p_scope='team' and actor_role not in ('CFO','Supervisor') then raise exception 'TEAM_SCOPE_NOT_ALLOWED'; end if;

  actor_family:=private.workcenter_role_family(actor_role);
  engine_enabled:=private.workcenter_rule_engine_enabled();

  select * into c from private.workcenter_cycles where active;
  if not found then
    return jsonb_build_object('cycle',null,'items','[]'::jsonb,'team','[]'::jsonb,'summary','{}'::jsonb);
  end if;

  date_from:=coalesce(nullif(p_filters->>'from','')::date,(c.started_at at time zone 'Asia/Riyadh')::date);
  date_to:=coalesce(nullif(p_filters->>'to','')::date,(now() at time zone 'Asia/Riyadh')::date);
  if date_from>date_to then raise exception 'INVALID_DATE_RANGE'; end if;

  with base as materialized (
    select
      w.*,
      m.entered_at,
      pa.full_name assignee_name,
      pr.full_name reviewer_name,
      case when w.status='Completed' then w.completed_by else w.assignee_id end owner_id,
      coalesce(t.assigned_at,m.entered_at) assigned_at,
      t.result_description,
      t.quality_score,
      t.rework_count,
      t.blocker_note,
      t.review_requested_at,
      t.original_due_date,
      t.original_due_time,
      t.output task_description,
      t.source_entity_type task_source_type,
      w.status='Completed' is_completed,
      (
        w.status in ('Pending Review','Extension Requested')
        or (
          w.item_type in ('PAYMENT_SUPERVISOR_APPROVAL','PAYMENT_CFO_APPROVAL')
          and w.status in ('Ready','Assigned')
        )
      ) is_review,
      private.task_effective_due_at(w.due_at) effective_due_at
    from private.workcenter_cycle_items m
    join public.work_items w on w.id=m.work_item_id
    left join public.tasks t on w.source_entity_type='task' and t.id::text=w.source_entity_id
    left join public.profiles pa on pa.id=w.assignee_id
    left join public.profiles pr on pr.id=w.reviewer_id
    where m.cycle_id=c.id
      and private.close_work_in_scope(w.source_entity_type,w.source_entity_id)
      and w.performance_credit
      and w.status not in ('Waiting','Cancelled','Closed')
      and (
        actor_role in ('CFO','Supervisor')
        or w.assignee_id=uid
        or w.reviewer_id=uid
        or w.completed_by=uid
      )
      and (
        p_scope='team'
        or case
          when w.status='Completed' then w.completed_by=uid
          else (w.assignee_id=uid or private.is_delegated_supervisor_for(w.assignee_id))
            or ((w.reviewer_id=uid or private.is_delegated_supervisor_for(w.reviewer_id)) and w.status in ('Pending Review','Extension Requested'))
        end
      )
      and (
        nullif(p_filters->>'employee_id','') is null
        or (case when w.status='Completed' then w.completed_by else w.assignee_id end)::text=p_filters->>'employee_id'
      )
      and (nullif(p_filters->>'item_type','') is null or w.item_type=p_filters->>'item_type')
      and (nullif(p_filters->>'priority','') is null or w.priority=p_filters->>'priority')
      and (nullif(p_filters->>'search','') is null or w.title ilike '%'||(p_filters->>'search')||'%')
      and (
        w.status<>'Completed'
        or (w.completed_at at time zone 'Asia/Riyadh')::date between date_from and date_to
      )
  ),
  classified as materialized (
    select
      b.*,
      (b.effective_due_at<now() and b.status not in ('Completed','Closed','Cancelled','Waiting')) is_overdue,
      case
        when is_completed then 'completed'
        when is_review then 'reviews'
        when status in ('Blocked','Paused','Returned for Rework') then 'attention'
        else 'execution'
      end bucket,
      (
        coalesce(b.effective_due_at<now() and b.status not in ('Completed','Closed','Cancelled','Waiting'),false)
        or b.status in ('Blocked','Paused','Returned for Rework')
      ) is_attention,
      case
        when is_completed and b.effective_due_at is not null
          then coalesce(review_requested_at,completed_at)<=b.effective_due_at
        else null
      end on_time
    from base b
  ),
  action_keys as materialized (
    select distinct action_key
    from public.workcenter_action_rules
    where active and handler_key<>'SOURCE_GUARDED'
  ),
  ranked_rules as (
    select
      b.id work_item_id,
      ar.rule_id,
      ar.action_key,
      ar.next_status,
      ar.audit_event,
      ar.handler_key,
      ar.effect,
      ar.authorization_scope,
      ar.role_key,
      row_number() over (
        partition by b.id,ak.action_key
        order by
          case
            when ar.role_key=actor_role then 0
            when ar.role_key=actor_family then 1
            when ar.role_key='Supervisor' and actor_role='CFO' then 2
            else 3
          end,
          case when ar.status_key=b.status then 0 else 1 end,
          case when ar.item_type_key=b.item_type then 0 else 1 end,
          case when ar.effect='DENY' then 0 else 1 end,
          ar.sort_order
      ) rn,
      b.status,
      b.item_type,
      b.source_entity_type,
      b.assignee_id,
      b.reviewer_id,
      b.effective_due_at,
      b.metadata
    from classified b
    cross join action_keys ak
    join public.workcenter_action_rules ar
      on ar.active
     and ar.action_key=ak.action_key
     and ar.status_key in (b.status,'*')
     and ar.item_type_key in (b.item_type,'*')
     and ar.role_key in (
       actor_role,
       actor_family,
       case when actor_role='CFO' then 'Supervisor' end,
       case when actor_role in ('CFO','Supervisor') then 'Employee' end
     )
    where actor_role in ('CFO','Supervisor')
       or b.assignee_id=uid
       or b.reviewer_id=uid
  ),
  allowed_actions as (
    select r.*
    from ranked_rules r
    where r.rn=1
      and engine_enabled
      and r.handler_key<>'SOURCE_GUARDED'
      and r.effect<>'DENY'
      and not (r.authorization_scope='EXACT_ROLE' and r.role_key<>actor_role)
      and private.workcenter_scope_allowed(
        r.authorization_scope,uid,actor_role,r.assignee_id,r.reviewer_id
      )
      and private.workcenter_source_guard_allowed(
        r.handler_key,r.source_entity_type,r.item_type
      )
      and not (
        r.action_key='APPROVE_COMPLETION'
        and uid=r.assignee_id
        and coalesce((r.metadata->>'allow_self_review')::boolean,false)=false
      )
      and (
        r.action_key<>'REQUEST_JUSTIFICATION'
        or r.status='Blocked'
        or (
          r.effective_due_at is not null
          and r.effective_due_at<now()
          and r.status not in ('Completed','Closed','Cancelled')
        )
        or coalesce((r.metadata->>'sla_breach')::boolean,false)
      )
  ),
  action_sets as (
    select
      work_item_id,
      jsonb_agg(
        jsonb_build_object('action',action_key,'next_status',next_status)
        order by action_key
      ) actions,
      bool_or(
        action_key in (
          'APPROVE_COMPLETION',
          'RETURN_REWORK',
          'APPROVE_EXTENSION',
          'REJECT_EXTENSION',
          'REQUEST_EXTENSION_INFO',
          'APPROVE_PAYMENT_SUPERVISOR',
          'APPROVE_PAYMENT_CFO'
        )
      ) my_decision
    from allowed_actions
    group by work_item_id
  ),
  enriched as (
    select
      b.*,
      coalesce(a.actions,'[]'::jsonb) actions,
      coalesce(a.my_decision,false) requires_my_decision
    from classified b
    left join action_sets a on a.work_item_id=b.id
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'work_item_id',id,
        'source_type',source_entity_type,
        'source_id',source_entity_id,
        'item_type',item_type,
        'title',title,
        'assignee_id',assignee_id,
        'owner_id',owner_id,
        'assignee_name',assignee_name,
        'reviewer_id',reviewer_id,
        'reviewer_name',reviewer_name,
        'status',status,
        'priority',priority,
        'bucket',bucket,
        'is_overdue',coalesce(is_overdue,false),
        'is_attention',is_attention,
        'is_review',is_review,
        'requires_my_decision',requires_my_decision,
        'assigned_at',assigned_at,
        'entered_at',entered_at,
        'due_at',due_at,
        'started_at',started_at,
        'completed_at',completed_at,
        'completed_by',completed_by,
        'quality_score',quality_score,
        'on_time',on_time,
        'rework_count',coalesce(rework_count,0),
        'result_description',result_description,
        'blocker_note',blocker_note,
        'task_description',task_description,
        'task_source_type',task_source_type,
        'available_actions',actions,
        'remaining_minutes',
          case
            when effective_due_at is null or is_completed then null
            else private.task_business_minutes_between(now(),effective_due_at)
          end
      )
      order by is_attention desc,due_at nulls last,entered_at
    ),
    '[]'::jsonb
  )
  into items
  from enriched;

  select jsonb_build_object(
    'total',count(*),
    'execution',count(*) filter(where x->>'bucket'='execution'),
    'reviews',count(*) filter(where (x->>'is_review')::boolean),
    'attention',count(*) filter(where (x->>'is_attention')::boolean),
    'completed',count(*) filter(where x->>'bucket'='completed'),
    'ready',count(*) filter(where x->>'status' in ('Ready','Assigned') and x->>'bucket'='execution'),
    'in_progress',count(*) filter(where x->>'status' in ('Started','In Progress') and x->>'bucket'='execution'),
    'overdue',count(*) filter(where (x->>'is_overdue')::boolean),
    'my_decisions',count(*) filter(
      where (x->>'is_review')::boolean and (x->>'requires_my_decision')::boolean
    )
  )
  into stats
  from jsonb_array_elements(items) x;

  if actor_role in ('CFO','Supervisor') and p_scope='team' then
    select coalesce(jsonb_agg(z order by z->>'full_name'),'[]'::jsonb)
    into people
    from (
      select jsonb_build_object(
        'user_id',p.id,
        'full_name',p.full_name,
        'role',p.role,
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
        'on_time_rate',
          round(
            100.0*count(x) filter(where (x->>'on_time')::boolean)
            /nullif(count(x->>'on_time'),0),
            1
          )
      ) z
      from public.profiles p
      left join jsonb_array_elements(items) x on x->>'owner_id'=p.id::text
      where p.active
        and p.role in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant')
        and (
          nullif(p_filters->>'employee_id','') is null
          or p.id::text=p_filters->>'employee_id'
        )
      group by p.id,p.full_name,p.role
    ) q;
  else
    people:='[]'::jsonb;
  end if;

  return jsonb_build_object(
    'cycle',jsonb_build_object('id',c.id,'label',c.label,'started_at',c.started_at),
    'as_of',now(),
    'from',date_from,
    'to',date_to,
    'scope',p_scope,
    'items',items,
    'summary',stats,
    'team',people
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.get_daily_payment_mail_config()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare c private.daily_payment_mail_config%rowtype;
begin
 if coalesce(private.effective_supervisor_role(),'') not in ('CFO','Supervisor','BankAccountant') then raise exception 'NOT_AUTHORIZED';end if;
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
 if coalesce(private.effective_supervisor_role(),'') not in ('Supervisor','BankAccountant') or not coalesce(public.has_user_permission('page.payments'),false) then raise exception 'MAIL_SENDER_ROLE_REQUIRED';end if;
 if p_report_date is null or p_report_date>(now() at time zone 'Asia/Riyadh')::date then raise exception 'MAIL_REPORT_DATE_INVALID';end if;
 select * into sender from public.profiles where id=auth.uid() and active;
 configuration:=public.get_daily_payment_mail_config();
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'due_date',p.due_date,'company',p.company,'beneficiary',p.beneficiary,'amount',p.amount,
  'bank_account',concat_ws(' — ',b.bank_name,b.account_name),'purpose',p.purpose,'executed_at',p.executed_at) order by p.executed_at,p.id),'[]') into items
 from public.payments p left join public.bank_accounts b on b.id=p.bank_account_id
 where p.operation_type='Payment' and (p.executed_at at time zone 'Asia/Riyadh')::date=p_report_date and p.supervisor_status='موافق' and p.cfo_status='موافق';
 payload:=jsonb_build_object('date',p_report_date,'subject','التحويلات البنكية المنفذة خلال اليوم '||p_report_date::text,
  'sender',jsonb_build_object('id',sender.id,'name',sender.full_name,'email',sender.email,'role',case when private.is_supervisor_or_delegate() then 'Supervisor' else sender.role end),
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

CREATE OR REPLACE FUNCTION public.finish_daily_payment_mail(p_dispatch_id uuid, p_status text, p_provider_request_id text, p_error_code text, p_server_secret text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
begin
 perform private.verify_mail_dispatch_secret(p_server_secret);
 if coalesce(private.effective_supervisor_role(),'') not in ('Supervisor','BankAccountant') then raise exception 'MAIL_SENDER_ROLE_REQUIRED';end if;
 if p_status is null or p_status not in ('Accepted','Failed','Unknown') then raise exception 'MAIL_INVALID_STATUS';end if;
 update public.daily_payment_mail_dispatches set status=p_status,provider_request_id=left(p_provider_request_id,200),error_code=left(p_error_code,100),updated_at=now()
 where id=p_dispatch_id and sender_id=auth.uid() and status='Sending';
 if not found then raise exception 'MAIL_DISPATCH_STATE_CONFLICT';end if;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'DAILY_PAYMENT_MAIL_'||upper(p_status),'mail_dispatch',p_dispatch_id::text,jsonb_build_object('status',p_status,'provider_request_id',left(p_provider_request_id,200)));
end$function$;

alter policy "bank_accounts_manage" on public."bank_accounts" using (((private."current_role"() = ANY (ARRAY['CFO'::text, 'Supervisor'::text, 'BankAccountant'::text]))) or private.effective_supervisor_role()='Supervisor') with check (((private."current_role"() = ANY (ARRAY['CFO'::text, 'Supervisor'::text, 'BankAccountant'::text]))) or private.effective_supervisor_role()='Supervisor');

alter policy "finance_activity_read" on public."finance_activity_log" using ((((employee_id = auth.uid()) OR (private."current_role"() = ANY (ARRAY['CFO'::text, 'Supervisor'::text])))) or private.effective_supervisor_role()='Supervisor');

alter policy "imprest_delete" on public."imprest_funds" using (((private."current_role"() = ANY (ARRAY['CFO'::text, 'Supervisor'::text]))) or private.effective_supervisor_role()='Supervisor');

alter policy "imprest_insert" on public."imprest_funds" with check (((private."current_role"() = ANY (ARRAY['CFO'::text, 'Supervisor'::text, 'BankAccountant'::text, 'APAccountant'::text]))) or private.effective_supervisor_role()='Supervisor');

alter policy "imprest_update" on public."imprest_funds" using (((private."current_role"() = ANY (ARRAY['CFO'::text, 'Supervisor'::text]))) or private.effective_supervisor_role()='Supervisor') with check (((private."current_role"() = ANY (ARRAY['CFO'::text, 'Supervisor'::text]))) or private.effective_supervisor_role()='Supervisor');

alter policy "close_manage" on public."monthly_close_tasks" using (((( SELECT profiles.role
   FROM profiles
  WHERE (profiles.id = auth.uid())) = ANY (ARRAY['CFO'::text, 'Supervisor'::text]))) or private.effective_supervisor_role()='Supervisor') with check (((( SELECT profiles.role
   FROM profiles
  WHERE (profiles.id = auth.uid())) = ANY (ARRAY['CFO'::text, 'Supervisor'::text]))) or private.effective_supervisor_role()='Supervisor');

alter policy "payments_insert" on public."payments" with check (((private."current_role"() = ANY (ARRAY['CFO'::text, 'Supervisor'::text, 'BankAccountant'::text, 'APAccountant'::text]))) or private.effective_supervisor_role()='Supervisor');

alter policy "payments_read" on public."payments" using (((private."current_role"() = ANY (ARRAY['CFO'::text, 'Supervisor'::text, 'BankAccountant'::text, 'GLAccountant'::text, 'APAccountant'::text]))) or private.effective_supervisor_role()='Supervisor');

alter policy "payments_update" on public."payments" using ((((private."current_role"() = ANY (ARRAY['CFO'::text, 'Supervisor'::text, 'BankAccountant'::text, 'GLAccountant'::text, 'APAccountant'::text])) OR private.is_supervisor_or_delegate())) or private.effective_supervisor_role()='Supervisor') with check ((((private."current_role"() = ANY (ARRAY['CFO'::text, 'Supervisor'::text, 'BankAccountant'::text, 'GLAccountant'::text, 'APAccountant'::text])) OR private.is_supervisor_or_delegate())) or private.effective_supervisor_role()='Supervisor');

alter policy "tasks_manage" on public."tasks" using ((((private."current_role"() = ANY (ARRAY['CFO'::text, 'Supervisor'::text])) OR (owner_id = auth.uid()) OR (EXISTS ( SELECT 1
   FROM leave_delegations ld
  WHERE ((ld.substitute_user_id = auth.uid()) AND (ld.absent_user_id = tasks.owner_id) AND (ld.active = true) AND ((CURRENT_DATE >= ld.date_from) AND (CURRENT_DATE <= ld.date_to))))))) or private.effective_supervisor_role()='Supervisor') with check ((((private."current_role"() = ANY (ARRAY['CFO'::text, 'Supervisor'::text])) OR (owner_id = auth.uid()) OR (EXISTS ( SELECT 1
   FROM leave_delegations ld
  WHERE ((ld.substitute_user_id = auth.uid()) AND (ld.absent_user_id = tasks.owner_id) AND (ld.active = true) AND ((CURRENT_DATE >= ld.date_from) AND (CURRENT_DATE <= ld.date_to))))))) or private.effective_supervisor_role()='Supervisor');

alter policy "tasks_read" on public."tasks" using ((((owner_id = auth.uid()) OR (reviewer_id = auth.uid()) OR (private."current_role"() = ANY (ARRAY['CFO'::text, 'Supervisor'::text])) OR (EXISTS ( SELECT 1
   FROM leave_delegations ld
  WHERE ((ld.substitute_user_id = auth.uid()) AND (ld.absent_user_id = tasks.owner_id) AND (ld.active = true) AND ((CURRENT_DATE >= ld.date_from) AND (CURRENT_DATE <= ld.date_to))))))) or private.effective_supervisor_role()='Supervisor');

alter policy "work_item_events_select" on public."work_item_events" using (((EXISTS ( SELECT 1
   FROM work_items w
  WHERE ((w.id = work_item_events.work_item_id) AND ((private."current_role"() = ANY (ARRAY['CFO'::text, 'Supervisor'::text])) OR (w.assignee_id = auth.uid()) OR (w.reviewer_id = auth.uid())))))) or private.effective_supervisor_role()='Supervisor');

alter policy "work_items_select" on public."work_items" using ((((private."current_role"() = ANY (ARRAY['CFO'::text, 'Supervisor'::text])) OR (assignee_id = auth.uid()) OR (reviewer_id = auth.uid()))) or private.effective_supervisor_role()='Supervisor');

CREATE OR REPLACE FUNCTION public.start_finance_task(p_task_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare v_task public.tasks%rowtype;
begin
 select * into v_task from public.tasks where id=p_task_id for update; if not found then raise exception 'Task not found'; end if;
 if (v_task.owner_id is distinct from auth.uid() and not private.is_delegated_supervisor_for(v_task.owner_id)) then raise exception 'Only task owner can start the task'; end if;
 if v_task.opened_at is null then raise exception 'Task has not been released by the Supervisor'; end if;
 if v_task.status in ('مكتمل','بانتظار المراجعة') then raise exception 'Task cannot be started in its current status'; end if;
 update public.tasks set status='قيد التنفيذ',started_at=coalesce(started_at,now()),updated_at=now() where id=p_task_id;
 insert into public.task_activity_events(task_id,actor_id,event_type,details) values(p_task_id,auth.uid(),'TASK_STARTED',jsonb_build_object('started_at',coalesce(v_task.started_at,now())));
 perform private.notify_task_participants_v4(p_task_id,auth.uid(),'TASK_STARTED','تم بدء المهمة',v_task.name,'V4:STARTED:'||p_task_id::text||':'||coalesce(v_task.started_at,now())::text);
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'START_TASK','task',p_task_id::text,jsonb_build_object('name',v_task.name));
end $function$
;

CREATE OR REPLACE FUNCTION public.submit_finance_task_result(p_task_id uuid, p_result_description text, p_justification text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  v_task public.tasks%rowtype;
  v_deadline timestamptz;
  v_requires_justification boolean;
  v_justification text;
  v_result text;
  v_role text:=private.current_role();
  v_self_complete boolean:=false;
begin
  select * into v_task from public.tasks where id=p_task_id for update;
  if not found then raise exception 'Task not found'; end if;
  if (v_task.owner_id is distinct from auth.uid() and not private.is_delegated_supervisor_for(v_task.owner_id)) then raise exception 'Only task owner can submit the task'; end if;
  if v_task.started_at is null or v_task.status<>'قيد التنفيذ' then raise exception 'TASK_MUST_BE_STARTED'; end if;
  if nullif(trim(coalesce(v_task.blocker_note,'')),'') is not null then raise exception 'TASK_BLOCKER_MUST_BE_CLEARED'; end if;

  v_result:=nullif(trim(coalesce(p_result_description,'')),'');
  if v_result is null then raise exception 'RESULT_DESCRIPTION_REQUIRED'; end if;

  v_deadline:=private.task_deadline(v_task.due_date,v_task.due_time);
  v_requires_justification:=(v_deadline is not null and now()>v_deadline) or v_task.justification_requested_at is not null;
  v_justification:=coalesce(nullif(trim(coalesce(p_justification,'')),''),v_task.delay_justification);
  if v_requires_justification and v_justification is null then raise exception 'DELAY_JUSTIFICATION_REQUIRED'; end if;

  v_self_complete:=v_task.owner_id=v_task.reviewer_id
    and auth.uid()=v_task.owner_id
    and v_role in ('CFO','Supervisor');

  if v_self_complete then
    update public.tasks
       set status='مكتمل',
           review_requested_at=now(),
           reviewed_at=null,
           reviewed_by=null,
           review_note=null,
           completed_at=now(),
           result_description=v_result,
           quality_score=null,
           evaluation_note=null,
           evaluated_by=null,
           evaluated_at=null,
           delay_justification=case when v_requires_justification then v_justification else delay_justification end,
           justification_submitted_at=case when v_requires_justification then coalesce(justification_submitted_at,now()) else justification_submitted_at end,
           updated_at=now()
     where id=p_task_id;

    insert into public.task_comments(task_id,author_id,comment_type,body)
    values(p_task_id,auth.uid(),'Completion',v_result);

    insert into public.task_activity_events(task_id,actor_id,event_type,details)
    values(
      p_task_id,
      auth.uid(),
      'TASK_SELF_COMPLETED',
      jsonb_build_object(
        'deadline',v_deadline,
        'late',v_deadline is not null and now()>v_deadline,
        'result_description',v_result,
        'automatic',true,
        'reason','OWNER_IS_REVIEWER_MANAGER'
      )
    );

    insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
    values(
      auth.uid(),
      'SELF_COMPLETE_TASK_RESULT',
      'task',
      p_task_id::text,
      jsonb_build_object(
        'deadline',v_deadline,
        'late',v_deadline is not null and now()>v_deadline,
        'result_description',v_result,
        'justification',case when v_requires_justification then v_justification else null end,
        'automatic',true,
        'reason','OWNER_IS_REVIEWER_MANAGER'
      )
    );
  else
    update public.tasks
       set status='بانتظار المراجعة',
           review_requested_at=now(),
           reviewed_at=null,
           reviewed_by=null,
           review_note=null,
           result_description=v_result,
           quality_score=null,
           evaluation_note=null,
           evaluated_by=null,
           evaluated_at=null,
           delay_justification=case when v_requires_justification then v_justification else delay_justification end,
           justification_submitted_at=case when v_requires_justification then coalesce(justification_submitted_at,now()) else justification_submitted_at end,
           updated_at=now()
     where id=p_task_id;

    insert into public.task_comments(task_id,author_id,comment_type,body)
    values(p_task_id,auth.uid(),'Completion',v_result);

    insert into public.task_activity_events(task_id,actor_id,event_type,details)
    values(
      p_task_id,
      auth.uid(),
      'TASK_SUBMITTED_FOR_REVIEW',
      jsonb_build_object('deadline',v_deadline,'late',v_deadline is not null and now()>v_deadline,'result_description',v_result)
    );

    perform private.notify_task_participants_v4(
      p_task_id,
      auth.uid(),
      'TASK_PENDING_REVIEW',
      'مهمة بانتظار المراجعة',
      v_task.name,
      'V4:PENDING_REVIEW:'||p_task_id::text||':'||extract(epoch from now())::bigint::text
    );

    insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
    values(
      auth.uid(),
      'SUBMIT_TASK_RESULT',
      'task',
      p_task_id::text,
      jsonb_build_object(
        'deadline',v_deadline,
        'late',v_deadline is not null and now()>v_deadline,
        'result_description',v_result,
        'justification',case when v_requires_justification then v_justification else null end
      )
    );
  end if;
end $function$
;

CREATE OR REPLACE FUNCTION private.workflow_can_view_instance(p_instance_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select private.effective_supervisor_role() in ('CFO','Supervisor')
    or exists(select 1 from public.work_items w where w.workflow_instance_id=p_instance_id and (w.assignee_id=auth.uid() or w.reviewer_id=auth.uid()));
$function$
;

CREATE OR REPLACE FUNCTION public.add_task_comment(p_task_id uuid, p_body text, p_comment_type text DEFAULT 'Comment'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare v_task public.tasks%rowtype; v_id uuid; v_type text:=coalesce(nullif(trim(p_comment_type),''),'Comment');
begin
 if nullif(trim(coalesce(p_body,'')),'') is null then raise exception 'Comment is required'; end if;
 select * into v_task from public.tasks where id=p_task_id; if not found then raise exception 'Task not found'; end if;
 if not private.can_access_task(v_task) then raise exception 'Not authorized for this task'; end if;
 insert into public.task_comments(task_id,author_id,comment_type,body) values(p_task_id,auth.uid(),v_type,trim(p_body)) returning id into v_id;
 insert into public.task_activity_events(task_id,actor_id,event_type,details) values(p_task_id,auth.uid(),'COMMENT_ADDED',jsonb_build_object('comment_id',v_id,'comment_type',v_type));
 perform private.notify_task_participants_v4(p_task_id,auth.uid(),'TASK_COMMENT','تحديث على المهمة',v_task.name||': '||left(trim(p_body),180),'V4:COMMENT:'||v_id::text);
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'ADD_TASK_COMMENT','task',p_task_id::text,jsonb_build_object('comment_type',v_type));
 return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.mark_task_blocker(p_task_id uuid, p_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$declare v_task public.tasks%rowtype; begin select * into v_task from public.tasks where id=p_task_id for update; if not found then raise exception 'Task not found'; end if; if (v_task.owner_id is distinct from auth.uid() and not private.is_delegated_supervisor_for(v_task.owner_id)) then raise exception 'Only task owner can mark a blocker'; end if; if v_task.status in ('مكتمل','بانتظار المراجعة') then raise exception 'Closed or submitted tasks cannot be blocked'; end if; if nullif(trim(coalesce(p_note,'')),'') is null then raise exception 'Blocker note is required'; end if; update public.tasks set blocker_note=trim(p_note),blocker_since=coalesce(blocker_since,now()),updated_at=now() where id=p_task_id; insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'MARK_TASK_BLOCKER','task',p_task_id::text,jsonb_build_object('note',trim(p_note))); end $function$
;

CREATE OR REPLACE FUNCTION public.request_task_extension(p_task_id uuid, p_requested_due_date date, p_requested_due_time time without time zone, p_justification text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare v_task public.tasks%rowtype; v_id uuid; v_requested timestamptz; v_current timestamptz;
begin
  select * into v_task from public.tasks where id=p_task_id for update; if not found then raise exception 'Task not found'; end if;
  if (v_task.owner_id is distinct from auth.uid() and not private.is_delegated_supervisor_for(v_task.owner_id)) then raise exception 'Only task owner can request extension'; end if;
  if v_task.status in ('مكتمل','بانتظار المراجعة') then raise exception 'Closed/submitted task cannot request extension'; end if;
  if nullif(trim(coalesce(p_justification,'')),'') is null then raise exception 'Extension justification is required'; end if;
  v_requested:=private.task_deadline(p_requested_due_date,p_requested_due_time);
  v_current:=private.task_deadline(v_task.due_date,v_task.due_time);
  if v_requested<=now() then raise exception 'Requested deadline must be in the future'; end if;
  if v_current is not null and v_requested<=v_current then raise exception 'Requested deadline must be later than the current deadline'; end if;
  if exists(select 1 from public.task_extension_requests where task_id=p_task_id and status='Pending') then raise exception 'A pending extension request already exists'; end if;
  insert into public.task_extension_requests(task_id,requested_by,requested_due_date,requested_due_time,justification)
  values(p_task_id,auth.uid(),p_requested_due_date,p_requested_due_time,trim(p_justification)) returning id into v_id;
  insert into public.task_activity_events(task_id,actor_id,event_type,details)
  values(p_task_id,auth.uid(),'EXTENSION_REQUESTED',jsonb_build_object('request_id',v_id,'requested_due_date',p_requested_due_date,'requested_due_time',p_requested_due_time,'previous_due_date',v_task.due_date,'previous_due_time',v_task.due_time,'justification',trim(p_justification)));
  perform private.notify_task_participants_v4(p_task_id,auth.uid(),'EXTENSION_REQUESTED','طلب تمديد مهمة',v_task.name||' — '||trim(p_justification),'V4:EXTENSION_REQUEST:'||v_id::text);
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'REQUEST_TASK_EXTENSION','task',p_task_id::text,jsonb_build_object('request_id',v_id,'previous_due_date',v_task.due_date,'previous_due_time',v_task.due_time,'requested_due_date',p_requested_due_date,'requested_due_time',p_requested_due_time));
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.submit_task_justification(p_task_id uuid, p_justification text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare v_task public.tasks%rowtype;
begin
  if nullif(trim(coalesce(p_justification,'')),'') is null then raise exception 'Justification is required'; end if;
  select * into v_task from public.tasks where id=p_task_id for update; if not found then raise exception 'Task not found'; end if;
  if (v_task.owner_id is distinct from auth.uid() and not private.is_delegated_supervisor_for(v_task.owner_id)) then raise exception 'Only task owner can submit justification'; end if;
  update public.tasks set delay_justification=trim(p_justification),justification_submitted_at=now(),updated_at=now() where id=p_task_id;
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'SUBMIT_TASK_JUSTIFICATION','task',p_task_id::text,jsonb_build_object('justification',trim(p_justification)));
end; $function$
;

alter policy daily_payment_mail_own_history on public.daily_payment_mail_dispatches
using (sender_id=(select auth.uid()) and private.effective_supervisor_role() in ('Supervisor','BankAccountant'));
