"""Exercise migration 73 over synthetic populated baseline 72, locally only."""
from pathlib import Path
import subprocess
import json
import sys

root = Path(__file__).resolve().parents[2]
out = root / 'gate-results'
out.mkdir(exist_ok=True)
containers = subprocess.check_output(['docker', 'ps', '--format', '{{.Names}}'], text=True)
container = next(n for n in containers.splitlines() if n.startswith('supabase_db_'))
migration = (root / 'supabase/migrations/20261026095100_fix_seed_permissions_for_user.sql').read_text()
fixture = (root / 'tests/harness/fixtures.sql').read_text()
setup = """
BEGIN;
DO $$ BEGIN
 IF (SELECT count(*) FROM supabase_migrations.schema_migrations) <> 72 THEN
  RAISE EXCEPTION 'UPGRADE_REQUIRES_BASELINE_72'; END IF;
END $$;
""" + fixture + """
SELECT set_config('request.jwt.claim.sub',(SELECT id::text FROM public.profiles WHERE role='CFO'),true);
INSERT INTO public.bank_accounts(id,company,bank_name,account_name)
VALUES('10000000-0000-4000-8000-000000000001','HARNESS','HARNESS','HARNESS');
INSERT INTO public.payments(due_date,company,beneficiary,amount,bank_account_id,created_at)
VALUES(current_date,'HARNESS','HARNESS',123.45,'10000000-0000-4000-8000-000000000001',now()-interval '2 days');
INSERT INTO public.tasks(name,owner_id,reviewer_id,due_date,status,created_by)
SELECT 'HARNESS_UPGRADE_PRESERVE',e.id,s.id,current_date+1,'لم يبدأ',c.id
FROM public.profiles e,public.profiles s,public.profiles c
WHERE e.role='BankAccountant' AND s.role='Supervisor' AND c.role='CFO';
UPDATE public.user_permissions SET allowed=NOT allowed,updated_at=now()-interval '3 days';
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.user_permissions) THEN
  RAISE EXCEPTION 'UPGRADE_PERMISSION_FIXTURE_EMPTY'; END IF;
END $$;
CREATE TEMP TABLE upgrade_before(schema_name text,table_name text,rows jsonb);
DO $$ DECLARE t record; snapshot jsonb; BEGIN
 FOR t IN SELECT n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname IN ('public','private','auth') AND c.relkind IN ('r','p') LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(j ORDER BY j::text),''[]''::jsonb) FROM (SELECT to_jsonb(r) j FROM %I.%I r) s',t.nspname,t.relname) INTO snapshot;
  INSERT INTO upgrade_before VALUES(t.nspname,t.relname,snapshot);
 END LOOP;
END $$;
"""
verify = """
DO $$ DECLARE t record; snapshot jsonb; BEGIN
 FOR t IN SELECT * FROM upgrade_before LOOP
  EXECUTE format('SELECT coalesce(jsonb_agg(j ORDER BY j::text),''[]''::jsonb) FROM (SELECT to_jsonb(r) j FROM %I.%I r) s',t.schema_name,t.table_name) INTO snapshot;
  IF snapshot IS DISTINCT FROM t.rows THEN
   RAISE EXCEPTION 'UPGRADE_CHANGED_ROWS: %.%',t.schema_name,t.table_name;
  END IF;
 END LOOP;
 RAISE NOTICE 'PASS: all public/private/auth table rows unchanged, including financial rows and manual permissions';
END $$;
"""
sql = setup + migration + verify + migration + verify + "\nROLLBACK;\n"
result = subprocess.run(['docker','exec','-i',container,'psql','-X','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose'],input=sql,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
(out / 'forward-upgrade.log').write_text(result.stdout,encoding='utf-8')
(out / 'forward-upgrade.json').write_text(json.dumps({'test':'populated-baseline-72-to-73','status':'PASS' if result.returncode==0 else 'FAIL','migration_applied_twice':True,'data':'synthetic only','compared':'all rows in public/private/auth tables','transaction':'rolled back; workflow applies migration with CLI afterward','live_access':False,'backup_restore_tested':False},indent=2))
print(result.stdout,flush=True)
sys.exit(result.returncode)
