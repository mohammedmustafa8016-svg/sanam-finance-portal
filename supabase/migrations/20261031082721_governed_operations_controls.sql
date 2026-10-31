set local lock_timeout='3s';


-- Additive operational data. Accounting remains in Business Central.
create table public.bc_import_batches (
 id uuid primary key default gen_random_uuid(), company text not null, record_type text not null,
 file_name text not null, imported_by uuid not null references public.profiles(id),
 imported_at timestamptz not null default now(), inserted_count integer not null default 0,
 updated_count integer not null default 0, unchanged_count integer not null default 0
);
create table public.bc_mirror_records (
 company text not null, record_type text not null check(record_type in ('bank_balance','payable','posted_document')),
 source_id text not null, payload jsonb not null, batch_id uuid not null references public.bc_import_batches(id),
 imported_at timestamptz not null default now(), primary key(company,record_type,source_id)
);
create table public.readiness_policies (
 expense_type text primary key, revision integer not null default 1,
 required_documents jsonb not null, conditional_documents jsonb not null default '[]',
 warning_flags jsonb not null default '[]', updated_by uuid references public.profiles(id),
 blocking_flags jsonb not null default '[]', amount_limit numeric(18,2) check(amount_limit>0),
 updated_at timestamptz not null default now()
);
create table public.payment_readiness_assessments (
 payment_id uuid primary key references public.payments(id) on delete cascade,
 expense_type text not null references public.readiness_policies(expense_type),
 evidence jsonb not null, context jsonb not null, assessed_by uuid not null references public.profiles(id),
 assessed_at timestamptz not null default now()
);
create table public.work_delay_attributions (
 id uuid primary key default gen_random_uuid(), work_item_id uuid references public.work_items(id) on delete set null, original_work_item_id uuid not null,
 employee_id uuid not null references public.profiles(id), reason text not null
 check(reason in ('WAITING_SUPERVISOR','WAITING_MANAGEMENT','EXTERNAL_DEPENDENCY','SYSTEM_FAILURE','EMPLOYEE_DELAY')),
 starts_at timestamptz not null, ends_at timestamptz not null check(ends_at>starts_at),
 explanation text not null check(length(trim(explanation)) between 10 and 2000),
 evidence_reference text not null check(length(trim(evidence_reference)) between 3 and 500),
 requested_by uuid not null references public.profiles(id), requested_at timestamptz not null default now(),
 status text not null default 'Pending' check(status in ('Pending','Approved','Rejected')),
 decided_by uuid references public.profiles(id), decided_at timestamptz, decision_note text,
 check((status='Pending' and decided_by is null and decided_at is null) or
       (status<>'Pending' and decided_by is not null and decided_at is not null))
);
create index work_delay_attributions_item_status on public.work_delay_attributions(work_item_id,status);
create index work_delay_attributions_employee on public.work_delay_attributions(employee_id,requested_at desc);
create index work_delay_attributions_pending on public.work_delay_attributions(requested_at) where status='Pending';
create index bc_import_batches_latest on public.bc_import_batches(company,record_type,imported_at desc,id desc);
create index bc_mirror_records_batch on public.bc_mirror_records(batch_id);
create index portal_client_error_actor_time on public.audit_log(actor_id,created_at desc) where action='PORTAL_CLIENT_ERROR';
create table public.bc_payment_links (
 company text not null, source_id text not null, payment_id uuid unique references public.payments(id) on delete set null,
 source_snapshot jsonb not null, linked_by uuid not null references public.profiles(id),linked_at timestamptz not null default now(),
 document_no text not null, beneficiary text not null,
 primary key(company,source_id)
);
create unique index bc_payment_links_invoice on public.bc_payment_links(company,document_no,beneficiary) where document_no<>'';
alter table public.bc_payment_links enable row level security;
revoke all on public.bc_payment_links from public,anon,authenticated;

alter table public.bc_import_batches enable row level security;
alter table public.bc_mirror_records enable row level security;
alter table public.readiness_policies enable row level security;
alter table public.payment_readiness_assessments enable row level security;
alter table public.work_delay_attributions enable row level security;
revoke all on public.bc_import_batches,public.bc_mirror_records,public.readiness_policies,
 public.payment_readiness_assessments,public.work_delay_attributions from public,anon,authenticated;

