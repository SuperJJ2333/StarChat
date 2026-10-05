import subprocess,json,os,hashlib,tarfile
from pathlib import Path
root=Path('/opt/starchat/releases/wallet-alerts-20261005')
root.mkdir(mode=0o700,exist_ok=True)
os.chmod(root,0o700)
private=root/'private';private.mkdir(mode=0o700,exist_ok=True)
files=['app/integrations/tron/funding_source.py','app/integrations/tron/reader.py','app/integrations/tron/observer.py','app/modules/wallet/manual_reserve_monitor.py','app/modules/wallet/manual_source_resample.py','app/modules/wallet/incidents.py','app/modules/wallet/incident_models.py','app/modules/wallet/alert_delivery.py']
def inspect(name):
 return json.loads(subprocess.check_output(['docker','inspect',name]))[0]
names=['starchat-business-api-1','starchat-business-worker-1','starchat-tron-watch-tron-watch-1']
summary={};sources=root/'baseline';sources.mkdir(exist_ok=True)
for name in names:
 data=inspect(name);role={'starchat-business-api-1':'api','starchat-business-worker-1':'worker','starchat-tron-watch-tron-watch-1':'watch'}[name]
 (private/(role+'-inspect.json')).write_text(json.dumps(data));os.chmod(private/(role+'-inspect.json'),0o600)
 summary[role]={'image':data['Image'],'id':data['Id'],'files':{}}
 paths=files if role!='watch' else ['reader.py','observer.py']
 if role=='worker': paths+=['integrations/email_sender.py','tasks/wallet_alert_email.py']
 for rel in paths:
  base='/opt/business-api/' if role=='api' else '/usr/local/lib/python3.12/site-packages/'
  if role=='watch': base='/opt/tron/'
  if role=='worker' and not rel.startswith('app/'):base='/opt/business-worker/app/'
  out=sources/role/rel;out.parent.mkdir(parents=True,exist_ok=True)
  subprocess.run(['docker','cp',name+':'+base+rel,str(out)],check=True,capture_output=True)
  summary[role]['files'][rel]=hashlib.sha256(out.read_bytes()).hexdigest()
 if role in ('api','worker'):
  compose=data['Config']['Labels']['com.docker.compose.project.config_files']
  if ',' in compose: raise RuntimeError('Unexpected multiple frozen Compose inputs')
  conf=json.loads(subprocess.check_output(['docker','compose','-p','starchat','-f',compose,'config','--format','json']))
  (private/'base-compose.json').write_text(json.dumps(conf));os.chmod(private/'base-compose.json',0o600)
 elif role=='watch':
  summary[role]['source_mount']=next(m['Source'] for m in data['Mounts'] if m['Destination']=='/opt/tron')
summary['containers']={d['Name']:d['Id'] for d in json.loads(subprocess.check_output(['docker','inspect',*subprocess.check_output(['docker','ps','-q'],text=True).split()]))}
(root/'baseline-summary.json').write_text(json.dumps(summary))
with tarfile.open(root/'source-baseline.tar','w') as tar:
 for file in sources.rglob('*.py'): tar.add(file,arcname=str(file.relative_to(sources)))
print(json.dumps({'directory':str(root),'sources':sum(len(summary[r]['files']) for r in ('api','worker','watch')),'images':{r:summary[r]['image'] for r in ('api','worker','watch')}}))
