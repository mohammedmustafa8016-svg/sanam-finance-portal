-- Sanam Finance Portal V3.2
-- Additive: imprest settlement workflow linked to the existing task/work-center engine.

alter table public.tasks add column if not exists source_entity_type text;
alter table public.tasks add column if not exists source_entity_id text;
create index if not exists tasks_source_entity_idx on public.tasks(source_entity_type,source_entity_id);

create table if not exists public.imprest_settlements (
  id uuid primary key default gen_random_uuid(),
  imprest_fund_id uuid not null references public.imprest_funds(id) on delete restrict,
  task_id uuid unique references public.tasks(id) on delete set null,
  handler_id uuid not null references public.profiles(id),
  amount numeric(18,2) not null check(amount>0),
  invoice_count integer not null default 0 check(invoice_count>=0),
  received_at timestamptz not null default now(),
  notes text,
  status text not null default 'In Progress' check(status in ('In Progress','Pending Review','Returned for Rework','Approved','Cancelled')),
  submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id),
  review_note text,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists imprest_settlements_fund_status_idx on public.imprest_settlements(imprest_fund_id,status,created_at);
create index if not exists imprest_settlements_handler_idx on public.imprest_settlements(handler_id,status,created_at);

alter table public.imprest_settlements enable row level security;
drop policy if exists imprest_settlements_select on public.imprest_settlements;
create policy imprest_settlements_select on public.imprest_settlements
for select to authenticated using (
  exists(select 1 from public.profiles p where p.id=auth.uid() and p.active=true)
);
revoke insert,update,delete on public.imprest_settlements from anon,authenticated;
grant select on public.imprest_settlements to authenticated;

create or replace function public.open_imprest_settlement_task(
  p_fund_id uuid,
  p_amount numeric,
  p_invoice_count integer,
  p_due_date date,
  p_due_time time,
  p_priority text default 'عادي',
  p_notes text default null
) returns uuid
language plpgsql security definer set search_path='public','private','pg_temp' as $$
declare
  v_role text:=private.current_role();
  v_fund public.imprest_funds%rowtype;
  v_settlement_id uuid:=gen_random_uuid();
  v_task_id uuid;
  v_supervisor uuid;
  v_open numeric:=0;
  v_available numeric:=0;
begin
  if v_role not in ('APAccountant','BankAccountant','Supervisor','CFO') then raise exception 'NOT_AUTHORIZED'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'SETTLEMENT_AMOUNT_REQUIRED'; end if;
  if p_invoice_count is null or p_invoice_count<1 then raise exception 'INVOICE_COUNT_REQUIRED'; end if;
  if p_due_date is null or p_due_time is null then raise exception 'DUE_DATE_TIME_REQUIRED'; end if;
  select * into v_fund from public.imprest_funds where id=p_fund_id for update;
  if not found then raise exception 'IMPREST_NOT_FOUND'; end if;
  select coalesce(sum(amount),0) into v_open from public.imprest_settlements
   where imprest_fund_id=p_fund_id and status in ('In Progress','Pending Review','Returned for Rework');
  v_available:=greatest(coalesce(v_fund.unsettled,0)-v_open,0);
  -- Existing funds may still have zero opening balances. Enforce ceiling only once an unsettled balance is maintained.
  if coalesce(v_fund.unsettled,0)>0 and p_amount>v_available then raise exception 'SETTLEMENT_EXCEEDS_AVAILABLE_BALANCE'; end if;
  v_supervisor:=private.workflow_user_for_role('Supervisor');
  if v_supervisor is null then raise exception 'SUPERVISOR_NOT_CONFIGURED'; end if;

  insert into public.imprest_settlements(id,imprest_fund_id,handler_id,amount,invoice_count,notes,status,created_by)
  values(v_settlement_id,p_fund_id,auth.uid(),p_amount,p_invoice_count,nullif(trim(coalesce(p_notes,'')),''),'In Progress',auth.uid());

  insert into public.tasks(name,frequency,owner_id,reviewer_id,due_date,due_time,priority,status,output,created_by,opened_at,opened_by,started_at,assigned_at,assigned_by,source_entity_type,source_entity_id)
  values(
    'تصفية عهدة — '||coalesce(v_fund.name,'')||' — '||to_char(p_amount,'FM9999999990.00'),
    'عند الطلب',auth.uid(),v_supervisor,p_due_date,p_due_time,coalesce(nullif(p_priority,''),'عادي'),'قيد التنفيذ',
    'تصفية عهدة بمبلغ '||to_char(p_amount,'FM9999999990.00')||' وعدد فواتير '||p_invoice_count,
    auth.uid(),now(),auth.uid(),now(),now(),auth.uid(),'imprest_settlement',v_settlement_id::text
  ) returning id into v_task_id;

  update public.imprest_settlements set task_id=v_task_id,updated_at=now() where id=v_settlement_id;
  perform private.ensure_task_workflow_v3(v_task_id);
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'OPEN_IMPREST_SETTLEMENT','imprest_settlement',v_settlement_id::text,
    jsonb_build_object('imprest_fund_id',p_fund_id,'task_id',v_task_id,'amount',p_amount,'invoice_count',p_invoice_count,'due_date',p_due_date,'due_time',p_due_time));
  return v_settlement_id;