insert into public.readiness_policies(expense_type,required_documents,conditional_documents,warning_flags) values
 ('rent','["lease","invoice","payment_proof"]','[{"flag":"prepayment","requires":["benefit_period"]},{"flag":"renewal","requires":["renewal"]}]','["contract_expiring","beneficiary_mismatch","amount_variance"]'),
 ('payroll','["approved_payroll","bank_transfer","approval"]','[{"flag":"exceptional_pay","requires":["exception_approval"]},{"flag":"termination","requires":["settlement"]}]','["duplicate_period","inactive_employee","amount_variance"]'),
 ('purchases','["purchase_approval","invoice","receipt"]','[{"flag":"above_limit","requires":["purchase_order","quotations"]},{"flag":"inventory","requires":["goods_receipt"]}]','["new_supplier","price_variance","duplicate_document"]'),
 ('contractors','["contract","certified_progress","invoice","completion_approval"]','[{"flag":"prepayment","requires":["advance_approval"]},{"flag":"retention","requires":["retention_schedule"]}]','["contract_overrun","duplicate_document"]'),
 ('maintenance','["invoice","work_order","asset_reference"]','[{"flag":"above_limit","requires":["quotations","approval"]},{"flag":"accident","requires":["accident_report"]}]','["repeat_repair","inactive_asset"]'),
 ('fuel','["invoice","vehicle_or_project"]','[{"flag":"monthly_account","requires":["detail_statement"]},{"flag":"above_limit","requires":["approval"]}]','["high_consumption","unregistered_vehicle"]'),
 ('professional','["agreement","invoice","service_evidence"]','[{"flag":"above_limit","requires":["management_approval"]},{"flag":"foreign_supplier","requires":["tax_review"]}]','["expired_contract","unclear_scope"]'),
 ('travel','["travel_approval","invoice","traveller_and_purpose"]','[{"flag":"above_limit","requires":["exception_approval"]},{"flag":"cancellation","requires":["justification"]}]','["outside_mission","non_employee"]'),
 ('imprest','["settlement","invoices","settlement_approval"]','[{"flag":"missing_invoice","requires":["exception_approval","justification"]}]','["duplicate_document","old_imprest"]'),
 ('assets','["purchase_approval","invoice","receipt","asset_location","custodian"]','[{"flag":"capitalized","requires":["asset_id","in_service_date"]}]','["classification_review","duplicate_asset"]'),
 ('government','["official_demand","calculation_basis","payment_proof"]','[{"flag":"penalty","requires":["explanation","approval"]}]','["period_mismatch","amount_variance"]'),
 ('technology','["invoice","subscription_details","service_name"]','[{"flag":"annual","requires":["benefit_period"]},{"flag":"perpetual_license","requires":["classification_review"]}]','["duplicate_subscription","inactive_users"]');

