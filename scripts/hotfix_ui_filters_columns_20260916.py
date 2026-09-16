from pathlib import Path
p=Path('index.html')
s=p.read_text()
marker='/* UI_FILTER_COLUMN_RESERVE_HOTFIX_2026_09_16 */'
if marker in s:
    print('already patched')
    raise SystemExit(0)
s=s.replace('/* GOVERNED_UX_PLANNING_SLA_2026_09_16 */','/* GOVERNED_UX_PLANNING_SLA_2026_09_16 */\n'+marker,1)
old="function renderAll(){renderBanks();renderPayments();renderAccountingQueue();renderSavedViews();renderTasks();renderControlCenter();renderWorkload();renderEscalations();renderAutomationHealth();renderClose();renderImprest();renderPerformance();renderOwnership();renderExceptions();renderPolicies();if(canBankBalances())renderDashboard();installUniversalColumnCustomizers();installTableFilters();applyLanguage()}"
new="""function safeRender(name,fn){try{fn()}catch(e){console.error(`Sanam render failure [${name}]`,e)}}
function renderAll(){
 const steps=[['banks',renderBanks],['payments',renderPayments],['accountingQueue',renderAccountingQueue],['savedViews',renderSavedViews],['tasks',renderTasks],['controlCenter',renderControlCenter],['workload',renderWorkload],['escalations',renderEscalations],['automation',renderAutomationHealth],['close',renderClose],['imprest',renderImprest],['performance',renderPerformance],['ownership',renderOwnership],['exceptions',renderExceptions],['policies',renderPolicies]];
 steps.forEach(([name,fn])=>safeRender(name,fn));
 if(canBankBalances())safeRender('dashboard',renderDashboard);
 try{installUniversalColumnCustomizers()}catch(e){console.error('Sanam column customization install failed',e)}
 try{installTableFilters()}catch(e){console.error('Sanam table filter install failed',e)}
 try{applyLanguage()}catch(e){console.error('Sanam language application failed',e)}
}"""
if old not in s:
    raise SystemExit('renderAll baseline not found')
s=s.replace(old,new,1)
needle="function renderDashboard(){\n const totalCash="
replacement="function renderDashboard(){\n const canMove=canBankBalances()&&['CFO','Supervisor','BankAccountant'].includes(profile.role);\n const totalCash="
if needle not in s:
    raise SystemExit('renderDashboard baseline not found')
s=s.replace(needle,replacement,1)
# Regression guards: universal column and filter frameworks must remain present.
for required in ['function installUniversalColumnCustomizers()','function installTableFilters()','function openUniversalColumnSettings(','filter-arrow.active','تخصيص الأعمدة','مسح جميع الفلاتر']:
    if required not in s:
        raise SystemExit(f'missing protected feature: {required}')
p.write_text(s)
print('patched')
