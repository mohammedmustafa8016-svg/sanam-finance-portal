/* Business Central-style column personalization.
   Additive UI layer only: preserves existing data, workflows, filters, permissions, and legacy visibility preferences. */

Object.assign(I18N_AR_EN,{
  "اسحب الصفوف لتغيير ترتيب الأعمدة، وحدد ما تريد إظهاره. يمكنك سحب حد عنوان العمود لتغيير العرض، والنقر المزدوج لضبط العرض تلقائيًا.":"Drag rows to reorder columns and choose which columns to show. Drag a column-header edge to resize; double-click it to auto-fit.",
  "ترتيب الأعمدة":"Column Order",
  "العرض":"Width",
  "تلقائي":"Auto Fit",
  "تثبيت الأعمدة حتى":"Freeze Columns Through",
  "بدون تثبيت":"No Freeze",
  "حفظ التخصيص":"Save Personalization",
  "إعداد افتراضي للدور":"Role Default Layout",
  "حفظ كافتراضي للدور":"Save as Role Default",
  "حذف افتراضي الدور":"Clear Role Default",
  "تم حفظ التخطيط الافتراضي للدور.":"Role default layout saved.",
  "تم حذف التخطيط الافتراضي للدور.":"Role default layout cleared.",
  "تحريك لأعلى":"Move Up",
  "تحريك لأسفل":"Move Down"
});

window.__sanamColumnRoleDefaults=window.__sanamColumnRoleDefaults||{};

function bcColumnRoleDefaults(){return window.__sanamColumnRoleDefaults||{}}

function bcColumnDefs(table){
  universalTableKey(table);
  const ths=[...table.querySelectorAll("thead tr:first-child th")];
  ths.forEach((th,i)=>{
    if(!th.dataset.universalColKey)th.dataset.universalColKey=th.dataset.colKey||("c"+(i+1));
    if(!th.dataset.universalLabel){
      const clone=th.cloneNode(true);
      clone.querySelectorAll("button,.filter-arrow,.column-resize-handle").forEach(x=>x.remove());
      th.dataset.universalLabel=(clone.textContent||"").trim()||("Column "+(i+1));
    }
  });
  if(!table.dataset.columnBaseOrder)table.dataset.columnBaseOrder=ths.map(th=>th.dataset.universalColKey).join("|");
  const base=(table.dataset.columnBaseOrder||"").split("|").filter(Boolean);
  const currentKeys=ths.map(th=>th.dataset.universalColKey);
  const merged=[...base.filter(k=>currentKeys.includes(k)),...currentKeys.filter(k=>!base.includes(k))];
  table.dataset.columnBaseOrder=merged.join("|");
  return ths.map((th,i)=>({
    key:th.dataset.universalColKey,
    label:th.dataset.universalLabel,
    index:i+1,
    defaultVisible:th.dataset.defaultHidden!=="1"
  }));
}

function bcBuiltInColumnConfig(table){
  const defs=bcColumnDefs(table);
  const base=(table.dataset.columnBaseOrder||"").split("|").filter(Boolean);
  const map=new Map(defs.map(d=>[d.key,d]));
  return {
    version:3,
    visible:base.filter(k=>map.get(k)?.defaultVisible),
    order:base,
    widths:{},
    freezeThrough:null
  };
}

function bcNormalizeColumnConfig(raw,table){
  const built=bcBuiltInColumnConfig(table);
  const keys=built.order.slice();
  if(Array.isArray(raw)){
    return {
      version:3,
      visible:raw.filter(k=>keys.includes(k)),
      order:keys,
      widths:{},
      freezeThrough:null
    };
  }
  const obj=raw&&typeof raw==="object"?raw:{};
  const order=Array.isArray(obj.order)
    ? [...obj.order.filter(k=>keys.includes(k)),...keys.filter(k=>!obj.order.includes(k))]
    : keys;
  const visible=Array.isArray(obj.visible)
    ? obj.visible.filter(k=>keys.includes(k))
    : built.visible.slice();
  const widths={};
  if(obj.widths&&typeof obj.widths==="object"){
    Object.entries(obj.widths).forEach(([k,v])=>{
      const n=Number(v);
      if(keys.includes(k)&&Number.isFinite(n)&&n>=55&&n<=800)widths[k]=Math.round(n);
    });
  }
  const freezeThrough=keys.includes(obj.freezeThrough)?obj.freezeThrough:null;
  return {
    version:3,
    visible:visible.length?visible:built.visible.slice(),
    order,
    widths,
    freezeThrough
  };
}