end $$;

grant execute on function public.open_imprest_settlement_task(uuid,numeric,integer,date,time,text,text) to authenticated;

create or replace function private.sync_imprest_settlement_from_task()
returns trigger language plpgsql security definer set search_path='public','private','pg_temp' as $$
declare
  v_settlement public.imprest_settlements%rowtype;
  v_old_status text;
begin
  if new.source_entity_type is distinct from 'imprest_settlement' or new.source_entity_id is null then return new; end if;
  select * into v_settlement from public.imprest_settlements where id=new.source_entity_id::uuid for update;
  if not found then return new; end if;
  v_old_status:=v_settlement.status;

  if new.status='بانتظار المراجعة' and v_settlement.status<>'Approved' then
    update public.imprest_settlements set status='Pending Review',submitted_at=coalesce(submitted_at,now()),updated_at=now() where id=v_settlement.id;
  elsif new.status='قيد التنفيذ' and old.status='بانتظار المراجعة' and v_settlement.status<>'Approved' then
    update public.imprest_settlements set status='Returned for Rework',reviewed_at=new.reviewed_at,reviewed_by=new.reviewed_by,review_note=new.review_note,updated_at=now() where id=v_settlement.id;
  elsif new.status='مكتمل' and v_settlement.status<>'Approved' then
    update public.imprest_settlements set status='Approved',submitted_at=coalesce(submitted_at,new.review_requested_at,new.completed_at,now()),reviewed_at=coalesce(new.reviewed_at,now()),reviewed_by=coalesce(new.reviewed_by,auth.uid()),review_note=new.review_note,updated_at=now() where id=v_settlement.id;
    update public.imprest_funds set unsettled=greatest(coalesce(unsettled,0)-v_settlement.amount,0),status=case when greatest(coalesce(unsettled,0)-v_settlement.amount,0)=0 then 'سليمة' else status end,updated_at=now() where id=v_settlement.imprest_fund_id;
    insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
    values(coalesce(new.reviewed_by,auth.uid()),'APPROVE_IMPREST_SETTLEMENT','imprest_settlement',v_settlement.id::text,
      jsonb_build_object('imprest_fund_id',v_settlement.imprest_fund_id,'task_id',new.id,'amount',v_settlement.amount,'previous_status',v_old_status));
  end if;
  return new;
end $$;

drop trigger if exists trg_sync_imprest_settlement_from_task on public.tasks;
create trigger trg_sync_imprest_settlement_from_task
after update of status,reviewed_at,reviewed_by,review_note on public.tasks
for each row execute function private.sync_imprest_settlement_from_task();

create or replace function public.get_imprest_settlement_register()
returns table(
  settlement_id uuid, imprest_fund_id uuid, imprest_name text, company text, custodian_name text,
  handler_id uuid, handler_name text, amount numeric, invoice_count integer, received_at timestamptz,
  settlement_status text, task_id uuid, task_status text, due_date date, due_time time,
  submitted_at timestamptz, reviewed_at timestamptz, reviewer_name text, review_note text, notes text
)
language sql stable security definer set search_path='public','private','pg_temp' as $$
  select s.id,f.id,f.name,f.company,c.full_name,s.handler_id,h.full_name,s.amount,s.invoice_count,s.received_at,
         s.status,t.id,t.status,t.due_date,t.due_time,s.submitted_at,s.reviewed_at,r.full_name,s.review_note,s.notes
  from public.imprest_settlements s
  join public.imprest_funds f on f.id=s.imprest_fund_id
  left join public.tasks t on t.id=s.task_id
  left join public.profiles h on h.id=s.handler_id
  left join public.profiles c on c.id=f.custodian_id
  left join public.profiles r on r.id=s.reviewed_by
  where exists(select 1 from public.profiles p where p.id=auth.uid() and p.active=true)
  order by s.created_at desc;
$$;
grant execute on function public.get_imprest_settlement_register() to authenticated;

create or replace function public.get_imprest_fund_summary()
returns table(
  imprest_fund_id uuid, under_settlement numeric, approved_settlements numeric, available_to_settle numeric
)
language sql stable security definer set search_path='public','private','pg_temp' as $$
  select f.id,
    coalesce(sum(s.amount) filter(where s.status in ('In Progress','Pending Review','Returned for Rework')),0)::numeric,
    coalesce(sum(s.amount) filter(where s.status='Approved'),0)::numeric,
    greatest(coalesce(f.unsettled,0)-coalesce(sum(s.amount) filter(where s.status in ('In Progress','Pending Review','Returned for Rework')),0),0)::numeric
  from public.imprest_funds f
  left join public.imprest_settlements s on s.imprest_fund_id=f.id
  where exists(select 1 from public.profiles p where p.id=auth.uid() and p.active=true)
  group by f.id,f.unsettled;
$$;
grant execute on function public.get_imprest_fund_summary() to authenticated;
