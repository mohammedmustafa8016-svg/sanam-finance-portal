
revoke all on table
  public.imprest_funding_requests,
  public.imprest_refunds,
  public.imprest_ledger_entries
from service_role;

grant select,insert,update,delete on table
  public.imprest_funding_requests,
  public.imprest_refunds,
  public.imprest_ledger_entries
to service_role;
