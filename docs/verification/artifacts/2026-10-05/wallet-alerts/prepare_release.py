import json,subprocess,os,copy,sys
from pathlib import Path
root=Path('/opt/starchat/releases/wallet-alerts-20261005');private=root/'private'
sys.path.insert(0,'/opt/starchat/ops/refresh-guards')
from business_release_guard import escape_interpolation
def run(args):return subprocess.run(args,capture_output=True,text=True,check=True).stdout
summary=json.loads((root/'baseline-summary.json').read_text());rollback={}
for role in ('api','worker'):
 base='starchat-wallet-alerts-'+role+'-base:20261005'
 paths=['app/modules/wallet/alert_context.py','app/modules/wallet/incident_models.py','app/modules/wallet/alert_delivery.py','migrations/versions/0095_wallet_source_alerts.py']
 if role=='worker':paths+=['integrations/email_sender.py','tasks/wallet_alert_email.py']
 lines=['FROM '+base]
 for rel in paths:
  dest='/opt/business-api/'+rel if role=='api' or rel.startswith('migrations/') else ('/usr/local/lib/python3.12/site-packages/'+rel if rel.startswith('app/') else '/opt/business-worker/app/'+rel)
  lines.append('COPY '+role+'/'+rel+' '+dest)
  if role=='worker' and rel.startswith('app/'):lines.append('COPY '+role+'/'+rel+' /opt/business-api/'+rel)
 dockerfile=root/'overlay'/('Dockerfile.rollback.'+role);dockerfile.write_text('\n'.join(lines)+'\n')
 tag='starchat-wallet-alerts-'+role+'-rollback:20261005'
 run(['docker','build','--network=none','-f',str(dockerfile),'-t',tag,str(root/'overlay')])
 rollback[role]=json.loads(run(['docker','image','inspect',tag]))[0]['Id']
(root/'rollback-images.json').write_text(json.dumps(rollback))
proof=run(['python3','/opt/starchat/ops/refresh-guards/business_release_guard.py','check','--api-image',rollback['api'],'--worker-image',rollback['worker']])
(root/'rollback-protocol-proof.json').write_text(proof)
base=json.loads((private/'base-compose.json').read_text())
assert set(base['services'])=={'business-api','business-worker'}
for version,mapping in [('candidate',json.loads((root/'images.json').read_text())),('rollback',rollback)]:
 config=copy.deepcopy(base)
 for role in ('api','worker'):config['services']['business-'+role]['image']=mapping[role]
 path=private/(version+'-compose.json');path.write_text(json.dumps(escape_interpolation(config)));os.chmod(path,0o600)
 rendered=json.loads(run(['docker','compose','-p','starchat','-f',str(path),'config','--format','json']))
 for role in ('api','worker'):
  actual=copy.deepcopy(rendered['services']['business-'+role]);expected=copy.deepcopy(base['services']['business-'+role]);actual.pop('image');expected.pop('image');assert actual==expected
watch=json.loads((private/'watch-inspect.json').read_text());labels=watch['Config']['Labels'];project=labels['com.docker.compose.project'];service=labels['com.docker.compose.service']
cmd=['docker','compose','-p',project]
for path in labels['com.docker.compose.project.config_files'].split(','):cmd+=['-f',path]
watchenv=dict(item.split('=',1) for item in watch['Config']['Env'] if '=' in item)
renderenv={**os.environ,**watchenv,'TRON_WATCH_IMAGE':summary['watch']['image'],'TRON_WATCH_SOURCE_DIR':summary['watch']['source_mount'],'TRON_WATCH_DATA_DIR':next(m['Source'] for m in watch['Mounts'] if m['Destination']=='/data')}
render=subprocess.run(cmd+['config','--format','json'],env=renderenv,capture_output=True,text=True)
if render.returncode:
 error=render.stderr
 for value in sorted(watchenv.values(),key=len,reverse=True):
  if value:error=error.replace(value,'REDACTED')
 print(error);raise RuntimeError('Watch render failed')
watchbase=json.loads(render.stdout);assert set(watchbase['services'])=={service}
for key,value in watchbase['services'][service]['environment'].items():assert watchenv[key]==str(value)
watchbase['services'][service]['image']=summary['watch']['image']
for version in ('candidate','rollback'):
 config=copy.deepcopy(watchbase)
 if version=='candidate':
  volume=next(v for v in config['services'][service]['volumes'] if v['target']=='/opt/tron');assert volume['source']==summary['watch']['source_mount'];volume['source']=str(root/'watch-source')
 path=private/(version+'-watch.json');path.write_text(json.dumps(escape_interpolation(config)));os.chmod(path,0o600)
 rendered=json.loads(run(['docker','compose','-p',project,'-f',str(path),'config','--format','json']))
 assert rendered==config
(root/'config-proof.json').write_text(json.dumps({'business_roles_preserved':True,'watch_project':project,'watch_service':service,'watch_only_source_changed':True,'rollback_images':rollback}))
print((root/'config-proof.json').read_text())
