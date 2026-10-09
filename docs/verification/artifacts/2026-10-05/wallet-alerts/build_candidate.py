import os,json,subprocess,tarfile,shutil,hashlib
from pathlib import Path
root=Path('/opt/starchat/releases/wallet-alerts-20261005');summary=json.loads((root/'baseline-summary.json').read_text());overlay=root/'overlay'
with tarfile.open(root/'overlay.tar') as tar:tar.extractall(overlay,filter='data')
manifest=json.loads((root/'overlay-manifest.json').read_text())
for item in manifest:
 path=overlay/item['role']/item['path']
 if hashlib.sha256(path.read_bytes()).hexdigest()!=item['sha256']:raise RuntimeError('Overlay mismatch')
images={}
for role in ('api','worker'):
 current=json.loads(subprocess.check_output(['docker','inspect','starchat-business-'+role+'-1']))[0]
 if current['Image']!=summary[role]['image'] or current['Id']!=summary[role]['id']:raise RuntimeError('Live drift')
 base='starchat-wallet-alerts-'+role+'-base:20261005';candidate='starchat-wallet-alerts-'+role+':20261005'
 subprocess.run(['docker','tag',summary[role]['image'],base],check=True)
 lines=['FROM '+base]
 for item in [x for x in manifest if x['role']==role]:
  rel=item['path'];src=role+'/'+rel
  if role=='api':dest='/opt/business-api/'+rel
  elif rel.startswith('app/'):dest='/usr/local/lib/python3.12/site-packages/'+rel
  elif rel.startswith('migrations/'):dest='/opt/business-api/'+rel
  else:dest='/opt/business-worker/app/'+rel
  lines.append('COPY '+src+' '+dest)
  if role=='worker' and rel.startswith('app/'):
   lines.append('COPY '+src+' /opt/business-api/'+rel)
 dockerfile=overlay/('Dockerfile.'+role);dockerfile.write_text('\n'.join(lines)+'\n')
 with (root/(role+'-build.log')).open('w') as log:
  subprocess.run(['docker','build','--network=none','-f',str(dockerfile),'-t',candidate,str(overlay)],stdout=log,stderr=subprocess.STDOUT,check=True)
 images[role]=json.loads(subprocess.check_output(['docker','image','inspect',candidate]))[0]['Id']
watch_source=Path(summary['watch']['source_mount']).resolve()
if not watch_source.is_relative_to('/opt/starchat/'):raise RuntimeError('Watch source outside workspace')
watch_candidate=root/'watch-source'
shutil.copytree(watch_source,watch_candidate,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__'))
for item in [x for x in manifest if x['role']=='watch']:
 shutil.copy2(overlay/'watch'/item['path'],watch_candidate/item['path'])
os.chmod(watch_candidate,0o755)
for file in watch_candidate.rglob('*.py'):os.chmod(file,0o644)
(root/'images.json').write_text(json.dumps(images))
(root/'rollback-images.json').write_text(json.dumps({r:summary[r]['image'] for r in ('api','worker')}))
print(json.dumps({'images':images,'watch_source_candidate':str(watch_candidate),'files_verified':len(manifest)}))