create function public.import_bc_control_file(p_company text,p_record_type text,p_file_name text,p_rows jsonb)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare b uuid; r jsonb; prior jsonb; n_insert int:=0; n_update int:=0; n_same int:=0; cleaned jsonb;
begin
 if auth.uid() is null or coalesce(private.current_role(),'') not in ('CFO','Supervisor','BankAccountant') then raise exception 'NOT_AUTHORIZED'; end if;
 if p_record_type not in ('bank_balance','payable','posted_document') or p_record_type is null then raise exception 'INVALID_RECORD_TYPE'; end if;
 if not coalesce(public.has_user_permission(case when p_record_type='bank_balance' then 'data.bank_balances' else 'page.payments' end),false) then raise exception 'NOT_AUTHORIZED'; end if;
 if length(trim(coalesce(p_company,''))) not between 1 and 200 or length(trim(coalesce(p_file_name,''))) not between 1 and 255 then raise exception 'INVALID_SOURCE'; end if;
 if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) not between 1 and 5000 then raise exception 'INVALID_ROWS'; end if;
 if (select count(*) from jsonb_array_elements(p_rows) x) <> (select count(distinct trim(x->>'source_id')) from jsonb_array_elements(p_rows) x) then raise exception 'DUPLICATE_SOURCE_ID'; end if;
 -- Serialize imports for one company/type. Every batch is atomic, including invalid later rows.
 perform pg_advisory_xact_lock(hashtextextended(trim(p_company)||':'||p_record_type,0));
 insert into public.bc_import_batches(company,record_type,file_name,imported_by)
 values(trim(p_company),p_record_type,trim(p_file_name),auth.uid()) returning id into b;
 for r in select value from jsonb_array_elements(p_rows) loop
   if jsonb_typeof(r) is distinct from 'object' or length(trim(coalesce(r->>'source_id',''))) not between 1 and 200
    or jsonb_typeof(r->'amount') is distinct from 'number' or abs((r->>'amount')::numeric)>9999999999999999.99
    or (r->>'amount')::numeric<>round((r->>'amount')::numeric,2)
    or coalesce(r->>'currency','') !~ '^[A-Z]{3}$'
    or coalesce(r->>'posting_date','') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'INVALID_ROW'; end if;
   perform (r->>'posting_date')::date;
   if nullif(r->>'due_date','') is not null then perform (r->>'due_date')::date; end if;
   cleaned=jsonb_build_object('source_id',trim(r->>'source_id'),'amount',(r->>'amount')::numeric,'currency',r->>'currency',
    'posting_date',r->>'posting_date','due_date',nullif(r->>'due_date',''),'document_no',left(coalesce(r->>'document_no',''),200),
    'beneficiary',left(coalesce(r->>'beneficiary',''),300),'description',left(coalesce(r->>'description',''),1000));
   select payload into prior from public.bc_mirror_records where company=trim(p_company) and record_type=p_record_type and source_id=cleaned->>'source_id';
   if not found then n_insert=n_insert+1; elsif prior=cleaned then n_same=n_same+1; continue; else n_update=n_update+1; end if;
   insert into public.bc_mirror_records(company,record_type,source_id,payload,batch_id)
   values(trim(p_company),p_record_type,cleaned->>'source_id',cleaned,b)
   on conflict(company,record_type,source_id) do update set payload=excluded.payload,batch_id=excluded.batch_id,imported_at=now();
   insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'BC_MIRROR_RECORD_CHANGED','bc_import_batch',b::text,jsonb_build_object('company',trim(p_company),'record_type',p_record_type,'source_id',cleaned->>'source_id','before',prior,'after',cleaned));
 end loop;
 update public.bc_import_batches set inserted_count=n_insert,updated_count=n_update,unchanged_count=n_same where id=b;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'BC_FILE_IMPORTED','bc_import_batch',b::text,jsonb_build_object('company',trim(p_company),'type',p_record_type,'inserted',n_insert,'updated',n_update,'unchanged',n_same));
 return jsonb_build_object('batch_id',b,'inserted',n_insert,'updated',n_update,'unchanged',n_same);
end $$;

create function public.get_bc_control_records(p_company text,p_record_type text,p_limit int default 100,p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path=public,private,pg_temp as $$
begin
 if auth.uid() is null or coalesce(private.current_role(),'') not in ('CFO','Supervisor','BankAccountant','GLAccountant','APAccountant') then raise exception 'NOT_AUTHORIZED'; end if;
 if p_record_type is null or p_record_type not in ('bank_balance','payable','posted_document') or not coalesce(public.has_user_permission(case when p_record_type='bank_balance' then 'data.bank_balances' else 'page.payments' end),false) then raise exception 'NOT_AUTHORIZED'; end if;
 return jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(x)) from (select company,record_type,source_id,payload,imported_at from public.bc_mirror_records where company=p_company and record_type=p_record_type order by source_id limit least(greatest(coalesce(p_limit,100),1),500) offset greatest(coalesce(p_offset,0),0)) x),'[]'::jsonb),
 'total',(select count(*) from public.bc_mirror_records where company=p_company and record_type=p_record_type),
 'last_batch',(select to_jsonb(x) from (select id,file_name,imported_at,inserted_count,updated_count,unchanged_count from public.bc_import_batches where company=p_company and record_type=p_record_type order by imported_at desc,id desc limit 1) x));
end $$;

