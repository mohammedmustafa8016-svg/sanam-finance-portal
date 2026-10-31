/* Navigation composition only. Existing page guards, RPCs and lifecycle remain authoritative. */
(() => {
  'use strict';
  const spaces = [
    {id:'home',ar:'الرئيسية',en:'Home',pages:[['dashboard','ملخص اليوم','Today']]},
    {id:'work',ar:'مركز العمل',en:'Work Center',pages:[['workcenter','مركز العمل','Work Center'],['tasks','المهام','Tasks'],['control','الرقابة التشغيلية','Operations control'],['workload','أعباء العمل','Workload'],['escalations','التصعيدات','Escalations']]},
    {id:'payments',ar:'المدفوعات',en:'Payments',pages:[['payments','المطلوبة والاعتمادات','Requests & approvals'],['executed','المنفذة','Executed'],['pending','المعلقة','Pending'],['posted','المرحلة محاسبيًا','Posted in accounting'],['dailyemail','البريد اليومي','Daily email']]},
    {id:'treasury',ar:'الخزينة والبنوك',en:'Treasury & Banks',pages:[['banks','السيولة والبنوك','Liquidity & banks']]},
    {id:'imprest',ar:'العهد',en:'Imprest',pages:[['imprest','العهد والتمويل والتسويات','Funds, funding & settlements']]},
    {id:'close',ar:'الإقفال الشهري',en:'Monthly Close',pages:[['close','متابعة الإقفال','Close progress']]},
    {id:'performance',ar:'الأداء والتقارير',en:'Performance & Reports',pages:[['performance','التقييم وتقارير الموظفين','Evaluation & employee reports']]},
    {id:'admin',ar:'الإدارة والرقابة',en:'Administration & Governance',pages:[['ownership','المسؤوليات','Ownership'],['exceptions','الاستثناءات والسياسات','Exceptions & policies'],['permissions','المستخدمون والصلاحيات','Users & permissions'],['automation','الأتمتة وصحة النظام','Automation & system health'],['audit','سجل التدقيق','Audit log']]}
  ];
  const text = (ar,en) => currentLang === 'en' ? en : ar;
  const allowed = space => space.pages.filter(([id]) => document.getElementById(id) && canPage(id));
  const owner = id => spaces.find(space => space.pages.some(page => page[0] === id));
  let identity = null;
  const remembered = new Map();
  const side = document.querySelector('.side');
  const content = document.querySelector('.main .content');
  if (!side || !content) return;
  const nav = document.createElement('nav');
  nav.id = 'workspaceNavigation';
  side.appendChild(nav);
  const header = document.createElement('section');
  header.id = 'workspaceHeader';
  content.before(header);

  function render() {
    if (identity !== profile?.id) { identity = profile?.id; remembered.clear(); }
    const active = document.querySelector('.section.active')?.id;
    const current = owner(active);
    nav.setAttribute('aria-label', text('مساحات العمل','Workspaces'));
    nav.replaceChildren();
    if (!profile) { header.replaceChildren(); return; }
    for (const space of spaces) {
      const pages = allowed(space);
      if (!pages.length) continue;
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'workspace-link';
      button.dataset.workspace = space.id;
      button.dataset.symbol = ({home:'⌂',work:'▦',payments:'⇄',treasury:'▤',imprest:'◇',close:'◷',performance:'▥',admin:'⚙'})[space.id];
      button.textContent = text(space.ar,space.en);
      if (space === current) button.setAttribute('aria-current','page');
      button.onclick = () => {
        const target = pages.find(([id]) => id === remembered.get(space.id)) || pages[0];
        openPage(target[0],text(target[1],target[2]));
      };
      nav.appendChild(button);
    }
    header.replaceChildren();
    if (!current || !canPage(active)) { header.hidden = true; return; }
    header.hidden = false;
    header.dataset.flow = current.id;
    const title = document.createElement('h1');
    title.textContent = text(current.ar,current.en);
    header.appendChild(title);
    const tabs = document.createElement('div');
    tabs.className = 'workspace-tabs';
    tabs.setAttribute('role','tablist');
    tabs.setAttribute('aria-label',title.textContent);
    for (const [id,ar,en] of allowed(current)) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'workspace-tab';
      button.dataset.workspacePage = id;
      button.id = `workspace-tab-${id}`;
      button.textContent = text(ar,en);
      button.setAttribute('role','tab');
      button.setAttribute('aria-controls',id);
      button.setAttribute('aria-selected',String(id === active));
      button.tabIndex = id === active ? 0 : -1;
      button.onclick = () => { openPage(id,text(ar,en)); document.getElementById(button.id)?.focus(); };
      button.onkeydown = event => {
        const buttons = [...tabs.children];
        let index = buttons.indexOf(button);
        const forward = currentLang === 'en' ? 'ArrowRight' : 'ArrowLeft';
        const backward = currentLang === 'en' ? 'ArrowLeft' : 'ArrowRight';
        if (event.key === forward) index = (index + 1) % buttons.length;
        else if (event.key === backward) index = (index - 1 + buttons.length) % buttons.length;
        else if (event.key === 'Home') index = 0;
        else if (event.key === 'End') index = buttons.length - 1;
        else return;
        event.preventDefault();
        buttons[index].click();
      };
      tabs.appendChild(button);
      const panel = document.getElementById(id);
      panel.setAttribute('role','tabpanel');
      panel.setAttribute('aria-labelledby',button.id);
    }
    header.appendChild(tabs);
  }
  const previousOpenPage = openPage;
  openPage = function(id,title) {
    if (!canPage(id)) return;
    const result = previousOpenPage(id,title);
    const space = owner(id);
    if (space) remembered.set(space.id,id);
    render();
    return result;
  };
  const previousApplyAccess = applyAccess;
  applyAccess = function(...args) {
    const result = previousApplyAccess.apply(this,args);
    const active = document.querySelector('.section.active');
    if (active && !canPage(active.id)) {
      active.classList.remove('active');
      const first = spaces.flatMap(allowed)[0];
      if (first) openPage(first[0],text(first[1],first[2]));
    }
    render();
    return result;
  };
  const previousApplyLanguage = applyLanguage;
  applyLanguage = function(...args) {
    const result = previousApplyLanguage.apply(this,args);
    render();
    return result;
  };
  document.documentElement.classList.add('workspace-navigation-ready');
  render();
})();
