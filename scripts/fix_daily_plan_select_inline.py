from pathlib import Path
p=Path('index.html')
s=p.read_text(encoding='utf-8')
needle='function renderSavedViews(){'
helper='''function selectInline(cls,id,items,value=""){return `<select class="${esc(cls)}" data-id="${esc(id)}">${(items||[]).map(x=>{const v=x&&typeof x==='object'?(x.value??''):x;const l=x&&typeof x==='object'?(x.label??v):x;return `<option value="${esc(v)}" ${String(v)===String(value)?'selected':''}>${esc(l)}</option>`}).join('')}</select>`}\n'''
if 'function selectInline(' in s:
    raise SystemExit('selectInline already exists')
if needle not in s:
    raise SystemExit('anchor not found')
s=s.replace(needle,helper+needle,1)
p.write_text(s,encoding='utf-8')