create function public.request_payment_from_bc(p_company text,p_source_id text,p_bank_account_id uuid,p_due_date date default null,p_priority text default 'عادي')
returns uuid language plpgsql security definer set search_path=public,private,pg_temp as $$
declare source jsonb; result uuid;
begin
 if auth.uid() is null or coalesce(private.current_role(),'') not in ('CFO','Supervisor','BankAccountant','APAccountant') or not coalesce(public.has_user_permission('page.payments'),false) then raise exception 'NOT_AUTHORIZED'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_company||':payable',0));
 select payload into source from public.bc_mirror_records where company=p_company and record_type='payable' and source_id=p_source_id;
 if not found then raise exception 'BC_SOURCE_NOT_FOUND'; end if;
 if exists(select 1 from public.bc_payment_links where company=p_company and source_id=p_source_id) then raise exception 'SOURCE_ALREADY_LINKED'; end if;
 if coalesce(source->>'document_no','')<>'' and exists(select 1 from public.bc_payment_links where company=p_company and document_no=source->>'document_no' and beneficiary=source->>'beneficiary') then raise exception 'DUPLICATE_INVOICE_LINK'; end if;
 if source->>'currency'<>'SAR' then raise exception 'NON_SAR_PAYMENT_REQUIRES_CURRENCY_WORKFLOW'; end if;
 if (source->>'amount')::numeric<=0 or length(trim(coalesce(source->>'beneficiary','')))=0 then raise exception 'INVALID_PAYABLE_SOURCE'; end if;
 if not exists(select 1 from public.bank_accounts where id=p_bank_account_id and company=p_company) then raise exception 'BANK_COMPANY_MISMATCH'; end if;
 if p_priority is null or p_priority not in ('عادي','عاجل','حرج') then raise exception 'INVALID_PRIORITY'; end if;
 if coalesce(nullif(source->>'due_date','')::date,p_due_date) is null then raise exception 'DUE_DATE_REQUIRED'; end if;
 insert into public.payments(due_date,company,beneficiary,amount,bank_account_id,priority,documents_status,purpose,requested_by)
 values(coalesce(nullif(source->>'due_date','')::date,p_due_date),p_company,source->>'beneficiary',(source->>'amount')::numeric,p_bank_account_id,p_priority,'ناقصة',
 'BC '||coalesce(source->>'document_no',p_source_id)||' — '||coalesce(source->>'description',''),auth.uid()) returning id into result;
 insert into public.bc_payment_links(company,source_id,payment_id,source_snapshot,linked_by,document_no,beneficiary) values(p_company,p_source_id,result,source,auth.uid(),coalesce(source->>'document_no',''),source->>'beneficiary');
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'PAYMENT_REQUESTED_FROM_BC','payment',result::text,jsonb_build_object('company',p_company,'source_id',p_source_id,'source_snapshot',source));
 return result;
end $$;

create function public.get_readiness_policies() returns jsonb language plpgsql stable security definer set search_path=public,private,pg_temp as $$
begin
 if auth.uid() is null or coalesce(private.current_role(),'') not in ('CFO','Supervisor','BankAccountant','APAccountant','GLAccountant') or not coalesce(public.has_user_permission('page.payments'),false) then raise exception 'NOT_AUTHORIZED'; end if;
 return coalesce((select jsonb_agg(to_jsonb(p) order by expense_type) from public.readiness_policies p),'[]'::jsonb);
end $$;

