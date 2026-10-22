-- CFO-only hard deletion from operational task tables. A complete audit snapshot is retained.
create function public.delete_finance_task_cfo_v7(p_task_id uuid,p_confirmation_name text,p_reason text)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare
 actor uuid:=auth.uid(); actor_role text:=private.current_role(); t public.tasks%rowtype;
 item_ids uuid[]; item_count integer:=0; audit_id bigint;
 snapshot jsonb;
begin
 if actor is null or actor_role is distinct from 'CFO' then raise exception 'CFO_ONLY'; end if;
 if p_task_id is null then raise exception 'TASK_ID_REQUIRED'; end if;
 if length(trim(coalesce(p_reason,'')))<10 then raise exception 'DELETE_REASON_MIN_10'; end if;
 select * into t from public.tasks where id=p_task_id for update;
 if not found then raise exception 'TASK_NOT_FOUND'; end if;
 if trim(coalesce(p_confirmation_name,'')) is distinct from t.name then raise exception 'CONFIRMATION_NAME_MISMATCH'; end if;

 select coalesce(array_agg(w.id),'{}'::uuid[]) into item_ids
 from public.work_items w where w.source_entity_type='task' and w.source_entity_id=t.id::text;
 item_count:=coalesce(array_length(item_ids,1),0);
 snapshot:=jsonb_build_object(
   'task',to_jsonb(t),'reason',trim(p_reason),'deleted_at',clock_timestamp(),
   'related_counts',jsonb_build_object(
     'work_items',item_count,
     'activity_events',(select count(*) from public.task_activity_events where task_id=t.id),
     'comments',(select count(*) from public.task_comments where task_id=t.id),
     'extension_requests',(select count(*) from public.task_extension_requests where task_id=t.id),
     'notifications',(select count(*) from public.task_notifications where task_id=t.id),
     'imprest_settlements',(select count(*) from public.imprest_settlements where task_id=t.id)
   ),
   'comments',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at) from public.task_comments x where x.task_id=t.id),'[]'::jsonb),
   'activity',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at) from public.task_activity_events x where x.task_id=t.id),'[]'::jsonb),
   'extensions',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at) from public.task_extension_requests x where x.task_id=t.id),'[]'::jsonb),
   'work_items',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at) from public.work_items x where x.id=any(item_ids)),'[]'::jsonb)
 );
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details)
 values(actor,'CFO_DELETE_TASK','task',t.id::text,snapshot) returning id into audit_id;

 if item_count>0 then
   delete from private.workcenter_cycle_items where work_item_id=any(item_ids);
   delete from public.work_items where id=any(item_ids);
 end if;
 delete from public.tasks where id=t.id;
 if found then
   return jsonb_build_object('ok',true,'task_id',t.id,'task_name',t.name,'previous_status',t.status,'audit_id',audit_id,'deleted_work_items',item_count);
 end if;
 raise exception 'TASK_DELETE_FAILED';
end $$;
revoke all on function public.delete_finance_task_cfo_v7(uuid,text,text) from public,anon;
grant execute on function public.delete_finance_task_cfo_v7(uuid,text,text) to authenticated;

