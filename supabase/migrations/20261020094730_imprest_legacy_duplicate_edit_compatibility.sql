
do $patch$
declare
  v_def text;
  v_new text;
begin
  select pg_get_functiondef(p.oid)
    into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='private'
    and p.proname='guard_imprest_duplicate'
  limit 1;

  if v_def is null then raise exception 'guard_imprest_duplicate not found'; end if;

  v_new:=replace(
    v_def,
    'if found then
    if not (',
    'if found then
    if tg_op=''UPDATE''
       and lower(regexp_replace(trim(v_duplicate.company),''\s+'','' '',''g''))
           = lower(regexp_replace(trim(old.company),''\s+'','' '',''g''))
       and upper(coalesce(v_duplicate.currency_code,''SAR''))=upper(coalesce(old.currency_code,''SAR''))
       and (
         (old.custodian_id is not null and v_duplicate.custodian_id=old.custodian_id)
         or lower(regexp_replace(trim(v_duplicate.name),''\s+'','' '',''g''))
            = lower(regexp_replace(trim(old.name),''\s+'','' '',''g''))
       ) then
      return new;
    end if;

    if not ('
  );

  if v_new=v_def then
    raise exception 'legacy duplicate edit compatibility patch made no change';
  end if;

  execute v_new;
end
$patch$;