create function public.set_readiness_policy(p_expense_type text,p_required jsonb,p_conditional jsonb,p_warnings jsonb,p_revision int,p_blocking jsonb default '[]',p_amount_limit numeric default null)
returns void language plpgsql security definer set search_path=public,private,pg_temp as $$
declare x jsonb;
begin
 if auth.uid() is null or coalesce(private.current_role(),'')<>'CFO' then raise exception 'NOT_AUTHORIZED'; end if;
 if jsonb_typeof(p_required) is distinct from 'array' or jsonb_typeof(p_conditional) is distinct from 'array' or jsonb_typeof(p_warnings) is distinct from 'array' or jsonb_typeof(p_blocking) is distinct from 'array'
 or jsonb_array_length(p_required)>30 or jsonb_array_length(p_conditional)>20 or jsonb_array_length(p_warnings)>30 or jsonb_array_length(p_blocking)>30 or (p_amount_limit is not null and (p_amount_limit<=0 or p_amount_limit>9999999999999999.99)) then raise exception 'INVALID_POLICY'; end if;
 for x in select value from jsonb_array_elements(p_required||p_warnings||p_blocking) loop
   if jsonb_typeof(x)<>'string' or (x#>>'{}') !~ '^[a-z][a-z0-9_]{0,59}$' then raise exception 'INVALID_POLICY_KEY'; end if;
 end loop;
 for x in select value from jsonb_array_elements(p_conditional) loop
  if jsonb_typeof(x)<>'object' or coalesce(x->>'flag','') !~ '^[a-z][a-z0-9_]{0,59}$' or jsonb_typeof(x->'requires') is distinct from 'array' or jsonb_array_length(x->'requires')>30
    or exists(select 1 from jsonb_array_elements(x->'requires') z where jsonb_typeof(z)<>'string' or (z#>>'{}') !~ '^[a-z][a-z0-9_]{0,59}$') then raise exception 'INVALID_POLICY_CONDITION'; end if;
 end loop;
 update public.readiness_policies set required_documents=p_required,conditional_documents=p_conditional,warning_flags=p_warnings,blocking_flags=p_blocking,amount_limit=p_amount_limit,revision=revision+1,updated_by=auth.uid(),updated_at=now() where expense_type=p_expense_type and revision=p_revision;
 if not found then raise exception 'POLICY_REVISION_CONFLICT'; end if;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'READINESS_POLICY_UPDATED','readiness_policy',p_expense_type,jsonb_build_object('previous_revision',p_revision,'required',p_required,'conditional',p_conditional,'warnings',p_warnings,'blocking',p_blocking,'amount_limit',p_amount_limit));
end $$;

create function public.check_payment_readiness(p_payment_id uuid,p_expense_type text,p_evidence jsonb,p_context jsonb,p_save boolean default false)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare pol public.readiness_policies; pay public.payments; req jsonb; key text; cond jsonb; missing jsonb:='[]'; warnings jsonb:='[]';
begin
 if auth.uid() is null or coalesce(private.current_role(),'') not in ('CFO','Supervisor','BankAccountant','APAccountant','GLAccountant') or not coalesce(public.has_user_permission('page.payments'),false) then raise exception 'NOT_AUTHORIZED'; end if;
 if jsonb_typeof(p_evidence) is distinct from 'object' or jsonb_typeof(p_context) is distinct from 'object' or length(p_evidence::text)>20000 or length(p_context::text)>10000 then raise exception 'INVALID_EVIDENCE'; end if;
 if p_save is null then raise exception 'INVALID_SAVE_FLAG'; end if;
 if p_save and private.current_role()='GLAccountant' then raise exception 'NOT_AUTHORIZED'; end if;
 select * into pay from public.payments where id=p_payment_id;
 if not found then raise exception 'PAYMENT_NOT_FOUND'; end if;
 select * into pol from public.readiness_policies where expense_type=p_expense_type;
 if not found then raise exception 'POLICY_NOT_FOUND'; end if;
 if pol.amount_limit is not null then p_context=p_context||jsonb_build_object('above_limit',pay.amount>pol.amount_limit); end if;
 req=pol.required_documents;
 for cond in select value from jsonb_array_elements(pol.conditional_documents) loop
  if p_context->(cond->>'flag')='true'::jsonb then req=req||(cond->'requires'); end if;
 end loop;
 for key in select distinct value from jsonb_array_elements_text(req) loop
  if jsonb_typeof(p_evidence->key) is distinct from 'string' or length(trim(coalesce(p_evidence->>key,'')))=0 then missing=missing||to_jsonb(key); end if;
 end loop;
 if pay.amount<=0 then missing=missing||'"positive_amount"'::jsonb; end if;
 if length(trim(coalesce(pay.company,'')))=0 then missing=missing||'"company"'::jsonb; end if;
 if p_context->'contract_expired'='true'::jsonb then missing=missing||'"valid_contract"'::jsonb; end if;
 if p_context->'duplicate_invoice'='true'::jsonb then missing=missing||'"unique_invoice"'::jsonb; end if;
 if nullif(trim(p_evidence->>'invoice'),'') is not null then
  if p_save then perform pg_advisory_xact_lock(hashtextextended(pay.company||':'||pay.beneficiary||':'||(p_evidence->>'invoice'),0)); end if;
  if exists(select 1 from public.payment_readiness_assessments a join public.payments p on p.id=a.payment_id where a.payment_id<>p_payment_id and p.company=pay.company and p.beneficiary=pay.beneficiary and a.evidence->>'invoice'=p_evidence->>'invoice') then missing=missing||'"unique_invoice"'::jsonb; end if;
 end if;
 for key in select value from jsonb_array_elements_text(pol.blocking_flags) loop
   if p_context->key='true'::jsonb then missing=missing||to_jsonb(key); end if;
 end loop;
 for key in select value from jsonb_array_elements_text(pol.warning_flags) loop
   if p_context->key='true'::jsonb and not pol.blocking_flags ? key then warnings=warnings||to_jsonb(key); end if;
 end loop;
 if p_save then
  insert into public.payment_readiness_assessments(payment_id,expense_type,evidence,context,assessed_by) values(p_payment_id,p_expense_type,p_evidence,p_context,auth.uid())
  on conflict(payment_id) do update set expense_type=excluded.expense_type,evidence=excluded.evidence,context=excluded.context,assessed_by=excluded.assessed_by,assessed_at=now();
  insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'PAYMENT_READINESS_ASSESSED','payment',p_payment_id::text,jsonb_build_object('expense_type',p_expense_type,'policy_revision',pol.revision,'missing',missing,'warnings',warnings,'evidence',p_evidence,'context',p_context));
 end if;
 return jsonb_build_object('ready',jsonb_array_length(missing)=0,'missing',missing,'warnings',warnings,'policy_revision',pol.revision,'required',req,'checked_at',now(),'evidence_source','user_attested_references','scope','operational_readiness_only');
end $$;

create function public.get_payment_readiness_assessment(p_payment_id uuid) returns jsonb language plpgsql stable security definer set search_path=public,private,pg_temp as $$
begin
 if auth.uid() is null or coalesce(private.current_role(),'') not in ('CFO','Supervisor','BankAccountant','APAccountant','GLAccountant') or not coalesce(public.has_user_permission('page.payments'),false) then raise exception 'NOT_AUTHORIZED'; end if;
 return (select to_jsonb(a) from public.payment_readiness_assessments a where payment_id=p_payment_id);
end $$;

create function public.request_work_delay_attribution(p_work_item_id uuid,p_reason text,p_starts_at timestamptz,p_ends_at timestamptz,p_explanation text,p_evidence_reference text)
returns uuid language plpgsql security definer set search_path=public,private,pg_temp as $$
declare w public.work_items; result uuid; employee uuid;
begin
 if auth.uid() is null or coalesce(private.current_role(),'') not in ('CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant') or not coalesce(public.has_user_permission('page.workcenter'),false) then raise exception 'NOT_AUTHORIZED'; end if;
 select * into w from public.work_items where id=p_work_item_id;
 if not found then raise exception 'WORK_ITEM_NOT_FOUND'; end if;
 employee=coalesce(w.completed_by,w.assignee_id);
 if employee is null or (employee<>auth.uid() and private.current_role() not in ('CFO','Supervisor')) then raise exception 'NOT_AUTHORIZED'; end if;
 if p_starts_at is null or p_ends_at is null or p_starts_at<coalesce(w.started_at,w.created_at) or p_ends_at>coalesce(w.completed_at,now()) or p_ends_at<=p_starts_at then raise exception 'INVALID_DELAY_INTERVAL'; end if;
 insert into public.work_delay_attributions(work_item_id,original_work_item_id,employee_id,reason,starts_at,ends_at,explanation,evidence_reference,requested_by)
 values(w.id,w.id,employee,p_reason,p_starts_at,p_ends_at,p_explanation,p_evidence_reference,auth.uid()) returning id into result;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'DELAY_ATTRIBUTION_REQUESTED','work_delay',result::text,jsonb_build_object('work_item_id',w.id,'employee_id',employee,'reason',p_reason,'starts_at',p_starts_at,'ends_at',p_ends_at,'explanation',p_explanation,'evidence_reference',p_evidence_reference));
 return result;
