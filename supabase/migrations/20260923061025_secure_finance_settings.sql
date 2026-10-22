-- Critical security hardening for public.finance_settings.
-- The portal does not require direct client access to this table.
-- SECURITY DEFINER functions owned by postgres continue to read it without FORCE RLS.

alter table public.finance_settings enable row level security;

revoke all on table public.finance_settings from public;
revoke all on table public.finance_settings from anon;
revoke all on table public.finance_settings from authenticated;

drop policy if exists finance_settings_deny_direct_access on public.finance_settings;
create policy finance_settings_deny_direct_access
on public.finance_settings
as restrictive
for all
to public
using (false)
with check (false);
