create or replace function public.save_enhanced_daily_plan(p_default_items jsonb default '[]'::jsonb,p_flexible_items jsonb default '[]'::jsonb)
returns jsonb
language plpgsql security definer
set search_path='public','private','pg_temp'
as $$
declare v_role text:=private.current_role(); v_default integer:=0; v_flexible integer:=0;
begin
  if v_role not in ('CFO','Supervisor') then raise exception 'Only CFO or Supervisor can manage the daily work plan'; end if;
  if coalesce(jsonb_typeof(p_default_items),'array')<>'array' or coalesce(jsonb_typeof(p_flexible_items),'array')<>'array' then raise exception 'Invalid daily plan payload'; end if;
  if jsonb_array_length(coalesce(p_default_items,'[]'::jsonb))=0 and jsonb_array_length(coalesce(p_flexible_items,'[]'::jsonb))=0 then raise exception 'Daily plan must include at least one task'; end if;
  if jsonb_array_length(coalesce(p_default_items,'[]'::jsonb))>0 then
    v_default:=public.supervisor_open_daily_plan(p_default_items);
  end if;
  if jsonb_array_length(coalesce(p_flexible_items,'[]'::jsonb))>0 then
    v_flexible:=public.save_flexible_daily_plan(p_flexible_items);
  end if;
  return jsonb_build_object('default_opened',v_default,'flexible_opened',v_flexible,'total',v_default+v_flexible);
end $$;

grant execute on function public.save_enhanced_daily_plan(jsonb,jsonb) to authenticated;
