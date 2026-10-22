-- Sanam Finance Portal - Task Management V2 integrated compatibility patch
-- Additive only. Preserves protected baseline and existing permissions/data.

create or replace function public.get_task_operational_start_date()
returns date language sql stable security definer set search_path=public,private,pg_temp as $$
 select coalesce((select trim(both '"' from setting_value::text)::date from public.finance_settings where setting_key='daily_plan_go_live_date'),'2026-09-17'::date)
$$;
grant execute on function public.get_task_operational_start_date() to authenticated;

create or replace function public.get_task_thread(p_task_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,private,pg_temp as $$
declare v_task public.tasks%rowtype;
begin
 select * into v_task from public.tasks where id=p_task_id;
 if not found then raise exception 'Task not found'; end if;
 if not private.can_access_task(v_task) then raise exception 'Not authorized to view task thread'; end if;
 return jsonb_build_object(
  'comments',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'author_id',c.author_id,'author_name',p.full_name,'comment_type',c.comment_type,'body',c.body,'created_at',c.created_at) order by c.created_at) from public.task_comments c left join public.profiles p on p.id=c.author_id where c.task_id=p_task_id),'[]'::jsonb),
  'extensions',coalesce((select jsonb_agg(jsonb_build_object(
    'id',e.id,'requested_by',e.requested_by,'requester_name',p.full_name,
    'current_due_at',private.task_deadline(v_task.original_due_date,v_task.original_due_time),
    'requested_due_at',private.task_deadline(e.requested_due_date,e.requested_due_time),
    'justification',e.justification,'status',e.status,'decided_by',e.decided_by,
    'decision_note',e.supervisor_note,'decided_at',e.decided_at,'created_at',e.created_at
  ) order by e.created_at desc) from public.task_extension_requests e left join public.profiles p on p.id=e.requested_by where e.task_id=p_task_id),'[]'::jsonb),
  'activity',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'actor_id',a.actor_id,'actor_name',p.full_name,'event_type',a.event_type,'details',a.details,'created_at',a.created_at) order by a.created_at) from public.task_activity_events a left join public.profiles p on p.id=a.actor_id where a.task_id=p_task_id),'[]'::jsonb)
 );
end $$;
grant execute on function public.get_task_thread(uuid) to authenticated;

create or replace function public.create_finance_task_v2(
 p_name text,p_owner_id uuid,p_reviewer_id uuid,p_due_date date,p_due_time time,
 p_frequency text,p_priority text,p_status text default 'لم يبدأ'
) returns uuid language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_role text:=private.current_role(); v_id uuid; v_reviewer uuid:=p_reviewer_id;
begin
 if v_role not in ('CFO','Supervisor') then raise exception 'Not authorized to create tasks'; end if;
 if nullif(trim(coalesce(p_name,'')),'') is null then raise exception 'Task name is required'; end if;
 if p_owner_id is null or not exists(select 1 from public.profiles where id=p_owner_id and active=true) then raise exception 'Valid owner is required'; end if;
 if v_reviewer is null then
   if exists(select 1 from public.profiles where id=p_owner_id and role='Supervisor') then
     select id into v_reviewer from public.profiles where active=true and role='CFO' order by created_at limit 1;
   else
     select id into v_reviewer from public.profiles where active=true and role='Supervisor' order by created_at limit 1;
   end if;
 end if;
 insert into public.tasks(name,frequency,owner_id,reviewer_id,due_date,due_time,priority,status,created_by,assigned_at,assigned_by,created_at,updated_at)
 values(trim(p_name),coalesce(nullif(p_frequency,''),'حسب الحاجة'),p_owner_id,v_reviewer,p_due_date,p_due_time,coalesce(nullif(p_priority,''),'عادي'),coalesce(nullif(p_status,''),'لم يبدأ'),auth.uid(),now(),auth.uid(),now(),now())
 returning id into v_id;
 insert into public.task_activity_events(task_id,actor_id,event_type,details)
 values(v_id,auth.uid(),'TASK_ASSIGNED',jsonb_build_object('owner_id',p_owner_id,'reviewer_id',v_reviewer,'due_date',p_due_date,'due_time',p_due_time));
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'CREATE_TASK_V2','task',v_id::text,jsonb_build_object('owner_id',p_owner_id,'reviewer_id',v_reviewer));
 return v_id;