end $$;

create function public.decide_work_delay_attribution(p_id uuid,p_approved boolean,p_note text) returns void language plpgsql security definer set search_path=public,private,pg_temp as $$
declare r public.work_delay_attributions;
begin
 if auth.uid() is null or coalesce(private.current_role(),'') not in ('CFO','Supervisor') or not coalesce(public.has_user_permission('page.performance'),false) then raise exception 'NOT_AUTHORIZED'; end if;
 select * into r from public.work_delay_attributions where id=p_id for update;
 if not found then raise exception 'DELAY_NOT_FOUND'; end if;
 if auth.uid() in (r.requested_by,r.employee_id) then raise exception 'SELF_APPROVAL_DENIED'; end if;
 if r.status<>'Pending' then raise exception 'ALREADY_DECIDED'; end if;
 if p_approved is null or length(trim(coalesce(p_note,''))) not between 10 and 2000 then raise exception 'DECISION_NOTE_REQUIRED'; end if;
 update public.work_delay_attributions set status=case when p_approved then 'Approved' else 'Rejected' end,decided_by=auth.uid(),decided_at=now(),decision_note=p_note where id=p_id;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'DELAY_ATTRIBUTION_DECIDED','work_delay',p_id::text,jsonb_build_object('approved',p_approved,'note',p_note));
