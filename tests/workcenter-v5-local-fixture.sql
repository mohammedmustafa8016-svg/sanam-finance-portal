-- Local-only synthetic Work Center fixture. Never run against Production.
\set ON_ERROR_STOP on

insert into auth.users (id,email,raw_user_meta_data)
values
 ('00000000-0000-4000-8000-000000000001','cfo@local.invalid','{}'::jsonb),
 ('00000000-0000-4000-8000-000000000002','supervisor@local.invalid','{}'::jsonb),
 ('00000000-0000-4000-8000-000000000003','bank.accountant@local.invalid','{}'::jsonb),
 ('00000000-0000-4000-8000-000000000004','gl.accountant@local.invalid','{}'::jsonb)
on conflict (id) do nothing;

do $$
begin
  if (select count(*) from public.profiles where id in (
    '00000000-0000-4000-8000-000000000001'::uuid,
    '00000000-0000-4000-8000-000000000002'::uuid,
    '00000000-0000-4000-8000-000000000003'::uuid,
    '00000000-0000-4000-8000-000000000004'::uuid
  )) <> 4 then
    raise exception 'Synthetic profile bootstrap failed';
  end if;
end $$;

-- Production currently keeps Workflow V3 generation disabled as an operational switch.
-- Enable it only inside this disposable local fixture so synthetic tasks generate governed Work Items.
update public.finance_settings
set setting_value='true'::jsonb
where setting_key='workflow_v3_enabled';

insert into public.tasks (
  name,frequency,owner_id,reviewer_id,due_date,due_time,priority,status,output,
  created_by,assigned_at,assigned_by,started_at,review_requested_at,completed_at,
  reviewed_at,reviewed_by,quality_score,source_entity_type,source_entity_id
)
select
  'Synthetic Work Center Task '||g,
  'اختبار محلي',
  case when g%2=0
    then '00000000-0000-4000-8000-000000000003'::uuid
    else '00000000-0000-4000-8000-000000000004'::uuid end,
  '00000000-0000-4000-8000-000000000002'::uuid,
  current_date + ((g%9)-4),
  time '15:00',
  case when g%10=0 then 'حرج' when g%4=0 then 'عالي' else 'عادي' end,
  case
    when g%12=0 then 'بانتظار المراجعة'
    when g%5=0 then 'قيد التنفيذ'
    when g%7=0 then 'مكتمل'
    else 'لم يبدأ'
  end,
  'Synthetic expected output',
  '00000000-0000-4000-8000-000000000001'::uuid,
  now()-interval '1 day',
  '00000000-0000-4000-8000-000000000001'::uuid,
  case when g%5=0 then now()-interval '2 hours' else null end,
  case when g%12=0 then now()-interval '30 minutes' else null end,
  case when g%7=0 then now()-interval '20 minutes' else null end,
  case when g%7=0 then now()-interval '10 minutes' else null end,
  case when g%7=0 then '00000000-0000-4000-8000-000000000002'::uuid else null end,
  case when g%7=0 then 90+(g%10) else null end,
  'synthetic_local_test',
  g::text
from generate_series(1,1400) g;

do $
declare
  v_work_items bigint;
  v_cycle_items bigint;
  v_cycle uuid;
begin
  select count(*) into v_work_items
  from public.work_items w
  join public.tasks t on t.id::text=w.source_entity_id
  where w.source_entity_type='task'
    and t.source_entity_type='synthetic_local_test';

  if v_work_items < 1300 then
    raise exception 'Synthetic workflow generated only % Work Items',v_work_items;
  end if;

  select id into v_cycle
  from private.workcenter_cycles
  where active
  limit 1;

  if v_cycle is null then
    raise exception 'No active local Work Center cycle';
  end if;

  insert into private.workcenter_cycle_items(cycle_id,work_item_id)
  select v_cycle,w.id
  from public.work_items w
  join public.tasks t on t.id::text=w.source_entity_id
  where w.source_entity_type='task'
    and t.source_entity_type='synthetic_local_test'
    and w.performance_credit
    and w.status not in ('Waiting','Cancelled','Closed')
  on conflict do nothing;

  select count(*) into v_cycle_items
  from private.workcenter_cycle_items m
  where m.cycle_id=v_cycle;

  if v_cycle_items < 1300 then
    raise exception 'Synthetic Work Center fixture generated only % cycle items',v_cycle_items;
  end if;

  raise notice 'SYNTHETIC_WORK_ITEMS=% CYCLE_ITEMS=%',v_work_items,v_cycle_items;
end $;
