import fs from 'fs';
import http from 'http';
import { chromium } from 'playwright';

const src = fs.readFileSync('index.html','utf8');

function extractFunction(name){
  const start = src.indexOf(`function ${name}(`);
  if(start<0) throw new Error(`Missing function ${name}`);
  let i = src.indexOf('{', start), depth=0, inS=false, inD=false, inT=false, esc=false;
  for(; i<src.length; i++){
    const c=src[i], p=src[i-1];
    if(esc){esc=false;continue}
    if(c==='\\'){esc=true;continue}
    if(!inD&&!inT&&c==="'"&&p!=='\\') inS=!inS;
    else if(!inS&&!inT&&c==='"'&&p!=='\\') inD=!inD;
    else if(!inS&&!inD&&c==='`'&&p!=='\\') inT=!inT;
    if(inS||inD||inT) continue;
    if(c==='{') depth++;
    if(c==='}') { depth--; if(depth===0) return src.slice(start,i+1); }
  }
  throw new Error(`Unclosed function ${name}`);
}

const names=[
  'universalColumnStorageKey','universalTableKey','universalColumnDefs','universalVisibleSet',
  'applyUniversalColumnVisibility','openUniversalColumnSettings','saveUniversalColumns','resetUniversalColumns',
  'installUniversalColumnCustomizers'
];
const funcs=names.map(extractFunction).join('\n');
const html=src.replace(/<script[\s\S]*?<\/script>/gi,'').replace('</body>',`<div id="qaModal"><div id="modalTitle"></div><div id="modalBody"></div></div><script>\nlet profile={id:'qa-column-user'};\nconst UNIVERSAL_COLUMN_PREF_PREFIX='sanam_columns_v2';\nfunction displayText(v){return v}\nfunction showModal(title,html){document.getElementById('modalTitle').textContent=title;document.getElementById('modalBody').innerHTML=html}\nfunction closeModal(){document.getElementById('modalBody').innerHTML=''}\nfunction installTableFilters(){}\n${funcs}\nwindow.addEventListener('DOMContentLoaded',()=>installUniversalColumnCustomizers());\n</script></body>`);

const server=http.createServer((req,res)=>{res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'});res.end(html)});
await new Promise(r=>server.listen(4173,'127.0.0.1',r));

const browser=await chromium.launch({headless:true});
const page=await browser.newPage();
await page.goto('http://127.0.0.1:4173',{waitUntil:'domcontentloaded'});

const initial=await page.evaluate(()=>{
  const tables=[...document.querySelectorAll('.section .table-wrap table')];
  return tables.map(t=>({key:universalTableKey(t),cols:universalColumnDefs(t).map(d=>d.key),id:t.id||null,section:t.closest('.section')?.id||null,button:!!t.closest('.table-wrap')?.previousElementSibling?.querySelector('button')}));
});
if(!initial.length) throw new Error('No customizable tables found');
for(const x of initial){ if(!x.button) throw new Error(`No customization button for ${x.key}`); if(!x.cols.length) throw new Error(`No column definitions for ${x.key}`); }

const configured=await page.evaluate(()=>{
  const out=[];
  for(const t of document.querySelectorAll('.section .table-wrap table')){
    const key=universalTableKey(t), defs=universalColumnDefs(t);
    openUniversalColumnSettings(key);
    const choices=[...document.querySelectorAll('.universal-column-choice')];
    choices.forEach(c=>c.checked=false);
    const wanted=defs.length>1?[defs[0].key,defs[defs.length-1].key]:[defs[0].key];
    for(const c of choices){ if(wanted.includes(c.value)) c.checked=true; }
    saveUniversalColumns(key);
    const stored=JSON.parse(localStorage.getItem(universalColumnStorageKey(t))||'[]');
    const visibility=defs.map(d=>({key:d.key,hidden:[...t.querySelectorAll(`tr > *:nth-child(${d.index})`)].every(el=>el.classList.contains('hidden'))}));
    out.push({key,wanted,stored,visibility,storageKey:universalColumnStorageKey(t)});
  }
  return out;
});
for(const x of configured){
  if(JSON.stringify(x.wanted)!==JSON.stringify(x.stored)) throw new Error(`Saved localStorage mismatch ${x.key}`);
  for(const v of x.visibility){
    const shouldHide=!x.wanted.includes(v.key);
    if(v.hidden!==shouldHide) throw new Error(`Immediate visibility mismatch ${x.key}/${v.key}`);
  }
}

await page.reload({waitUntil:'domcontentloaded'});
const afterReload=await page.evaluate(()=>{
  const out=[];
  for(const t of document.querySelectorAll('.section .table-wrap table')){
    const defs=universalColumnDefs(t);
    const chosen=JSON.parse(localStorage.getItem(universalColumnStorageKey(t))||'[]');
    applyUniversalColumnVisibility(t);
    const visibility=defs.map(d=>({key:d.key,hidden:[...t.querySelectorAll(`tr > *:nth-child(${d.index})`)].every(el=>el.classList.contains('hidden'))}));
    out.push({key:universalTableKey(t),chosen,visibility,button:!!t.closest('.table-wrap')?.previousElementSibling?.querySelector('button')});
  }
  return out;
});

if(afterReload.length!==initial.length) throw new Error(`Table count changed after reload: ${initial.length} -> ${afterReload.length}`);
for(const x of afterReload){
  if(!x.button) throw new Error(`Customization button missing after reload: ${x.key}`);
  if(!x.chosen.length) throw new Error(`Stored selection missing after reload: ${x.key}`);
  for(const v of x.visibility){
    const shouldHide=!x.chosen.includes(v.key);
    if(v.hidden!==shouldHide) throw new Error(`Reload persistence mismatch ${x.key}/${v.key}`);
  }
}

console.log(JSON.stringify({tablesTested:initial.length,tables:initial.map(x=>({key:x.key,section:x.section,id:x.id,columnCount:x.cols.length})),actualSaveFlow:'PASS',persistenceAfterReload:'PASS',customizerButtons:'PASS'},null,2));
await browser.close(); server.close();
