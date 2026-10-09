import json,subprocess,hashlib,time,os
from pathlib import Path
root=Path('/opt/starchat/releases/wallet-alerts-20261005');private=root/'private';images=json.loads((root/'images.json').read_text());baseline=json.loads((root/'baseline-summary.json').read_text())
def run(args):return subprocess.run(args,capture_output=True,text=True,check=True).stdout
def inspect(name):return json.loads(run(['docker','inspect',name]))[0]
for proof in ('api-domain-proof.json','worker-domain-proof.json','rollback-domain-proof.json','protocol-proof.json','rollback-protocol-proof.json','config-proof.json'):
 assert (root/proof).is_file()
for role in ('api','worker'):
 proof=json.loads((root/(role+'-domain-proof.json')).read_text());assert proof['passed'] is True and proof['role']==role
rollback=json.loads((root/'rollback-images.json').read_text())
for filename,mapping in [('protocol-proof.json',images),('rollback-protocol-proof.json',rollback)]:
 proofs=json.loads((root/filename).read_text());assert len(proofs)==2 and {p['role'] for p in proofs}=={'api','worker'}
 for proof in proofs:assert proof['passed'] is True and proof['image']==mapping[proof['role']]
proofs=json.loads((root/'rollback-domain-proof.json').read_text());assert len(proofs)==3 and {p['role'] for p in proofs}=={'producer','api','worker'} and all(p['passed'] is True and p['cause_changed_compatible'] is True and p['receipt_replay_compatible'] is True for p in proofs)
for role in ('api','worker','watch'):
 name='starchat-tron-watch-tron-watch-1' if role=='watch' else 'starchat-business-'+role+'-1'
 assert inspect(name)['Id']==baseline[role]['id'],'Production changed since baseline'
snapshot="""import json;from sqlalchemy import select,text;from app.core.config import Settings;from app.core.database import create_session_factory;from sqlalchemy import create_engine;from app.modules.wallet.models import WalletControl;f=create_session_factory(create_engine(Settings().database_url));
with f() as s:
 c=s.get(WalletControl,'global');print(json.dumps({'schema':s.scalar(text('SELECT version_num FROM alembic_version')),'paused':c.withdrawals_paused,'reason':c.pause_reason}))
"""
def state():return json.loads(run(['docker','exec','-e','PYTHONPATH=/opt/business-api','starchat-business-api-1','python','-c',snapshot]).splitlines()[-1])
before=state();assert before['schema']=='0094_support_finance_order_recovery'
(root/'pre-deploy-control.json').write_text(json.dumps(before))
compose=private/'candidate-compose.json'
migration=run(['docker','compose','-p','starchat','-f',str(compose),'run','--rm','--no-deps','-w','/opt/business-api','--entrypoint','python','business-api','-m','alembic','upgrade','head'])
(private/'production-migration.log').write_text(migration);os.chmod(private/'production-migration.log',0o600)
assert state()['schema']=='0095_wallet_source_alerts'
switched=run(['python3','/opt/starchat/ops/refresh-guards/business_release_guard.py','deploy','--compose',str(compose),'--service','business-api','--service','business-worker'])
(root/'deployment-proof.json').write_text(switched)
run(['docker','compose','-p','starchat-tron-watch','-f',str(private/'candidate-watch.json'),'up','-d','--no-deps','--pull','never','--no-build','tron-watch'])
manifest=json.loads((root/'overlay-manifest.json').read_text())
for item in manifest:
 role=item['role'];rel=item['path'];name='starchat-tron-watch-tron-watch-1' if role=='watch' else 'starchat-business-'+role+'-1'
 path='/opt/tron/'+rel if role=='watch' else ('/opt/business-api/'+rel if role=='api' or rel.startswith('migrations/') else ('/usr/local/lib/python3.12/site-packages/'+rel if rel.startswith('app/') else '/opt/business-worker/app/'+rel))
 got=run(['docker','exec',name,'python','-c','import hashlib;print(hashlib.sha256(open('+repr(path)+',"rb").read()).hexdigest())']).strip();assert got==item['sha256']
for _ in range(60):
 containers=[inspect('starchat-business-api-1'),inspect('starchat-business-worker-1'),inspect('starchat-tron-watch-tron-watch-1')]
 if all(c['State']['Running'] and c['State'].get('Health',{}).get('Status','healthy')=='healthy' for c in containers):break
 time.sleep(1)
else:raise RuntimeError('Candidate health did not settle')
after=state();assert (before['paused'],before['reason'])==(after['paused'],after['reason'])
for role,c in zip(('api','worker','watch'),containers):
 assert c['Image']==(baseline['watch']['image'] if role=='watch' else images[role])
 old=json.loads((private/(role+'-inspect.json')).read_text())
 def envmap(items):return dict(item.split('=',1) if '=' in item else (item,None) for item in items)
 assert envmap(c['Config']['Env'])==envmap(old['Config']['Env']), 'Runtime environment changed: '+','.join(sorted(key for key in set(envmap(c['Config']['Env']))|set(envmap(old['Config']['Env'])) if envmap(c['Config']['Env']).get(key)!=envmap(old['Config']['Env']).get(key)))
 for key in ('User','WorkingDir','Entrypoint','Cmd','Healthcheck'):assert c['Config'].get(key)==old['Config'].get(key)
 oldmount=sorted((m['Type'],m['Source'],m['Destination'],m['RW']) for m in old['Mounts'])
 newmount=sorted((m['Type'],baseline['watch']['source_mount'] if role=='watch' and m['Destination']=='/opt/tron' else m['Source'],m['Destination'],m['RW']) for m in c['Mounts'])
 assert oldmount==newmount
 for key in ('Memory','NanoCpus','PidsLimit','ReadonlyRootfs','CapDrop','SecurityOpt','RestartPolicy'):assert c['HostConfig'].get(key)==old['HostConfig'].get(key)
changed={'/starchat-business-api-1','/starchat-business-worker-1','/starchat-tron-watch-tron-watch-1'}
for name,identity in baseline['containers'].items():
 if name not in changed:assert inspect(name)['Id']==identity,'Unrelated container changed'
ready=json.loads(run(['curl','--fail','--silent','--show-error','https://liuhetong888.com/api/v1/health/ready']))
proof={'images':images,'schema':after['schema'],'wallet_control_preserved':True,'wallet_paused':after['paused'],'source_files_verified':len(manifest),'runtime_config_preserved':True,'unrelated_containers_preserved':True,'ready':ready,'containers':[{'name':c['Name'],'id':c['Id'],'restarts':c['RestartCount'],'state':c['State']['Status'],'health':c['State'].get('Health',{}).get('Status')} for c in containers]}
(root/'production-proof.json').write_text(json.dumps(proof));print(json.dumps(proof))
