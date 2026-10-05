from pathlib import Path
import difflib,subprocess,json,hashlib,tarfile
root=Path('docs/verification/artifacts/2026-10-05/wallet-alerts');live_root=root/'live-source';overlay=root/'overlay'
manifest=[]
for file in live_root.rglob('*.py'):
 rel=file.relative_to(live_root);role=rel.parts[0];item=Path(*rel.parts[1:])
 if role=='watch':path=Path('services/business-api/app/integrations/tron')/item
 elif item.as_posix().startswith('app/'):path=Path('services/business-api')/item
 else:path=Path('services/business-worker/app')/item
 base=subprocess.check_output(['git','show','HEAD:'+path.as_posix()]).decode('utf-8').replace('\r\n','\n')
 live=file.read_text(encoding='utf-8');candidate=path.read_text(encoding='utf-8')
 for tag,a,b,c,d in reversed(difflib.SequenceMatcher(None,base.splitlines(True),live.splitlines(True),autojunk=False).get_opcodes()):
  if tag=='equal':continue
  old=''.join(base.splitlines(True)[a:b]);new=''.join(live.splitlines(True)[c:d])
  if not old or candidate.count(old)!=1:raise RuntimeError('Unsafe drift integration: '+str(rel))
  candidate=candidate.replace(old,new,1)
 out=overlay/rel;out.parent.mkdir(parents=True,exist_ok=True);out.write_text(candidate,encoding='utf-8',newline='\n')
 manifest.append({'role':role,'path':item.as_posix(),'sha256':hashlib.sha256(out.read_bytes()).hexdigest()})
for role in ('api','worker'):
 for item in ('app/modules/wallet/alert_context.py','migrations/versions/0095_wallet_source_alerts.py'):
  source=Path('services/business-api')/item;out=overlay/role/item;out.parent.mkdir(parents=True,exist_ok=True);out.write_text(source.read_text(encoding='utf-8'),encoding='utf-8',newline='\n')
  manifest.append({'role':role,'path':item,'sha256':hashlib.sha256(out.read_bytes()).hexdigest()})
(root/'overlay-manifest.json').write_text(json.dumps(manifest),encoding='utf-8')
with tarfile.open(root/'overlay.tar','w') as tar:
 for file in overlay.rglob('*.py'):tar.add(file,arcname=str(file.relative_to(overlay)))
print(json.dumps({'files':len(manifest),'sha256':hashlib.sha256((root/'overlay.tar').read_bytes()).hexdigest()}))
