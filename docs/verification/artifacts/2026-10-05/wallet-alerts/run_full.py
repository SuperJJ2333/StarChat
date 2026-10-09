import subprocess,json,hashlib,re,time
from pathlib import Path
root=Path('docs/verification/artifacts/2026-10-05/wallet-alerts')
files=subprocess.check_output(['rg','--files','tests/business_api','tests/business_worker','-g','test_*.py'],text=True).splitlines()
groups=[[] for _ in range(4)];weights=[0]*4
for f in sorted(files,key=lambda f:len(Path(f).read_bytes()),reverse=True):
 i=min(range(4),key=lambda i:weights[i]);groups[i].append(f);weights[i]+=len(Path(f).read_bytes())
identity={f:hashlib.sha256(Path(f).read_bytes()).hexdigest() for f in files}
for base in ('services/business-api/app','services/business-worker/app'):
 for f in Path(base).rglob('*.py'):identity[str(f)]=hashlib.sha256(f.read_bytes()).hexdigest()
(root/'full-input-hashes.json').write_text(json.dumps(identity),encoding='utf-8')
started=time.monotonic();runs=[]
for i,files in enumerate(groups):
 log=(root/f'backend-shard-{i+1}.log').open('w',encoding='utf-8')
 cmd=['D:/pythonProject/outsource/StarChat/.venv/Scripts/python.exe','-m','pytest',*files,'-q','--tb=short','--durations=5']
 p=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT);runs.append((p,log,cmd))
(root/'full-commands.json').write_text(json.dumps([r[2] for r in runs]),encoding='utf-8')
results=[]
for i,(p,log,cmd) in enumerate(runs):
 code=p.wait();log.close();lines=(root/f'backend-shard-{i+1}.log').read_text(encoding='utf-8').splitlines()
 results.append({'shard':i+1,'exit_code':code,'summary':lines[-1] if lines else 'NO_OUTPUT'})
(root/'full-result.json').write_text(json.dumps({'seconds':time.monotonic()-started,'results':results}),encoding='utf-8')
print(json.dumps(results))
raise SystemExit(1 if any(r['exit_code'] for r in results) else 0)
