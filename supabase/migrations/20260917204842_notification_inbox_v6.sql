-- Recipient-scoped inbox; history is retained and read state never changes task state.
create function public.get_notification_inbox_v6(p_scope text default 'current',p_unread_only boolean default false,p_limit integer default 30,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path=public,private,pg_temp as $$
declare uid uuid:=auth.uid(); v_cycle_id uuid; cycle_start timestamptz; result jsonb;
begin
 if uid is null or private.current_role() is null then raise exception 'NOT_AUTHORIZED'; end if;
 if p_scope is null or p_scope not in ('current','history') then raise exception 'INVALID_SCOPE'; end if;
 select id,started_at into v_cycle_id,cycle_start from private.workcenter_cycles where active;
 with owned as (
   select n.*, n.created_at>=cycle_start and (n.task_id is null or exists(
     select 1 from private.workcenter_cycle_items m join public.work_items w on w.id=m.work_item_id
     where m.cycle_id=v_cycle_id and w.source_entity_type='task' and w.source_entity_id=n.task_id::text
   )) as in_cycle
   from public.task_notifications n where n.user_id=uid
 ), scoped as (
   select * from owned where case when p_scope='current' then coalesce(in_cycle,false) else not coalesce(in_cycle,false) end
 ), filtered as (
   select * from scoped where not coalesce(p_unread_only,false) or read_at is null
 ), page as (
   select id,task_id,notification_type,title,message,read_at,created_at from filtered
   order by created_at desc,id desc limit least(greatest(coalesce(p_limit,30),1),100) offset greatest(coalesce(p_offset,0),0)
 ) select jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(p) order by created_at desc,id desc) from page p),'[]'::jsonb),
   'total',(select count(*) from filtered),'unread',(select count(*) from scoped where read_at is null),
   'scope',p_scope,'cycle_started_at',cycle_start) into result;
 return result;
end $$;
revoke all on function public.get_notification_inbox_v6(text,boolean,integer,integer) from public,anon;
grant execute on function public.get_notification_inbox_v6(text,boolean,integer,integer) to authenticated;