end $$;
grant execute on function public.create_finance_task_v2(text,uuid,uuid,date,time,text,text,text) to authenticated;

create or replace function public.update_finance_task_v2(
 p_task_id uuid,p_name text,p_reviewer_id uuid,p_due_date date,p_due_time time,p_priority text,p_frequency text default null
) returns void language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_task public.tasks%rowtype; v_role text:=private.current_role();
begin
 if v_role not in ('CFO','Supervisor') then raise exception 'Not authorized to modify tasks'; end if;
 select * into v_task from public.tasks where id=p_task_id for update;
 if not found then raise exception 'Task not found'; end if;
 if nullif(trim(coalesce(p_name,'')),'') is null then raise exception 'Task name is required'; end if;
 update public.tasks set name=trim(p_name),reviewer_id=p_reviewer_id,due_date=p_due_date,due_time=p_due_time,
   priority=coalesce(nullif(p_priority,''),priority),frequency=coalesce(nullif(p_frequency,''),frequency),updated_at=now()
 where id=p_task_id;
 insert into public.task_activity_events(task_id,actor_id,event_type,details)
 values(p_task_id,auth.uid(),'TASK_UPDATED',jsonb_build_object(
   'previous',jsonb_build_object('name',v_task.name,'reviewer_id',v_task.reviewer_id,'due_date',v_task.due_date,'due_time',v_task.due_time,'priority',v_task.priority,'frequency',v_task.frequency),
   'current',jsonb_build_object('name',trim(p_name),'reviewer_id',p_reviewer_id,'due_date',p_due_date,'due_time',p_due_time,'priority',p_priority,'frequency',p_frequency)));
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'UPDATE_TASK_V2','task',p_task_id::text,jsonb_build_object('due_date',p_due_date,'due_time',p_due_time,'priority',p_priority));
end $$;
grant execute on function public.update_finance_task_v2(uuid,text,uuid,date,time,text,text) to authenticated;

create table if not exists public.daily_work_sessions(
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references public.profiles(id),
 work_date date not null,
 started_at timestamptz not null default now(),
 ended_at timestamptz,
 start_note text,
 end_note text,
 created_at timestamptz not null default now(),
 unique(user_id,work_date)
);
alter table public.daily_work_sessions enable row level security;

create or replace function public.start_workday(p_note text default null)
returns public.daily_work_sessions language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_date date:=(now() at time zone 'Asia/Riyadh')::date; v public.daily_work_sessions;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 insert into public.daily_work_sessions(user_id,work_date,started_at,start_note)
 values(auth.uid(),v_date,now(),nullif(trim(coalesce(p_note,'')),''))
 on conflict(user_id,work_date) do update set ended_at=null,start_note=coalesce(public.daily_work_sessions.start_note,excluded.start_note)
 returning * into v;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'START_WORKDAY','daily_work_session',v.id::text,jsonb_build_object('work_date',v_date));
 return v;
end $$;
grant execute on function public.start_workday(text) to authenticated;

create or replace function public.end_workday(p_note text default null)
returns public.daily_work_sessions language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_date date:=(now() at time zone 'Asia/Riyadh')::date; v public.daily_work_sessions;
begin
 update public.daily_work_sessions set ended_at=now(),end_note=nullif(trim(coalesce(p_note,'')),'')
 where user_id=auth.uid() and work_date=v_date returning * into v;
 if not found then raise exception 'Workday has not been started'; end if;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'END_WORKDAY','daily_work_session',v.id::text,jsonb_build_object('work_date',v_date));
 return v;
end $$;
grant execute on function public.end_workday(text) to authenticated;

create or replace function public.get_my_workday()
returns table(id uuid,work_date date,started_at timestamptz,ended_at timestamptz,start_note text,end_note text)
language sql stable security definer set search_path=public,private,pg_temp as $$
 select s.id,s.work_date,s.started_at,s.ended_at,s.start_note,s.end_note
 from public.daily_work_sessions s
 where s.user_id=auth.uid() and s.work_date=(now() at time zone 'Asia/Riyadh')::date limit 1
$$;
grant execute on function public.get_my_workday() to authenticated;

-- Keep legacy automatic daily task generation disabled. Enable only deadline reminders/escalations.
update public.finance_settings set setting_value='false'::jsonb,updated_at=now() where setting_key='auto_daily_generation_enabled';