function bcReadPersonalConfig(table){
  try{
    const raw=localStorage.getItem(universalColumnStorageKey(table));
    if(!raw)return null;
    return bcNormalizeColumnConfig(JSON.parse(raw),table);
  }catch{return null}
}

function bcEffectiveColumnConfig(table){
  const personal=bcReadPersonalConfig(table);
  if(personal)return personal;
  const roleDefault=bcColumnRoleDefaults()[universalTableKey(table)];
  if(roleDefault)return bcNormalizeColumnConfig(roleDefault,table);
  return bcBuiltInColumnConfig(table);
}

function bcSavePersonalConfig(table,config){
  localStorage.setItem(universalColumnStorageKey(table),JSON.stringify(bcNormalizeColumnConfig(config,table)));
}

function bcValidRows(table){
  const count=table.tHead?.rows?.[0]?.cells?.length||0;
  return [...table.querySelectorAll("tr")].filter(r=>r.cells.length===count);
}

function bcReorderColumns(table,config){
  const header=table.tHead?.rows?.[0];
  if(!header)return;
  const current=[...header.cells].map(th=>th.dataset.universalColKey);
  const desired=[...config.order.filter(k=>current.includes(k)),...current.filter(k=>!config.order.includes(k))];
  const indices=desired.map(k=>current.indexOf(k));
  bcValidRows(table).forEach(row=>{
    const cells=[...row.cells];
    indices.forEach(i=>{if(cells[i])row.appendChild(cells[i])});
  });
}

function bcColumnCells(table,key){
  const defs=bcColumnDefs(table);
  const index=defs.findIndex(d=>d.key===key);
  if(index<0)return [];
  return bcValidRows(table).map(r=>r.cells[index]).filter(Boolean);
}

function bcClearColumnWidthStyles(table,key){
  bcColumnCells(table,key).forEach(cell=>{
    cell.style.removeProperty("width");
    cell.style.removeProperty("min-width");
  });
}

function bcApplyWidths(table,config){
  const defs=bcColumnDefs(table);
  defs.forEach(d=>{
    const width=Number(config.widths?.[d.key]||0);
    const cells=bcColumnCells(table,d.key);
    cells.forEach(cell=>{
      if(width){
        cell.style.width=width+"px";
        cell.style.minWidth=width+"px";
      }else{
        cell.style.removeProperty("width");
        cell.style.removeProperty("min-width");
      }
    });
  });
}

function bcApplyVisibility(table,config){
  const visible=new Set(config.visible||[]);
  const defs=bcColumnDefs(table);
  defs.forEach((d,i)=>{
    bcValidRows(table).forEach(row=>row.cells[i]?.classList.toggle("hidden",!visible.has(d.key)));
  });
}

function bcClearFreeze(table){
  bcValidRows(table).forEach(row=>[...row.cells].forEach(cell=>{
    cell.classList.remove("bc-frozen-column","bc-frozen-last");
    cell.style.removeProperty("position");
    cell.style.removeProperty("inset-inline-start");
    cell.style.removeProperty("z-index");
    cell.style.removeProperty("background-color");
  }));
}

