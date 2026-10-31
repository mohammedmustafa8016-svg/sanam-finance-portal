"""Run existing SQL/browser tests against a disposable, migrations-only stack.

Every SQL test has its own connection and BEGIN/ROLLBACK, including fixtures.
Failures are retained independently; no schema, grant or policy patch is applied.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'gate-results'
OUT.mkdir(exist_ok=True)
RESULTS = []
MANIFEST = sorted(p.name.split('_', 1)[0] for p in (ROOT / 'supabase/migrations').glob('*.sql'))
assert len(MANIFEST) == len(set(MANIFEST)) and all(v.isdigit() for v in MANIFEST)
HARDENED = any((ROOT / 'supabase/migrations').glob('*_governed_operations_controls.sql'))
CONTAINER = subprocess.check_output(['docker', 'ps', '--format', '{{.Names}}'], text=True)
CONTAINER = next(n for n in CONTAINER.splitlines() if n.startswith('supabase_db_'))


def sql(text):
    # -i is mandatory: without it docker discards the supplied SQL stdin.
    return subprocess.run(['docker', 'exec', '-i', CONTAINER, 'psql', '-X', '-U',
                           'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1',
                           '-v', 'VERBOSITY=verbose'], input=text, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def record(gate, name, result):
    status = 'PASS' if result.returncode == 0 else 'FAIL'
    log = OUT / (name.replace('/', '_') + '.log')
    log.write_text(result.stdout, encoding='utf-8')
    RESULTS.append(dict(gate=gate, test=name, status=status, log=log.name,
                        exit_code=result.returncode))
    print(f'{status}: {gate}: {name}', flush=True)
    if status == 'FAIL':
        print(result.stdout[-12000:], flush=True)


def check(name, body, gate='Security', fixture=False):
    setup = (ROOT / 'tests/harness/fixtures.sql').read_text() if fixture else ''
    record(gate, name, sql('BEGIN;\n' + setup + '\n' + body + '\nROLLBACK;\n'))


check('migration-history-and-empty-database', f"""
do $$ declare n int; begin
 select count(*) into n from supabase_migrations.schema_migrations;
 if n <> {len(MANIFEST)} then
   raise exception 'MIGRATION_COUNT: %',n; end if;
 if exists(select 1 from auth.users) or exists(select 1 from public.tasks)
    or exists(select 1 from public.payments) then raise exception 'DATABASE_NOT_EMPTY'; end if;
 raise notice 'Migration count=%, auth.users/tasks/payments empty, no seed or patch', n;
