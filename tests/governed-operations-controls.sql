-- The harness supplies synthetic local users and wraps all effects in rollback.
select set_config('request.jwt.claim.sub',(select id::text from public.profiles where role='CFO' and active limit 1),true);
insert into public.bank_accounts(id,company,bank_name,account_name)
values('83000000-0000-4000-8000-000000000001','LOCAL-BC-CONTROL','Local Test','Operations');
set local role authenticated;
do $$
declare r jsonb; p uuid; result jsonb;
begin
 r=public.import_bc_control_file('LOCAL-BC-CONTROL','payable','synthetic.csv',
 '[{"source_id":"BC-LOCAL-1","amount":1200.25,"currency":"SAR","posting_date":"2026-10-31","due_date":"2026-11-01","beneficiary":"Synthetic Vendor","document_no":"INV-LOCAL"}]');
 if (r->>'inserted')::int<>1 then raise exception 'IMPORT_INSERT_FAILED'; end if;
 r=public.import_bc_control_file('LOCAL-BC-CONTROL','payable','synthetic.csv',
 '[{"source_id":"BC-LOCAL-1","amount":1200.25,"currency":"SAR","posting_date":"2026-10-31","due_date":"2026-11-01","beneficiary":"Synthetic Vendor","document_no":"INV-LOCAL"}]');
 if (r->>'unchanged')::int<>1 then raise exception 'IMPORT_NOT_IDEMPOTENT'; end if;
 p=public.request_payment_from_bc('LOCAL-BC-CONTROL','BC-LOCAL-1','83000000-0000-4000-8000-000000000001');
 begin
  perform public.request_payment_from_bc('LOCAL-BC-CONTROL','BC-LOCAL-1','83000000-0000-4000-8000-000000000001');
  raise exception 'DUPLICATE_LINK_WAS_ALLOWED';
 exception when others then
  if sqlerrm not like '%SOURCE_ALREADY_LINKED%' then raise; end if;
 end;
 result=public.check_payment_readiness(p,'rent','{"lease":"LEASE-1","invoice":"INV-LOCAL","payment_proof":"BANK-1"}','{}',true);
 if result->>'ready'<>'true' then raise exception 'READINESS_REQUIRED_DOCUMENTS_FAILED'; end if;
 result=public.check_payment_readiness(p,'rent','{"lease":"LEASE-1","invoice":"INV-LOCAL","payment_proof":"BANK-1"}','{"prepayment":true}',false);
 if result->>'ready'<>'false' or not result->'missing' ? 'benefit_period' then raise exception 'CONDITIONAL_READINESS_FAILED'; end if;
 if has_table_privilege('authenticated','public.bc_mirror_records','SELECT') then raise exception 'DIRECT_MIRROR_ACCESS'; end if;
 if has_table_privilege('authenticated','public.work_delay_attributions','UPDATE') then raise exception 'DIRECT_DELAY_ACCESS'; end if;
 if has_function_privilege('authenticated','public.seed_permissions_for_user(uuid)','EXECUTE') then raise exception 'INTERNAL_SEED_EXPOSED'; end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub',(select id::text from public.profiles where role='APAccountant' and active limit 1),true);
set local role authenticated;
do $$begin
 begin
  perform public.import_bc_control_file('LOCAL-BC-CONTROL','payable','synthetic.csv','[{"source_id":"2","amount":1,"currency":"SAR","posting_date":"2026-10-31"}]');
  raise exception 'AP_IMPORT_WAS_ALLOWED';
 exception when others then if sqlerrm not like '%NOT_AUTHORIZED%' then raise; end if;end;
 begin
  perform public.seed_permissions_for_user(auth.uid());raise exception 'SEED_EXECUTE_WAS_ALLOWED';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
select set_config('request.jwt.claim.sub',(select id::text from public.profiles where role='CFO' and active limit 1),true);
set local role authenticated;
do $$declare r jsonb; u uuid;begin
 select id into u from public.profiles where role='BankAccountant' and active limit 1;
 r=public.get_employee_performance_report_v5(u,'2026-10-01','2026-10-31');
 if not r ? 'adjusted_summary' or not r ? 'method_version' then raise exception 'PERFORMANCE_CONTRACT_MISSING'; end if;
end $$;
reset role;
select 'PASS: local Supabase import, no-double-entry link, readiness, internal grants and report contract' as result;
