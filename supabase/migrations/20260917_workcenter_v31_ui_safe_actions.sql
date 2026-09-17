-- Work Center V3.1: expose only actions with implemented source-safe handlers.
create or replace function public.get_work_item_actions(p_work_item_id uuid)
returns table(rule_id text,action_key text,next_status text,audit_event text,handler_key text)
language plpgsql stable security definer set search_path='public','private','pg_temp' as $$
declare w public.work_items%rowtype; v_role text:=private.current_role(); r record;
begin
 if not private.workcenter_rule_engine_enabled() then return; end if;
 select * into w from public.work_items where id=p_work_item_id;
 if not found then return; end if;
 if not (v_role in ('CFO','Supervisor') or w.assignee_id=auth.uid() or w.reviewer_id=auth.uid()) then return; end if;
 for r in select distinct action_key from public.workcenter_action_rules where active=true and handler_key<>'SOURCE_GUARDED' loop
   if exists(select 1 from private.resolve_workcenter_rule(p_work_item_id,r.action_key,auth.uid(),v_role) z where z.allowed and z.handler_key<>'SOURCE_GUARDED') then
     return query select z.rule_id,z.action_key,z.next_status,z.audit_event,z.handler_key
       from private.resolve_workcenter_rule(p_work_item_id,r.action_key,auth.uid(),v_role) z
       where z.allowed and z.handler_key<>'SOURCE_GUARDED' limit 1;
   end if;
 end loop;
end $$;
grant execute on function public.get_work_item_actions(uuid) to authenticated;