function bcApplyFreeze(table,config){
  bcClearFreeze(table);
  if(!config.freezeThrough)return;
  const defs=bcColumnDefs(table);
  const visibleOrder=defs.filter(d=>(config.visible||[]).includes(d.key));
  const end=visibleOrder.findIndex(d=>d.key===config.freezeThrough);
  if(end<0)return;
  let offset=0;
  visibleOrder.slice(0,end+1).forEach((d,freezeIndex,arr)=>{
    const colIndex=defs.findIndex(x=>x.key===d.key);
    const headerCell=table.tHead?.rows?.[0]?.cells?.[colIndex];
    const width=headerCell?.getBoundingClientRect().width||Number(config.widths?.[d.key]||120);
    bcValidRows(table).forEach(row=>{
      const cell=row.cells[colIndex];
      if(!cell)return;
      cell.classList.add("bc-frozen-column");
      if(freezeIndex===arr.length-1)cell.classList.add("bc-frozen-last");
      cell.style.position="sticky";
      cell.style.insetInlineStart=Math.round(offset)+"px";
      cell.style.zIndex=row.parentElement?.tagName==="THEAD"?"8":"4";
      const rowBg=getComputedStyle(row).backgroundColor;
      cell.style.backgroundColor=(rowBg&&rowBg!=="rgba(0, 0, 0, 0)")?rowBg:"#fff";
    });
    offset+=width;
  });
}

function bcApplyColumnPersonalization(table){
  if(!table)return;
  bcColumnDefs(table);
  const config=bcEffectiveColumnConfig(table);
  bcReorderColumns(table,config);
  bcApplyVisibility(table,config);
  bcApplyWidths(table,config);
  bcInstallResizeHandles(table);
  requestAnimationFrame(()=>bcApplyFreeze(table,config));
}

function bcSetColumnWidth(table,key,width,persist){
  const n=Math.max(55,Math.min(800,Math.round(Number(width)||0)));
  if(!n)return;
  bcColumnCells(table,key).forEach(cell=>{
    cell.style.width=n+"px";
    cell.style.minWidth=n+"px";
  });
  if(persist!==false){
    const config=bcEffectiveColumnConfig(table);
    config.widths=config.widths||{};
    config.widths[key]=n;
    bcSavePersonalConfig(table,config);
    bcApplyFreeze(table,config);
  }
}

function autoFitUniversalColumn(tableKey,key){
  const table=[...document.querySelectorAll(".section .table-wrap table")].find(t=>universalTableKey(t)===tableKey);
  if(!table)return;
  bcClearColumnWidthStyles(table,key);
  const cells=bcColumnCells(table,key);
  let width=70;
  cells.forEach(cell=>{width=Math.max(width,Math.min(520,(cell.scrollWidth||cell.getBoundingClientRect().width||70)+24))});
  bcSetColumnWidth(table,key,width,true);
  bcRefreshColumnWidthLabels(tableKey);
}

function clearUniversalColumnWidth(tableKey,key){
  const table=[...document.querySelectorAll(".section .table-wrap table")].find(t=>universalTableKey(t)===tableKey);
  if(!table)return;
  const config=bcEffectiveColumnConfig(table);
  if(config.widths)delete config.widths[key];
  bcSavePersonalConfig(table,config);
  bcClearColumnWidthStyles(table,key);
  bcApplyColumnPersonalization(table);
  bcRefreshColumnWidthLabels(tableKey);
}

function bcInstallResizeHandles(table){
  const defs=bcColumnDefs(table);
  const ths=[...table.querySelectorAll("thead tr:first-child th")];
  ths.forEach((th,i)=>{
    const key=defs[i]?.key;
    if(!key)return;
    th.style.position="relative";
    let handle=th.querySelector(".column-resize-handle");
    if(!handle){
      handle=document.createElement("span");
      handle.className="column-resize-handle";
      handle.title=currentLang==="en"?"Drag to resize; double-click to auto-fit":"اسحب لتغيير العرض؛ انقر مرتين للضبط التلقائي";
      th.appendChild(handle);
    }
    handle.dataset.key=key;
    handle.ondblclick=e=>{e.preventDefault();e.stopPropagation();autoFitUniversalColumn(universalTableKey(table),key)};
    handle.onpointerdown=e=>{
      if(e.button!==0)return;
      e.preventDefault();e.stopPropagation();
      const startX=e.clientX;
      const startWidth=th.getBoundingClientRect().width;
      const dir=document.documentElement.dir==="rtl"?-1:1;
      handle.setPointerCapture?.(e.pointerId);
      const move=ev=>bcSetColumnWidth(table,key,startWidth+(ev.clientX-startX)*dir,false);
      const up=ev=>{
        window.removeEventListener("pointermove",move);
        window.removeEventListener("pointerup",up);
        const finalWidth=th.getBoundingClientRect().width;
        bcSetColumnWidth(table,key,finalWidth,true);
      };
      window.addEventListener("pointermove",move);
      window.addEventListener("pointerup",up,{once:true});
    };
  });
}

