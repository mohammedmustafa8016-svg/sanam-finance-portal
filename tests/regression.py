from pathlib import Path
import re

s = Path('index.html').read_text(encoding='utf-8')

required_pages = ['dashboard','banks','payments','posted','tasks','close','imprest','performance','ownership','exceptions','audit']
for page in required_pages:
    assert f'id="{page}"' in s, f'missing page: {page}'

required_roles = ['CFO','Supervisor','BankAccountant','GLAccountant','ARAccountant','APAccountant']
for role in required_roles:
    assert role in s, f'missing role: {role}'

required_functions = ['openBankModal','saveBank','openPaymentModal','savePayment','supervisorApprove','cfoApprove','executePayment','postPayment','openTaskModal','saveTask','openCloseModal','saveClose','openImprestModal','saveImprest','openExceptionModal','saveException','loadAudit']
for fn in required_functions:
    assert re.search(rf'function\s+{re.escape(fn)}\s*\(|async\s+function\s+{re.escape(fn)}\s*\(', s), f'missing function: {fn}'

for btn_id in ['addBankBtn','addPaymentBtn','addTaskBtn','addCloseBtn','addImprestBtn','addExceptionBtn']:
    assert f'id="{btn_id}"' in s
    assert f'getElementById("{btn_id}")?.addEventListener' not in s, f'duplicate listener regression: {btn_id}'

assert '${moneyHtml(n)}' not in s, 'recursive moneyHtml regression'
assert 'negative-amount' in s, 'negative amount style missing'

for token in ['بانتظار مراجعة المشرف','بانتظار اعتماد CFO','معتمد للدفع','منفذ','مرحّل']:
    assert token in s, f'missing payment state: {token}'

assert 'audit_log_actor_id_fkey' in s, 'audit actor join missing'
assert 'entity_type' in s, 'audit entity_type mapping missing'

print('Static regression suite passed')
