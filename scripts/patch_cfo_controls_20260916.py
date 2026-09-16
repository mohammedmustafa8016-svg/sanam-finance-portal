from pathlib import Path

p=Path('index.html')
s=p.read_text()
marker='/* CFO_CONTROLS_RESERVE_RECOVERY_2026_09_16 */'
if marker in s:
    print('already patched')
    raise SystemExit(0)

s=s.replace('/* UNIVERSAL_COLUMN_CUSTOMIZATION_2026_09_15 */','/* UNIVERSAL_COLUMN_CUSTOMIZATION_2026_09_15 */\n'+marker,1)

# CFO gets the same operational ability to open the daily plan; task ownership itself is unchanged.
s=s.replace('dailyPlanBtn.classList.toggle("hidden",profile.role!=="Supervisor")','dailyPlanBtn.classList.toggle("hidden",!["Supervisor","CFO"].includes(profile.role))',1)
s=s.replace('function openDailyPlan(){if(profile.role!=="Supervisor")return;','function openDailyPlan(){if(!["Supervisor","CFO"].includes(profile.role))return;',1)

# Payment list action: CFO may edit an approved-but-not-executed payment; other roles keep the previous boundary.
old='if(["CFO","Supervisor","BankAccountant"].includes(profile.role)&&p.cfo_status!=="موافق"&&!p.executed_at&&!p.posted_at&&p.status!=="مرحّل")a.push(`<button class="btn" onclick="openPaymentModal(\'${p.id}\')">${displayText(\'تعديل\')}</button>`);'
new='if(((profile.role==="CFO")||(["Supervisor","BankAccountant"].includes(profile.role)&&p.cfo_status!=="موافق"))&&!p.executed_at&&!p.posted_at&&p.status!=="مرحّل")a.push(`<button class="btn" onclick="openPaymentModal(\'${p.id}\')">${displayText(\'تعديل\')}</button>`);'
assert old in s, 'paymentActions edit condition not found'
s=s.replace(old,new,1)

old='if(editing){if(!["CFO","Supervisor","BankAccountant"].includes(profile.role))return;if(!p||p.cfo_status==="موافق"||p.executed_at||p.posted_at||p.status==="مرحّل")return alert("لا يمكن تعديل دفعة بعد الاعتماد النهائي أو التنفيذ.")}else if(!["CFO","Supervisor","BankAccountant","APAccountant"].includes(profile.role))return;'
new='if(editing){if(!["CFO","Supervisor","BankAccountant"].includes(profile.role))return;if(!p||p.executed_at||p.posted_at||p.status==="مرحّل"||(p.cfo_status==="موافق"&&profile.role!=="CFO"))return alert("لا يمكن تعديل الدفعة بهذه الصلاحية بعد اعتماد CFO أو بعد التنفيذ.")}else if(!["CFO","Supervisor","BankAccountant","APAccountant"].includes(profile.role))return;'
assert old in s, 'openPaymentModal edit guard not found'
s=s.replace(old,new,1)

oldwarn="${editing?'أي تعديل يعيد اعتماد المشرف وCFO إلى «معلق» حفاظًا على سلامة دورة الاعتماد. ':''}عند اختيار حساب احتياطي سيظهر تحذير قبل الحفظ."
newwarn="${editing?(p?.cfo_status==='موافق'&&profile.role==='CFO'?'هذه الدفعة معتمدة من CFO. التعديل قبل التنفيذ مسموح للمدير المالي فقط؛ التغيير الجوهري في الشركة/المستفيد/المبلغ/الحساب يعيد دورة اعتماد المشرف وCFO، أما التغييرات الأخرى فتعيد اعتماد CFO فقط. ':'أي تعديل قبل الاعتماد النهائي يعيد اعتماد المشرف وCFO إلى «معلق» حفاظًا على سلامة دورة الاعتماد. '):''}عند اختيار حساب احتياطي سيظهر تحذير قبل الحفظ."
assert oldwarn in s, 'payment edit warning not found'
s=s.replace(oldwarn,newwarn,1)