end $$;
""")

check('exposed-tables-require-rls', """
do $$ declare bad text; begin
 select string_agg(c.relname,', ' order by c.relname) into bad
 from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where n.nspname='public' and c.relkind in ('r','p') and not c.relrowsecurity
 and (has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE')
      or has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE'));
 if bad is not null then raise exception 'EXPOSED_TABLE_WITHOUT_RLS: %',bad; end if;
end $$;
""")

check('anonymous-security-definer-execution', """
do $$ declare bad text; begin
 select string_agg(p.oid::regprocedure::text,E'\\n' order by p.oid::regprocedure::text) into bad
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.prosecdef and p.prokind='f'
 and has_function_privilege('anon',p.oid,'EXECUTE');
 if bad is not null then raise exception 'ANON_EXECUTABLE_SECURITY_DEFINER: %',bad; end if;
end $$;
""")

check('seed-function-security-contract', f"""
do $$ declare f oid:=to_regprocedure('public.seed_permissions_for_user(uuid)'); begin
 if f is null then raise exception 'SEED_FUNCTION_MISSING'; end if;
 if not exists(select 1 from pg_proc where oid=f and prosecdef
   and proconfig @> array['search_path=public, private, pg_temp']) then
   raise exception 'SEED_SECURITY_OR_SEARCH_PATH'; end if;
 if has_function_privilege('anon',f,'EXECUTE') then raise exception 'SEED_ANON_EXECUTE'; end if;
 if has_function_privilege('authenticated',f,'EXECUTE') is distinct from {'false' if HARDENED else 'true'}
 or not has_function_privilege('service_role',f,'EXECUTE') then raise exception 'SEED_ROLE_EXECUTE'; end if;
end $$;
""")

check('seed-defaults-and-manual-overrides', """
do $$ declare u record; n int; begin
 for u in select id,role from public.profiles loop
   delete from public.user_permissions where user_id=u.id;
   perform public.seed_permissions_for_user(u.id);
   select count(*) into n from public.user_permissions where user_id=u.id;
   if n<>16 then raise exception 'SEED_COUNT: role=% count=%',u.role,n; end if;
   if exists(select 1 from public.user_permissions where user_id=u.id
       and allowed is distinct from private.default_permission_for_role(u.role,permission_key)) then
     raise exception 'SEED_ROLE_DEFAULT: %',u.role; end if;
   update public.user_permissions set allowed=not allowed where user_id=u.id;
   perform public.seed_permissions_for_user(u.id);
   if exists(select 1 from public.user_permissions where user_id=u.id
       and allowed is not distinct from private.default_permission_for_role(u.role,permission_key)) then
     raise exception 'SEED_OVERWROTE_MANUAL_PERMISSION: %',u.role; end if;
 end loop;
 perform public.seed_permissions_for_user(gen_random_uuid());
end $$;
""", gate='RLS/permissions', fixture=True)

check('authenticated-rls-task-and-permission-isolation', """
select set_config('request.jwt.claim.sub',(select id::text from public.profiles where role='CFO'),true);
insert into public.tasks(name,owner_id,reviewer_id,due_date,status,created_by)
select 'HARNESS_PRIVATE_TASK',e.id,s.id,current_date+1,'لم يبدأ',c.id
from public.profiles e,public.profiles s,public.profiles c
where e.role='BankAccountant' and s.role='Supervisor' and c.role='CFO';
select set_config('request.jwt.claim.sub',(select id::text from public.profiles where role='ARAccountant'),true);
set local role authenticated;
do $$ begin
 if exists(select 1 from public.tasks where name='HARNESS_PRIVATE_TASK') then
   raise exception 'RLS_OTHER_EMPLOYEE_TASK_LEAK'; end if;
 if exists(select 1 from public.user_permissions where user_id<>auth.uid()) then
   raise exception 'RLS_OTHER_EMPLOYEE_PERMISSION_LEAK'; end if;
 if exists(select 1 from public.get_my_permissions() where permission_key='page.permissions' and allowed) then
   raise exception 'NON_CFO_PERMISSION_ADMIN'; end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub',(select id::text from public.profiles where role='BankAccountant'),true);
set local role authenticated;
do $$ begin
 if not exists(select 1 from public.tasks where name='HARNESS_PRIVATE_TASK') then
   raise exception 'RLS_ASSIGNEE_CANNOT_READ'; end if;
end $$;
""", gate='RLS/permissions', fixture=True)

# Existing repo SQL tests run unmodified. Supply only the data/pre-activation
# conditions explicitly required by their comments, within the same rollback.
for path in sorted((ROOT / 'tests').glob('*.sql')):
    if path.name in ('governed-operations-controls.sql','workcenter-v5-performance.sql') and not HARDENED:
        print('SKIP baseline: new operations/performance checks: '+path.name, flush=True)
        continue
    setup = (ROOT / 'tests/harness/fixtures.sql').read_text()
    setup += '\n' + (ROOT / 'tests/harness/workflow-fixtures.sql').read_text()
    if path.name in ('workcenter-v5.sql', 'workcenter-v5-plan.sql', 'workcenter-v5-payment-cycle.sql'):
        setup += '\nupdate private.workcenter_cycles set active=false;\n'
    if path.name == 'workcenter-v5.sql':
        setup += """
insert into public.tasks(name,owner_id,reviewer_id,due_date,status,created_at)
select 'HARNESS_HISTORICAL_TASK',e.id,s.id,current_date-1,'لم يبدأ',now()-interval '2 days'
from public.profiles e,public.profiles s where e.role='BankAccountant' and s.role='Supervisor';
"""
    if path.name == 'workcenter-v5-payment-cycle.sql':
        setup += """
insert into public.bank_accounts(id,company,bank_name,account_name)
values('10000000-0000-4000-8000-000000000001','HARNESS','HARNESS','HARNESS');
insert into public.payments(due_date,company,beneficiary,amount,bank_account_id,created_at)
values(current_date,'HARNESS','HARNESS',1,'10000000-0000-4000-8000-000000000001',now()-interval '2 days');
"""
    record('RLS/permissions', path.name, sql('BEGIN;\n' + setup + '\n' + path.read_text() + '\nROLLBACK;\n'))

ENV = dict(os.environ)
ENV['PLAYWRIGHT_PATH'] = str(ROOT / 'tests/harness/node_modules/playwright')
ENV['CHROME_PATH'] = subprocess.check_output(
    ['node', '-e', "process.stdout.write(require('./tests/harness/node_modules/playwright').chromium.executablePath())"],
    cwd=ROOT, text=True)

server_log = (OUT / 'fixture-server.log').open('w')
server = subprocess.Popen(['node', 'tests/serve-preview.cjs'], cwd=ROOT,
                          stdout=server_log, stderr=subprocess.STDOUT)
try:
    import time
    import urllib.request
    for _ in range(50):
        try:
            urllib.request.urlopen('http://127.0.0.1:4173', timeout=1).close()
            break
        except Exception:
            time.sleep(.1)
    for path in sorted((ROOT / 'tests').glob('*browser.cjs')):
        try:
            result = subprocess.run(['node', str(path)], cwd=ROOT, env=ENV,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, timeout=180)
        except subprocess.TimeoutExpired as exc:
            result = subprocess.CompletedProcess([],124,'HARNESS_TIMEOUT\n'+str(exc.stdout))
        record('UI regression (repo fixtures)', path.name, result)
finally:
    server.terminate()
    server.wait()
    server_log.close()

# A separate browser smoke test uses actual local Auth/PostgREST, not fixtures.
# Local-only credentials are generated by Supabase CLI; no remote secrets used.
status = json.loads(subprocess.check_output(['supabase', 'status', '-o', 'json'],text=True))
ENV['LOCAL_SUPABASE_URL'] = status['API_URL']
ENV['LOCAL_SUPABASE_ANON_KEY'] = status['ANON_KEY']
ENV['LOCAL_SUPABASE_SERVICE_KEY'] = status['SERVICE_ROLE_KEY']
record('UI regression (local database)', 'local-database-browser', subprocess.run(
    ['node', 'tests/harness/local-database-browser.cjs'], cwd=ROOT, env=ENV,
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180))

(OUT / 'results.json').write_text(json.dumps(RESULTS,indent=2),encoding='utf-8')
summary = '| Gate | Test | Result |\n|---|---|---|\n' + '\n'.join(
    f"| {r['gate']} | {r['test']} | **{r['status']}** |" for r in RESULTS)
(OUT / 'summary.md').write_text(summary,encoding='utf-8')
if os.getenv('GITHUB_STEP_SUMMARY'):
    with open(os.environ['GITHUB_STEP_SUMMARY'],'a') as stream:
        stream.write(summary+'\n')
sys.exit(1 if any(r['status']=='FAIL' for r in RESULTS) else 0)