end $$;

create function public.get_work_delay_attributions(p_employee_id uuid) returns jsonb language plpgsql stable security definer set search_path=public,private,pg_temp as $$
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and active) or not (auth.uid()=p_employee_id or coalesce(private.current_role(),'') in ('CFO','Supervisor')) then raise exception 'NOT_AUTHORIZED'; end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by requested_at desc) from public.work_delay_attributions x where employee_id=p_employee_id),'[]'::jsonb);
end $$;

create function public.get_employee_performance_report_v5(p_user_id uuid,p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path=public,private,pg_temp as $$
declare base jsonb; enriched jsonb; summary jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and active) or not (auth.uid()=p_user_id or coalesce(private.current_role(),'') in ('CFO','Supervisor')) then raise exception 'NOT_AUTHORIZED'; end if;
 if p_from is not null and p_to is not null and p_from>p_to then raise exception 'INVALID_REPORT_PERIOD'; end if;
 base=public.get_employee_performance_report_v4(p_user_id,p_from,p_to);
 with items as (select value as item from jsonb_array_elements(base->'items')),
 adjusted as (
 select item,
  coalesce((select sum(extract(epoch from upper(v)-lower(v))) from unnest((select range_agg(tstzrange(greatest(d.starts_at,(item->>'assigned_at')::timestamptz),least(d.ends_at,(item->>'completed_at')::timestamptz),'[)')) from public.work_delay_attributions d where d.work_item_id=(item->>'work_item_id')::uuid and d.employee_id=p_user_id and d.status='Approved' and d.reason<>'EMPLOYEE_DELAY' and d.starts_at<(item->>'completed_at')::timestamptz and d.ends_at>(item->>'assigned_at')::timestamptz)) v),0) as excluded_seconds,
  (select count(*) from public.work_delay_attributions d where d.work_item_id=(item->>'work_item_id')::uuid and d.employee_id=p_user_id and status='Pending') as pending
 from items), final as (
 select item||jsonb_build_object('excluded_seconds',excluded_seconds,'pending_delay_reviews',pending,
 'adjusted_due_at',case when nullif(item->>'due_at','') is null then null else (item->>'due_at')::timestamptz+excluded_seconds*interval '1 second' end,
 'adjusted_on_time',case when pending>0 or nullif(item->>'due_at','') is null then null else (item->>'completed_at')::timestamptz <= (item->>'due_at')::timestamptz+excluded_seconds*interval '1 second' end) as row from adjusted)
 select coalesce(jsonb_agg(row),'[]'::jsonb) into enriched from final;
 select jsonb_build_object('completed',count(*),'timed_final',count(*) filter(where value->>'adjusted_on_time' is not null),
 'on_time',count(*) filter(where value->>'adjusted_on_time'='true'),'late',count(*) filter(where value->>'adjusted_on_time'='false'),
 'pending_delay_reviews',coalesce(sum((value->>'pending_delay_reviews')::int),0),
 'excluded_seconds',coalesce(sum((value->>'excluded_seconds')::numeric),0),
 'on_time_rate',case when count(*) filter(where value->>'adjusted_on_time' is not null)=0 then null else round(100.0*count(*) filter(where value->>'adjusted_on_time'='true')/count(*) filter(where value->>'adjusted_on_time' is not null),1) end,
 'avg_quality_score',round(avg(nullif(value->>'quality_score','')::numeric),1),
 'rework_count',coalesce(sum((value->>'rework_count')::int),0)) into summary from jsonb_array_elements(enriched);
 return base||jsonb_build_object('items',enriched,'adjusted_summary',summary,'method','elapsed-time union of independently approved non-employee delay intervals; pending reviews are provisional; existing deadline extensions are already reflected in due_at','method_version',1);
end $$;

