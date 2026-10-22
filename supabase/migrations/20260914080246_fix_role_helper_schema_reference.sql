create or replace function private.is_cfo()
returns boolean
language sql
stable
security definer
set search_path = public, private
as $$
  select coalesce(private."current_role"()='CFO',false)
$$;

create or replace function private.is_supervisor_or_delegate()
returns boolean
language sql
stable
security definer
set search_path = public, private
as $$
  select coalesce(private."current_role"()='Supervisor',false) or exists(
    select 1
    from public.leave_delegations ld
    join public.profiles p on p.id=ld.absent_user_id
    where ld.substitute_user_id=auth.uid()
      and p.role='Supervisor'
      and ld.active=true
      and current_date between ld.date_from and ld.date_to
  )
$$;