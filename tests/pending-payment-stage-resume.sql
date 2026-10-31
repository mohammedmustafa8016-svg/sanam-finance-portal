-- Actual database regression on disposable users only. Harness wraps fixtures and test in rollback.
do $$begin if exists(select 1 from public.profiles where email not like '%@local.invalid') then raise exception 'LOCAL_FIXTURE_REQUIRED';end if;end$$;
create function pg_temp.pending_denied(q text,expected text) returns void language plpgsql as $$begin
 begin execute q;exception when others then if position(expected in sqlerrm)>0 then return;end if;raise exception 'WRONG_PENDING_DENIAL expected=% actual=%',expected,sqlerrm;end;
 raise exception 'PENDING_DENIAL_MISSING: %',q;
end$$;
do $$
declare cfo uuid;sup uuid;gl uuid;banker uuid;bank uuid;p uuid;ids uuid[]:='{}';i int;u record;
 before_row public.payments;after_row public.payments;original_registration timestamptz;old_version timestamptz;history jsonb;
begin
 select id into cfo from public.profiles where role='CFO';select id into sup from public.profiles where role='Supervisor';
 select id into gl from public.profiles where role='GLAccountant';select id into banker from public.profiles where role='BankAccountant';
 perform set_config('request.jwt.claim.sub',cfo::text,true);
 insert into public.bank_accounts(company,bank_name,account_name,balance) values('LOCAL-PENDING','Local bank','Test operating',10000) returning id into bank;
 for i in 1..4 loop
  insert into public.payments(due_date,company,beneficiary,amount,bank_account_id,supervisor_status,cfo_status,status,requested_by)
  values(current_date+1,'LOCAL-PENDING','Synthetic pending '||i,1000,bank,'موافق','موافق','معتمد للدفع',banker) returning id into p;
  ids=array_append(ids,p);perform set_config('request.jwt.claim.sub',banker::text,true);perform public.execute_payment(p);
  perform set_config('request.jwt.claim.sub',gl::text,true);
  if i>2 then perform public.register_payment_accounting(p);perform set_config('request.jwt.claim.sub',sup::text,true);end if;
  perform public.mark_payment_pending(p,case when i%2=0 then 'PARTIAL' else 'FULL' end,case when i%2=0 then 300 else 1000 end,
   'Synthetic source issue','Missing source documentation','Obtain document',gl,current_date+1);
 end loop;
 if (select balance from public.bank_accounts where id=bank)<>6000 then raise exception 'PENDING_INITIAL_DEBIT_WRONG';end if;

 -- All seven roles, both accounting stages; no denied attempt may change the record.
 for u in select id,role from public.profiles where active loop
  perform set_config('request.jwt.claim.sub',u.id::text,true);
  select * into before_row from public.payments where id=ids[1];
  if u.role<>'GLAccountant' then
   perform pg_temp.pending_denied(format('select public.resume_pending_payment(%L,''Resolved with source document'',%L)',ids[1],before_row.updated_at),case when u.role in ('CFO','Supervisor') then 'PENDING_REQUIRES_GL_REGISTRATION' else 'PENDING_NOT_AUTHORIZED' end);
  end if;
  select * into before_row from public.payments where id=ids[3];
  if u.role not in ('CFO','Supervisor') then
   perform pg_temp.pending_denied(format('select public.resume_pending_payment(%L,''Resolved with source document'',%L)',ids[3],before_row.updated_at),case when u.role='GLAccountant' then 'PENDING_REQUIRES_SUPERVISOR_REVIEW' else 'PENDING_NOT_AUTHORIZED' end);
  end if;
 end loop;
 perform set_config('request.jwt.claim.sub','',true);
 perform pg_temp.pending_denied(format('select public.resume_pending_payment(%L,''Resolved with source document'',now())',ids[1]),'PENDING_NOT_AUTHORIZED');
 perform set_config('request.jwt.claim.sub',sup::text,true);
 select * into before_row from public.payments where id=ids[3];old_version=before_row.updated_at;
 perform pg_temp.pending_denied(format('select public.resume_pending_payment(%L,''short'',%L)',ids[3],old_version),'PENDING_RESOLUTION_NOTE_REQUIRED');
 perform pg_temp.pending_denied(format('select public.resume_pending_payment(%L,''Resolved with source document'',null)',ids[3]),'PENDING_VERSION_REQUIRED');
 perform public.update_pending_payment_followup(ids[3],'Obtain corrected invoice',gl,current_date+2,'Reassigned for source correction',old_version);
 select * into after_row from public.payments where id=ids[3];
 if after_row.amount<>before_row.amount or after_row.pending_amount<>before_row.pending_amount or after_row.status<>before_row.status then raise exception 'FOLLOWUP_CHANGED_FINANCIAL_STATE';end if;
 perform pg_temp.pending_denied(format('select public.resume_pending_payment(%L,''Resolved with source document'',%L)',ids[3],old_version),'PENDING_STALE_RECORD_REFRESH');
 perform pg_temp.pending_denied(format('select public.update_pending_payment_followup(%L,''Review documents'',%L,current_date+2,''Changed to invalid owner'',%L)',ids[3],(select id from public.profiles where role='Viewer'),after_row.updated_at),'PENDING_ACTIVE_FINANCE_OWNER_REQUIRED');

 -- Full and partial holds resume without changing the total, original execution or prior registration.
 for i in 1..4 loop
  p=ids[i];select * into before_row from public.payments where id=p;
  perform set_config('request.jwt.claim.sub',case when i<=2 then gl::text when i=3 then sup::text else cfo::text end,true);
  after_row=public.resume_pending_payment(p,'Source issue resolved; invoice verified',before_row.updated_at);
  if after_row.status<>'تم التسجيل' or after_row.pending_amount<>0 or after_row.registered_amount<>1000 or after_row.posted_at is not null then raise exception 'PENDING_WRONG_RESUME_STATE';end if;
  if after_row.executed_at is distinct from before_row.executed_at or after_row.executed_by is distinct from before_row.executed_by or after_row.amount<>before_row.amount then raise exception 'PENDING_EXECUTION_OR_TOTAL_CHANGED';end if;
  if i>2 and (after_row.accounting_registered_at is distinct from before_row.accounting_registered_at or after_row.accounting_registered_by is distinct from before_row.accounting_registered_by) then raise exception 'PENDING_ORIGINAL_REGISTRATION_OVERWRITTEN';end if;
  if i<=2 and after_row.accounting_registered_by<>gl then raise exception 'PENDING_REGISTRAR_WRONG';end if;
  perform pg_temp.pending_denied(format('select public.resume_pending_payment(%L,''Duplicate click should be refused'',%L)',p,before_row.updated_at),'PENDING_STALE_RECORD_REFRESH');
  if not exists(select 1 from public.audit_log where entity_id=p::text and action='PAYMENT_PENDING_RESOLVED' and (details->>'previous_pending_amount')::numeric=before_row.pending_amount and details->>'automatic_posting'='false') then raise exception 'PENDING_RESOLUTION_AUDIT_MISSING';end if;
 end loop;
 if (select balance from public.bank_accounts where id=bank)<>6000 or (select count(*) from public.payment_bank_balance_effects where payment_id=any(ids))<>4 then raise exception 'PENDING_DOUBLE_BANK_EFFECT';end if;

 -- A second hold is a distinct auditable cycle; final posting remains a separate action.
 perform set_config('request.jwt.claim.sub',sup::text,true);
 perform public.mark_payment_pending(ids[3],'PARTIAL',200,'Second independent issue','Second source document','Review second issue',gl,current_date+2);
 select * into before_row from public.payments where id=ids[3];
 perform set_config('request.jwt.claim.sub',gl::text,true);
 perform pg_temp.pending_denied(format('select public.resolve_payment_pending_and_register(%L,''Legacy GL must not bypass stage'')',ids[3]),'PENDING_REQUIRES_SUPERVISOR_REVIEW');
 perform set_config('request.jwt.claim.sub',cfo::text,true);
 perform public.resume_pending_payment(ids[3],'Second source issue resolved and verified',before_row.updated_at);
 history=public.get_pending_payment_history(ids[3]);
 if jsonb_array_length(history)<>5 then raise exception 'PENDING_HISTORY_CYCLES_MISSING: %',history;end if;
 perform public.supervisor_finalize_registered_payment(ids[3],'Posted');
 select * into after_row from public.payments where id=ids[3];
 perform pg_temp.pending_denied(format('select public.resume_pending_payment(%L,''Cannot reopen a posted payment'',%L)',ids[3],after_row.updated_at),'PAYMENT_IS_NOT_ACTIVE_PENDING');
 perform set_config('request.jwt.claim.sub',(select id::text from public.profiles where role='Viewer'),true);
 perform pg_temp.pending_denied(format('select public.get_pending_payment_history(%L)',ids[3]),'PENDING_NOT_AUTHORIZED');
 perform set_config('request.jwt.claim.sub',cfo::text,true);update public.profiles set active=false where id=gl;
 perform set_config('request.jwt.claim.sub',gl::text,true);
 perform pg_temp.pending_denied(format('select public.resume_pending_payment(%L,''Inactive users cannot resume holds'',now())',ids[1]),'PENDING_NOT_AUTHORIZED');
 if has_function_privilege('anon','public.resume_pending_payment(uuid,text,timestamptz)','EXECUTE') then raise exception 'PENDING_ANON_EXECUTE';end if;
end$$;
select 'PASS: stage-aware pending release, seven roles, full/partial holds, preserved registration/execution/bank effects, follow-up/stale protection, independent posting, repeat cycles/history, inactive and anonymous denial' as result;