-- Internal seeding is not a client API; triggers/owners and service_role retain access.
do $$declare f record;begin
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='private' and p.proname in ('policy_snapshot','workcenter_role_family','workcenter_scope_allowed') loop
  execute format('alter function %s set search_path=public,private,pg_temp',f.oid::regprocedure);
 end loop;
end $$;

create function public.record_portal_client_error(p_code text,p_page text) returns void language plpgsql security definer set search_path=public,private,pg_temp as $$
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and active) then raise exception 'NOT_AUTHORIZED'; end if;
 if p_code is null or p_code not in ('WINDOW_ERROR','UNHANDLED_REJECTION','IMPORT_FAILED','READINESS_FAILED','REPORT_FAILED') or p_page is null or p_page not in ('dashboard','workcenter','tasks','control','workload','escalations','payments','executed','pending','posted','banks','reservev2','imprest','close','performance','ownership','exceptions','permissions','automation','audit','other') then raise exception 'INVALID_ERROR_EVENT'; end if;
 perform pg_advisory_xact_lock(hashtextextended('portal-errors:'||auth.uid()::text,0));
 if (select count(*) from public.audit_log where actor_id=auth.uid() and action='PORTAL_CLIENT_ERROR' and created_at>now()-interval '10 minutes')>=20 then return; end if;
 insert into public.audit_log(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'PORTAL_CLIENT_ERROR','portal','operations-20261031',jsonb_build_object('code',p_code,'page',p_page));
end $$;

create function public.get_operations_health() returns jsonb language plpgsql stable security definer set search_path=public,private,pg_temp as $$
begin
 if auth.uid() is null or coalesce(private.current_role(),'') not in ('CFO','Supervisor') or not coalesce(public.has_user_permission('page.automation'),false) then raise exception 'NOT_AUTHORIZED'; end if;
 return jsonb_build_object('as_of',now(),'client_errors_24h',coalesce((select jsonb_agg(to_jsonb(x)) from (select details->>'code' as code,details->>'page' as page,count(*) as count,max(created_at) as last_at from public.audit_log where action='PORTAL_CLIENT_ERROR' and created_at>now()-interval '24 hours' group by details->>'code',details->>'page') x),'[]'::jsonb),
 'pending_delay_decisions',(select count(*) from public.work_delay_attributions where status='Pending'),
 'oldest_delay_request',(select min(requested_at) from public.work_delay_attributions where status='Pending'),
 'latest_imports',coalesce((select jsonb_agg(to_jsonb(x)) from (select distinct on(company,record_type) company,record_type,imported_at,inserted_count,updated_count,unchanged_count from public.bc_import_batches order by company,record_type,imported_at desc,id desc) x),'[]'::jsonb));
end $$;
revoke all on function public.record_portal_client_error(text,text),public.get_operations_health() from public,anon;
grant execute on function public.record_portal_client_error(text,text),public.get_operations_health() to authenticated;

revoke execute on function public.seed_permissions_for_user(uuid) from public,anon,authenticated;
grant execute on function public.seed_permissions_for_user(uuid) to service_role;

revoke all on function public.request_payment_from_bc(text,text,uuid,date,text),public.import_bc_control_file(text,text,text,jsonb),public.get_bc_control_records(text,text,int,int),public.get_readiness_policies(),public.set_readiness_policy(text,jsonb,jsonb,jsonb,int,jsonb,numeric),public.check_payment_readiness(uuid,text,jsonb,jsonb,boolean),public.get_payment_readiness_assessment(uuid),public.request_work_delay_attribution(uuid,text,timestamptz,timestamptz,text,text),public.decide_work_delay_attribution(uuid,boolean,text),public.get_work_delay_attributions(uuid),public.get_employee_performance_report_v5(uuid,date,date) from public,anon;
grant execute on function public.request_payment_from_bc(text,text,uuid,date,text),public.import_bc_control_file(text,text,text,jsonb),public.get_bc_control_records(text,text,int,int),public.get_readiness_policies(),public.set_readiness_policy(text,jsonb,jsonb,jsonb,int,jsonb,numeric),public.check_payment_readiness(uuid,text,jsonb,jsonb,boolean),public.get_payment_readiness_assessment(uuid),public.request_work_delay_attribution(uuid,text,timestamptz,timestamptz,text,text),public.decide_work_delay_attribution(uuid,boolean,text),public.get_work_delay_attributions(uuid),public.get_employee_performance_report_v5(uuid,date,date) to authenticated;
