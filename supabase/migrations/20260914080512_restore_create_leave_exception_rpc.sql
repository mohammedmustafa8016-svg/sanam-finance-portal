create or replace function public.create_leave_exception(
  p_absent_user uuid,
  p_substitute_user uuid,
  p_from date,
  p_to date,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_leave_id uuid;
begin
  if not private.is_cfo() then
    raise exception 'Only CFO can create leave exceptions';
  end if;
  if p_absent_user is null or p_substitute_user is null or p_from is null or p_to is null then
    raise exception 'Missing leave delegation data';
  end if;
  if p_absent_user = p_substitute_user then
    raise exception 'Substitute must be a different user';
  end if;
  if p_to < p_from then
    raise exception 'Leave end date cannot be before start date';
  end if;

  insert into public.leave_delegations(absent_user_id,substitute_user_id,date_from,date_to,notes,active,created_by)
  values(p_absent_user,p_substitute_user,p_from,p_to,p_notes,true,auth.uid())
  returning id into v_leave_id;

  insert into public.exceptions(kind,type,severity,owner_id,detail,status,leave_delegation_id,created_by)
  values('leave','إجازة موظف + نقل صلاحيات','متوسط',p_absent_user,p_notes,'مفتوح',v_leave_id,auth.uid());

  return v_leave_id;
end;
$$;

grant execute on function public.create_leave_exception(uuid,uuid,date,date,text) to authenticated;