# Replace reserve movement entry with recoverability classification and explicit restoration target.
old_start=s.index("function openReserveMovement(bankId,type){")
old_end=s.index("\n\nlet reserveReportRows=[];",old_start)
old_block=s[old_start:old_end]
new_block=r'''async function openReserveMovement(bankId,type){
 if(!['CFO','Supervisor','BankAccountant'].includes(profile.role))return;
 const b=banks.find(x=>x.id===bankId);if(!b||!isProtectedBank(b))return;
 if(type==='Support Draw'){
   showModal('تسجيل سحب دعم خارجي',`<div class="note">${esc(b.bank_name)} — ${esc(b.account_name)} — ${esc(accountTypeLabel(b.account_type))}</div><div class="modal-grid" style="margin-top:10px">${input('rm_amount','المبلغ',0,'number')}${input('rm_date','التاريخ',new Date().toISOString().slice(0,10),'date')}${select('rm_requires','هل الدعم مطلوب استعادته؟',[{value:'true',label:'نعم — مطلوب استعادته'},{value:'false',label:'لا — غير مطلوب استعادته'}])}</div><label style="margin-top:10px">ملاحظة / استخدام المبلغ</label><textarea id="rm_note" rows="3"></textarea><div class="row" style="margin-top:14px"><button class="btn primary" onclick="saveReserveMovement('${bankId}','Support Draw')">حفظ سجل المراقبة</button></div>`)
   return;
 }
 const {data,error}=await sb.rpc('get_recoverable_reserve_uses',{p_bank_account_id:bankId});
 if(error)return alert(error.message);
 const uses=data||[];
 if(!uses.length)return alert(displayText('لا توجد مبالغ مطلوبة الاستعادة على هذا الحساب.'));
 const opts=uses.map(x=>({value:`${x.source_type==='Payment'?'P':'M'}:${x.source_id}`,label:`${x.use_date||'—'} — ${x.source_type==='Payment'?displayText('دفعة منفذة'):displayText('سحب دعم خارجي')} — ${money(x.outstanding_amount)} — ${x.note||''}`}));
 showModal('تسجيل استعادة مبلغ للحساب المحمي',`<div class="note">${esc(b.bank_name)} — ${esc(b.account_name)} — ${esc(accountTypeLabel(b.account_type))}</div><div class="modal-grid" style="margin-top:10px">${select('rm_target','المبلغ المطلوب استعادته',opts)}${input('rm_amount','مبلغ الاستعادة',0,'number')}${input('rm_date','التاريخ',new Date().toISOString().slice(0,10),'date')}</div><label style="margin-top:10px">ملاحظة</label><textarea id="rm_note" rows="3"></textarea><div class="row" style="margin-top:14px"><button class="btn primary" onclick="saveReserveMovement('${bankId}','Restoration')">حفظ سجل الاستعادة</button></div>`)
}
async function saveReserveMovement(bankId,type){
 const amount=Number(val('rm_amount')||0);if(amount<=0)return alert('أدخل مبلغًا أكبر من صفر.');
 const args={p_bank_account_id:bankId,p_movement_type:type,p_amount:amount,p_movement_date:val('rm_date')||null,p_note:val('rm_note')||null};
 if(type==='Support Draw')args.p_requires_restoration=val('rm_requires')!=='false';
 else{
   const target=val('rm_target')||'',parts=target.split(':');
   if(parts.length!==2)return alert(displayText('حدد المبلغ الذي تتم استعادته.'));
   args.p_requires_restoration=null;
   args.p_restores_movement_id=parts[0]==='M'?parts[1]:null;
   args.p_restores_payment_id=parts[0]==='P'?parts[1]:null;
 }
 const {error}=await sb.rpc('record_reserve_movement',args);if(error)return alert(error.message);closeModal();await reloadAll();
}'''
s=s[:old_start]+new_block+s[old_end:]