function bcColumnListMove(button,delta){
  const item=button.closest(".bc-column-item");
  const list=item?.parentElement;
  if(!item||!list)return;
  if(delta<0&&item.previousElementSibling)list.insertBefore(item,item.previousElementSibling);
  if(delta>0&&item.nextElementSibling)list.insertBefore(item.nextElementSibling,item);
}

function bcColumnDragStart(event){
  const item=event.currentTarget;
  event.dataTransfer.effectAllowed="move";
  event.dataTransfer.setData("text/plain",item.dataset.key||"");
  item.classList.add("dragging");
}

function bcColumnDragEnd(event){event.currentTarget.classList.remove("dragging")}

function bcColumnDragOver(event){event.preventDefault();event.dataTransfer.dropEffect="move"}

function bcColumnDrop(event){
  event.preventDefault();
  const target=event.currentTarget;
  const list=target.parentElement;
  const key=event.dataTransfer.getData("text/plain");
  const source=[...list.querySelectorAll(".bc-column-item")].find(x=>x.dataset.key===key);
  if(!source||source===target)return;
  const rect=target.getBoundingClientRect();
  if(event.clientY<rect.top+rect.height/2)list.insertBefore(source,target);
  else list.insertBefore(source,target.nextElementSibling);
}

function bcConfigFromModal(table){
  const current=bcEffectiveColumnConfig(table);
  const items=[...document.querySelectorAll("#bcColumnList .bc-column-item")];
  const order=items.map(x=>x.dataset.key);
  const visible=items.filter(x=>x.querySelector(".universal-column-choice")?.checked).map(x=>x.dataset.key);
  const freeze=document.getElementById("bcFreezeThrough")?.value||null;
  return bcNormalizeColumnConfig({
    version:3,
    order,
    visible,
    widths:current.widths||{},
    freezeThrough:visible.includes(freeze)?freeze:null
  },table);
}

function bcRefreshColumnWidthLabels(tableKey){
  const table=[...document.querySelectorAll(".section .table-wrap table")].find(t=>universalTableKey(t)===tableKey);
  if(!table)return;
  const config=bcEffectiveColumnConfig(table);
  document.querySelectorAll("#bcColumnList .bc-column-item").forEach(item=>{
    const span=item.querySelector(".bc-width-value");
    if(span)span.textContent=config.widths?.[item.dataset.key]?config.widths[item.dataset.key]+" px":displayText("تلقائي");
  });
}

async function loadColumnRoleDefaults(){
  if(!profile)return;
  const result=await sb.rpc("get_my_column_layout_defaults");
  if(result.error){console.error("Column role defaults load failed",result.error);window.__sanamColumnRoleDefaults={};return}
  const map={};
  (result.data||[]).forEach(row=>{map[row.table_key]=row.config||{}});
  window.__sanamColumnRoleDefaults=map;
}

