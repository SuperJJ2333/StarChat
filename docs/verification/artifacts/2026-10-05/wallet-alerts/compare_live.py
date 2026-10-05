from pathlib import Path
import tarfile,subprocess,difflib,json
root=Path('docs/verification/artifacts/2026-10-05/wallet-alerts')
with tarfile.open(root/'source-baseline.tar') as tar:tar.extractall(root/'live-source',filter='data')
diffs=[];summary=[]
for file in (root/'live-source').rglob('*.py'):
 rel=file.relative_to(root/'live-source');role=rel.parts[0];item=Path(*rel.parts[1:])
 if role=='watch': path=Path('services/business-api/app/integrations/tron')/item
 elif str(item).replace('\\','/').startswith('app/'):path=Path('services/business-api')/item
 else:path=Path('services/business-worker/app')/item
 base=subprocess.check_output(['git','show','HEAD:'+path.as_posix()]).decode('utf-8').replace('\r\n','\n')
 live=file.read_text(encoding='utf-8').replace('\r\n','\n')
 if live!=base:
  delta=list(difflib.unified_diff(base.splitlines(True),live.splitlines(True),fromfile='HEAD/'+path.as_posix(),tofile='LIVE/'+rel.as_posix()))
  diffs.extend(delta);summary.append({'role':role,'path':path.as_posix(),'diff_lines':len(delta)})
(root/'source-drift.diff').write_text(''.join(diffs),encoding='utf-8')
print(json.dumps(summary))
