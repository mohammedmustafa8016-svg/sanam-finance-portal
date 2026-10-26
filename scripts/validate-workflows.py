"""Parse workflow YAML and compile the two embedded Python patchers, never run them."""
import ast
from pathlib import Path
import re
import yaml

root=Path(__file__).resolve().parents[1]
for path in sorted((root/'.github/workflows').glob('*.yml')):
    config=yaml.safe_load(path.read_text(encoding='utf-8'))
    assert isinstance(config,dict) and 'jobs' in config,path
    if path.name in ('fix-all-add-actions.yml','fix-bank-modal.yml'):
        script=config['jobs']['patch']['steps'][1 if path.name=='fix-all-add-actions.yml' else 1]['run']
        code=re.search(r"python - <<'PY'\n(.*?)\nPY",script,re.S).group(1)
        ast.parse(code,filename=str(path))
    print('PASS:',path.relative_to(root))