function openUniversalColumnSettings(tableKey){
  const table=[...document.querySelectorAll(".section .table-wrap table")].find(t=>universalTableKey(t)===tableKey);
  if(!table)return;
  bcApplyColumnPersonalization(table);
  const config=bcEffectiveColumnConfig(table);
  const defs=bcColumnDefs(table);
  const byKey=new Map(defs.map(d=>[d.key,d]));
  const ordered=[...config.order.filter(k=>byKey.has(k)),...defs.map(d=>d.key).filter(k=>!config.order.includes(k))];
  const current=new Set(config.visible||[]);
  const rows=ordered.map(key=>{
    const d=byKey.get(key);
    const width=config.widths?.[key]?config.widths[key]+" px":displayText("تلقائي");
    return '<div class="bc-column-item" draggable="true" data-key="'+esc(key)+'" ondragstart="bcColumnDragStart(event)" ondragend="bcColumnDragEnd(event)" ondragover="bcColumnDragOver(event)" ondrop="bcColumnDrop(event)">'+
      '<span class="bc-drag-handle" title="'+displayText("ترتيب الأعمدة")+'">⋮⋮</span>'+
      '<label class="bc-column-check"><input type="checkbox" class="universal-column-choice" value="'+esc(key)+'" '+(current.has(key)?"checked":"")+'> <span>'+esc(displayText(d.label))+'</span></label>'+
      '<span class="bc-width-value muted">'+esc(width)+'</span>'+
      '<button class="btn bc-mini-btn" type="button" onclick="autoFitUniversalColumn(\''+esc(tableKey)+'\',\''+esc(key)+'\')">'+displayText("تلقائي")+'</button>'+
      '<button class="btn bc-mini-btn" type="button" onclick="clearUniversalColumnWidth(\''+esc(tableKey)+'\',\''+esc(key)+'\')">↺</button>'+
      '<button class="btn bc-mini-btn" type="button" title="'+displayText("تحريك لأعلى")+'" onclick="bcColumnListMove(this,-1)">↑</button>'+
      '<button class="btn bc-mini-btn" type="button" title="'+displayText("تحريك لأسفل")+'" onclick="bcColumnListMove(this,1)">↓</button>'+
    '</div>';
  }).join("");
  const freezeOptions=['<option value="">'+displayText("بدون تثبيت")+'</option>'].concat(ordered.map(key=>{
    const d=byKey.get(key);
    return '<option value="'+esc(key)+'" '+(config.freezeThrough===key?"selected":"")+'>'+esc(displayText(d.label))+'</option>';
  })).join("");
  const roleControls=profile.role==="CFO"
    ? '<div class="bc-role-default-box"><h4>'+displayText("إعداد افتراضي للدور")+'</h4><div class="modal-grid"><div><label>'+displayText("الدور")+'</label><select id="bcRoleDefaultRole">'+Object.entries(ROLE_LABEL).map(([v,l])=>'<option value="'+esc(v)+'">'+esc(displayText(l))+'</option>').join("")+'</select></div></div><div class="lang-actions" style="margin-top:8px"><button class="btn" type="button" onclick="saveColumnRoleDefault(\''+esc(tableKey)+'\')">'+displayText("حفظ كافتراضي للدور")+'</button><button class="btn" type="button" onclick="clearColumnRoleDefault(\''+esc(tableKey)+'\')">'+displayText("حذف افتراضي الدور")+'</button></div></div>'
    : "";
  showModal(displayText("تخصيص الأعمدة"),
    '<div class="note">'+displayText("اسحب الصفوف لتغيير ترتيب الأعمدة، وحدد ما تريد إظهاره. يمكنك سحب حد عنوان العمود لتغيير العرض، والنقر المزدوج لضبط العرض تلقائيًا.")+'</div>'+
    '<div id="bcColumnList" class="bc-column-list" style="margin-top:12px">'+rows+'</div>'+
    '<div style="margin-top:12px"><label>'+displayText("تثبيت الأعمدة حتى")+'</label><select id="bcFreezeThrough">'+freezeOptions+'</select></div>'+
    roleControls+
    '<div class="row" style="margin-top:14px"><div class="lang-actions"><button class="btn" onclick="resetUniversalColumns(\''+esc(tableKey)+'\',false)">'+displayText("استعادة الافتراضي")+'</button><button class="btn" onclick="resetUniversalColumns(\''+esc(tableKey)+'\',true)">'+displayText("إظهار الكل")+'</button></div><button class="btn primary" onclick="saveUniversalColumns(\''+esc(tableKey)+'\')">'+displayText("حفظ التخصيص")+'</button></div>'
  );
}

