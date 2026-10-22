create schema if not exists private;

alter function public.current_role() set schema private;
alter function public.is_cfo() set schema private;
alter function public.is_supervisor_or_delegate() set schema private;
alter function public.handle_new_user() set schema private;

revoke all on function private.handle_new_user() from public, anon, authenticated;
revoke all on function private.current_role() from public, anon;
revoke all on function private.is_cfo() from public, anon;
revoke all on function private.is_supervisor_or_delegate() from public, anon;
grant usage on schema private to authenticated;
grant execute on function private.current_role() to authenticated;
grant execute on function private.is_cfo() to authenticated;
grant execute on function private.is_supervisor_or_delegate() to authenticated;

create or replace view public.bank_liquidity with (security_invoker=true) as
select b.id,b.company,b.bank_name,b.account_name,b.account_no,b.balance,
       coalesce(sum(case when p.status not in ('مرفوض','موقوف','منفذ','مرحّل') then p.amount else 0 end),0)::numeric(18,2) as reserved_balance,
       (b.balance-coalesce(sum(case when p.status not in ('مرفوض','موقوف','منفذ','مرحّل') then p.amount else 0 end),0))::numeric(18,2) as available_balance,
       b.updated_at
from public.bank_accounts b left join public.payments p on p.bank_account_id=b.id
group by b.id;

grant select on public.bank_liquidity to authenticated;