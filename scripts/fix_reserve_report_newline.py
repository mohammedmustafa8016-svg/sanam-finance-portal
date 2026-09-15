from pathlib import Path
p=Path('index.html')
s=p.read_text()
s=s.replace("join('\r\n'),blob", "join(String.fromCharCode(13,10)),blob")
s=s.replace("join('\n'),blob", "join(String.fromCharCode(13,10)),blob")
p.write_text(s)