function saveUniversalColumns(tableKey){
  const table=[...document.querySelectorAll(".section .table-wrap table")].find(t=>universalTableKey(t)===tableKey);
  if(!table)return;
  const config=bcConfigFromModal(table);
  if(!config.visible.length)return alert(displayText("يجب اختيار عمود واحد على الأقل."));
  bcSavePersonalConfig(table,config);
  closeModal();
  bcApplyColumnPersonalization(table);
  installTableFilters();
}

function resetUniversalColumns(tableKey,showAll){
  const table=[...document.querySelectorAll(".section .table-wrap table")].find(t=>universalTableKey(t)===tableKey);
  if(!table)return;
  if(showAll){
    const config=bcEffectiveColumnConfig(table);
    config.visible=bcBuiltInColumnConfig(table).order.slice();
    bcSavePersonalConfig(table,config);
  }else{
    localStorage.removeItem(universalColumnStorageKey(table));
  }
  closeModal();
  bcApplyColumnPersonalization(table);
  installTableFilters();
}

async function saveColumnRoleDefault(tableKey){
  if(profile.role!=="CFO")return;
  const table=[...document.querySelectorAll(".section .table-wrap table")].find(t=>universalTableKey(t)===tableKey);
  if(!table)return;
  const role=document.getElementById("bcRoleDefaultRole")?.value;
  const config=bcConfigFromModal(table);
  if(!config.visible.length)return alert(displayText("يجب اختيار عمود واحد على الأقل."));
  const result=await sb.rpc("set_column_layout_default",{p_role:role,p_table_key:tableKey,p_config:config});
  if(result.error)return alert(result.error.message);
  if(role===profile.role)window.__sanamColumnRoleDefaults[tableKey]=config;
  alert(displayText("تم حفظ التخطيط الافتراضي للدور."));
}

async function clearColumnRoleDefault(tableKey){
  if(profile.role!=="CFO")return;
  const role=document.getElementById("bcRoleDefaultRole")?.value;
  const result=await sb.rpc("clear_column_layout_default",{p_role:role,p_table_key:tableKey});
  if(result.error)return alert(result.error.message);
  if(role===profile.role)delete window.__sanamColumnRoleDefaults[tableKey];
  alert(displayText("تم حذف التخطيط الافتراضي للدور."));
}

function installUniversalColumnCustomizers(){
  document.querySelectorAll(".section .table-wrap table").forEach(table=>{
    const wrap=table.closest(".table-wrap");
    if(!wrap)return;
    const key=universalTableKey(table);
    bcColumnDefs(table);
    const parent=wrap.parentNode;
    const existing=[...parent.children].filter(el=>el.classList?.contains("column-customizer-bar")&&el.dataset.columnTableKey===key);
    let bar=existing.shift();
    existing.forEach(el=>el.remove());
    if(!bar){
      bar=document.createElement("div");
      bar.className="row column-customizer-bar";
      bar.dataset.columnTableKey=key;
      bar.style.cssText="justify-content:flex-end;margin:6px 0";
    }
    if(bar.parentNode!==parent||bar.nextElementSibling!==wrap)parent.insertBefore(bar,wrap);
    bar.innerHTML='<button class="btn" type="button" onclick="openUniversalColumnSettings(\''+esc(key)+'\')">'+displayText("تخصيص الأعمدة")+'</button>';
    bcApplyColumnPersonalization(table);
  });
}

function universalColumnDefs(table){return bcColumnDefs(table)}
function universalVisibleSet(table){return new Set(bcEffectiveColumnConfig(table).visible||[])}
function applyUniversalColumnVisibility(table){bcApplyColumnPersonalization(table)}

const __bcOriginalEnterApp=enterApp;
enterApp=async function(){
  await __bcOriginalEnterApp();
  if(profile){
    await loadColumnRoleDefaults();
    try{installUniversalColumnCustomizers();installTableFilters()}catch(e){console.error("Column personalization post-login apply failed",e)}
  }
};
