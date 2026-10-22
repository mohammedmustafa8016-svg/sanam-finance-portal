-- Correct liquidity reservation logic.
-- A payment reserves bank liquidity only while it has not been executed.
-- Rejected, on-hold, and posted payments never reserve liquidity.

create or replace view public.bank_liquidity as
select
  b.id,
  b.company,
  b.bank_name,
  b.account_name,
  b.account_no,
  b.balance,
  coalesce(sum(
    case
      when p.executed_at is null
       and p.status not in ('مرفوض','موقوف','مرحّل')
      then p.amount
      else 0::numeric
    end
  ),0::numeric)::numeric(18,2) as reserved_balance,
  (
    b.balance - coalesce(sum(
      case
        when p.executed_at is null
         and p.status not in ('مرفوض','موقوف','مرحّل')
        then p.amount
        else 0::numeric
      end
    ),0::numeric)
  )::numeric(18,2) as available_balance,
  b.updated_at,
  b.account_type
from public.bank_accounts b
left join public.payments p on p.bank_account_id=b.id
group by b.id;
