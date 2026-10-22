
-- Preserve the existing finance-policy compliance counts for finance users.
-- Only add the Viewer page gate; do not change the prior counting semantics.

create or replace function public.get_finance_policy_register()
returns table(
  id uuid,policy_code text,title text,category text,purpose text,scope text,policy_text text,procedures text,
  responsibilities text,exceptions_text text,effective_date date,status text,current_version integer,
  created_at timestamptz,updated_at timestamptz,acknowledged_current boolean,acknowledged_count bigint,active_team_count bigint
)
language sql stable security definer set search_path=public,private,pg_temp as $$
with team as (select count(*)::bigint c from public.profiles where active=true),
acks as (
 select a.policy_id,a.version_no,count(distinct a.user_id)::bigint c
 from public.finance_policy_acknowledgements a join public.profiles p on p.id=a.user_id and p.active=true
 group by a.policy_id,a.version_no
)
select p.id,p.policy_code,p.title,p.category,p.purpose,p.scope,p.policy_text,p.procedures,p.responsibilities,
       p.exceptions_text,p.effective_date,p.status,p.current_version,p.created_at,p.updated_at,
       exists(select 1 from public.finance_policy_acknowledgements a
              where a.policy_id=p.id and a.user_id=auth.uid() and a.version_no=p.current_version),
       coalesce(a.c,0),team.c
from public.finance_policies p
left join acks a on a.policy_id=p.id and a.version_no=p.current_version
cross join team
where private.current_role() is not null
  and (p.status<>'Draft' or private.current_role()='CFO')
  and (private.current_role()<>'Viewer' or public.has_user_permission('page.exceptions'))
order by case p.status when 'Active' then 1 when 'Draft' then 2 when 'Suspended' then 3 else 4 end,p.category,p.policy_code;
$$;
