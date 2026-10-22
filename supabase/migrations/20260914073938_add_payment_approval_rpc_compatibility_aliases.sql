create or replace function public.supervisor_approve_payment(p_payment_id uuid)
returns public.payments
language sql
security definer
set search_path = public, private
as $$
  select public.approve_payment_supervisor(p_payment_id);
$$;

create or replace function public.cfo_approve_payment(p_payment_id uuid)
returns public.payments
language sql
security definer
set search_path = public, private
as $$
  select public.approve_payment_cfo(p_payment_id);
$$;

grant execute on function public.supervisor_approve_payment(uuid) to authenticated;
grant execute on function public.cfo_approve_payment(uuid) to authenticated;

notify pgrst, 'reload schema';