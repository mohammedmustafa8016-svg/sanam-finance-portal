/* Pure import validation shared by the browser and regression checks. */
(function(root){
 'use strict';
 const fields=['source_id','amount','currency','posting_date','due_date','document_no','beneficiary','description'];
 function parseCsv(text,delimiter=','){
  if(![',',';','\t'].includes(delimiter))throw Error('INVALID_DELIMITER');
  if(text.length>5*1024*1024)throw Error('FILE_TOO_LARGE');
  text=text.replace(/^\uFEFF/,'');
  const rows=[];let row=[],cell='',quoted=false,closed=false;
  for(let i=0;i<text.length;i++){
   const ch=text[i];
   if(quoted){if(ch==='"'&&text[i+1]==='"'){cell+='"';i++;}else if(ch==='"'){quoted=false;closed=true;}else cell+=ch;continue;}
   if(ch==='"'){if(cell||closed)throw Error('INVALID_CSV_QUOTE');quoted=true;continue;}
   if(ch===delimiter){row.push(cell);cell='';closed=false;continue;}
   if(ch==='\n'||ch==='\r'){
    if(ch==='\r'&&text[i+1]==='\n')i++;
    row.push(cell);if(row.some(x=>x.trim()))rows.push(row);row=[];cell='';closed=false;
    if(rows.length>5001)throw Error('TOO_MANY_ROWS');continue;
   }
   if(closed&&!/\s/.test(ch))throw Error('INVALID_CSV_QUOTE');
   if(!closed)cell+=ch;
  }
  if(quoted)throw Error('UNCLOSED_CSV_QUOTE');
  row.push(cell);if(row.some(x=>x.trim()))rows.push(row);
  if(rows.length<2||rows.length>5001)throw Error('INVALID_ROW_COUNT');
  const headers=rows.shift().map(x=>x.trim());
  if(headers.some(x=>!x)||new Set(headers).size!==headers.length)throw Error('DUPLICATE_OR_EMPTY_HEADER');
  if(rows.some(row=>row.length!==headers.length))throw Error('INCONSISTENT_COLUMNS');
  return {headers,rows};
 }
 function isoDate(value){
  if(!/^\d{4}-\d{2}-\d{2}$/.test(value)||!Number.isFinite(Date.parse(value+'T00:00:00Z'))||new Date(value+'T00:00:00Z').toISOString().slice(0,10)!==value)throw Error('INVALID_ISO_DATE');
  return value;
 }
 function amount(value,decimal='.',group='none'){
  if(!['.',','].includes(decimal)||!['none',',','.',' '].includes(group)||decimal===group)throw Error('INVALID_NUMBER_FORMAT');
  let raw=String(value).trim();
  const esc=x=>x.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
  const integer=group==='none'?'[0-9]+':`(?:[0-9]+|[0-9]{1,3}(?:${esc(group)}[0-9]{3})+)`;
  if(!new RegExp(`^[+-]?${integer}(?:${esc(decimal)}[0-9]{1,2})?$`).test(raw))throw Error('INVALID_AMOUNT');
  if(group!=='none')raw=raw.split(group).join('');
  raw=raw.replace(decimal,'.');
  const valueNumber=Number(raw);
  // Confirm that JSON's numeric representation preserves the original cents.
  const cents=text=>{
   if(!/^[+-]?[0-9]+(?:\.[0-9]{1,2})?$/.test(text))return null;
   const negative=text.startsWith('-'),parts=text.replace(/^[+-]/,'').split('.');
   const result=BigInt(parts[0])*100n+BigInt((parts[1]||'').padEnd(2,'0'));
   return negative?-result:result;
  };
  if(!Number.isFinite(valueNumber)||Math.abs(valueNumber)>90071992547409.9||cents(String(valueNumber))!==cents(raw))throw Error('AMOUNT_OUT_OF_RANGE');
  return valueNumber;
 }
 function mapRows(parsed,mapping,options={}){
  const required=['source_id','amount','currency','posting_date'];
  for(const key of required)if(!parsed.headers.includes(mapping[key]))throw Error('MISSING_MAPPING:'+key);
  const mapped=fields.map(key=>mapping[key]).filter(Boolean);
  if(new Set(mapped).size!==mapped.length)throw Error('DUPLICATE_MAPPING');
  const seen=new Set();
  return parsed.rows.map((row,index)=>{
   const value=key=>mapping[key]?String(row[parsed.headers.indexOf(mapping[key])]||'').trim():'';
   try{
    const id=value('source_id');if(!id||id.length>200)throw Error('INVALID_SOURCE_ID');if(seen.has(id))throw Error('DUPLICATE_SOURCE_ID');seen.add(id);
    const currency=value('currency').toUpperCase();if(!/^[A-Z]{3}$/.test(currency))throw Error('INVALID_CURRENCY');
    const result={source_id:id,amount:amount(value('amount'),options.decimal||'.',options.group||'none'),currency,posting_date:isoDate(value('posting_date'))};
    for(const key of ['document_no','beneficiary','description'])result[key]=value(key);
    result.due_date=value('due_date')?isoDate(value('due_date')):null;
    return result;
   }catch(error){throw Error(`ROW_${index+2}: ${error.message}`);}
  });
 }
 const api={fields,parseCsv,mapRows,amount,isoDate};
 if(typeof module!=='undefined'&&module.exports)module.exports=api;
 else root.SanamOperationsCore=Object.freeze(api);
})(typeof window!=='undefined'?window:globalThis);