# Enrich reserve movement report with recoverability and restoration status while keeping position report unchanged.
old_rpc="sb.rpc('get_reserve_account_movement_report',{p_bank_account_id:bank,p_from:val('rr_from')||null,p_to:val('rr_to')||null})"
s=s.replace(old_rpc,"sb.rpc('get_reserve_account_movement_report_v2',{p_bank_account_id:bank,p_from:val('rr_from')||null,p_to:val('rr_to')||null})",1)
old_table='`<div class="table-wrap"><table><thead><tr><th>التاريخ</th><th>الحساب</th><th>الحركة</th><th>المصدر</th><th>المبلغ</th><th>البيان</th></tr></thead><tbody>${reserveReportRows.map(r=>`<tr><td>${esc(r.movement_date||\'—\')}</td><td>${esc(r.bank_name)} — ${esc(r.account_name)}</td><td>${esc(r.movement_type)}</td><td>${esc(r.source)}</td><td>${moneyHtml(r.amount)}</td><td>${esc(r.note||\'—\')}</td></tr>`).join(\'\')||\'<tr><td colspan="6">—</td></tr>\'}</tbody></table></div>`'
new_table='`<div class="table-wrap"><table><thead><tr><th>التاريخ</th><th>الحساب</th><th>الحركة</th><th>المصدر</th><th>المبلغ</th><th>مطلوب استعادته؟</th><th>المسترد</th><th>المتبقي</th><th>حالة الاسترداد</th><th>البيان</th></tr></thead><tbody>${reserveReportRows.map(r=>`<tr><td>${esc(r.movement_date||\'—\')}</td><td>${esc(r.bank_name)} — ${esc(r.account_name)}</td><td>${esc(r.movement_type)}</td><td>${esc(r.source)}</td><td>${moneyHtml(r.amount)}</td><td>${r.requires_restoration==null?\'—\':(r.requires_restoration?displayText(\'نعم\'):displayText(\'لا\'))}</td><td>${moneyHtml(r.restored_amount||0)}</td><td>${moneyHtml(r.outstanding_amount||0)}</td><td>${esc(displayText(r.recovery_status||\'—\'))}</td><td style="white-space:normal">${esc(r.note||\'—\')}</td></tr>`).join(\'\')||\'<tr><td colspan="10">—</td></tr>\'}</tbody></table></div>`'
assert old_table in s, 'reserve movement report table not found'
s=s.replace(old_table,new_table,1)
old_csv="return [['Date','Account','Movement','Source','Amount','Note'],...reserveReportRows.map(r=>[r.movement_date,`${r.bank_name} - ${r.account_name}`,r.movement_type,r.source,r.amount,r.note||''])]"
new_csv="return [['Date','Account','Movement','Source','Amount','Requires Restoration','Restored Amount','Outstanding Amount','Recovery Status','Note'],...reserveReportRows.map(r=>[r.movement_date,`${r.bank_name} - ${r.account_name}`,r.movement_type,r.source,r.amount,r.requires_restoration==null?'':(r.requires_restoration?'Yes':'No'),r.restored_amount||0,r.outstanding_amount||0,r.recovery_status||'',r.note||''])]"
assert old_csv in s, 'reserve CSV not found'
s=s.replace(old_csv,new_csv,1)

# Bilingual labels for the new UI text.
i18n_marker='Object.assign(I18N_AR_EN,{'
addition='''Object.assign(I18N_AR_EN,{\n"هل الدعم مطلوب استعادته؟":"Is restoration required?","نعم — مطلوب استعادته":"Yes — restoration required","لا — غير مطلوب استعادته":"No — no restoration required","مطلوب استعادته؟":"Restoration Required?","المسترد":"Restored","المتبقي":"Outstanding","حالة الاسترداد":"Recovery Status","سحب دعم خارجي":"External Support Draw","دفعة منفذة":"Executed Payment","لا توجد مبالغ مطلوبة الاستعادة على هذا الحساب.":"No recoverable amounts are outstanding on this account.","حدد المبلغ الذي تتم استعادته.":"Select the amount being restored.","Not Required":"Not Required","Not Restored":"Not Restored","Partially Restored":"Partially Restored","Restored":"Restored","Restoration":"Restoration",'''
assert i18n_marker in s
s=s.replace(i18n_marker,addition,1)

p.write_text(s)
print('patched CFO controls and reserve recovery UI')
