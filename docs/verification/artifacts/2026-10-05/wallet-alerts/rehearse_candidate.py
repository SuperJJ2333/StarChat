import subprocess,json,os,time,secrets
from pathlib import Path
root=Path('/opt/starchat/releases/wallet-alerts-20261005');private=root/'private';images=json.loads((root/'images.json').read_text());summary=json.loads((root/'baseline-summary.json').read_text())
def run(args,**kwargs):
 result=subprocess.run(args,capture_output=True,**kwargs)
 if result.returncode:
  print(result.stderr.decode() if isinstance(result.stderr,bytes) else result.stderr)
  raise RuntimeError('Isolated rehearsal command failed')
 return result
proof=run(['python3','/opt/starchat/ops/refresh-guards/business_release_guard.py','check','--api-image',images['api'],'--worker-image',images['worker']],text=True)
(root/'protocol-proof.json').write_text(proof.stdout)
pg=json.loads(run(['docker','inspect','starchat-business-postgres-1'],text=True).stdout)[0]
env=dict(item.split('=',1) for item in pg['Config']['Env'] if '=' in item)
db=env.get('POSTGRES_DB',env['POSTGRES_USER']);user=env['POSTGRES_USER']
dump=private/'business.dump'
if not dump.exists():
 with dump.open('wb') as out:
  subprocess.run(['docker','exec','starchat-business-postgres-1','pg_dump','-U',user,'-d',db,'-Fc','--no-owner','--no-acl'],stdout=out,check=True)
 os.chmod(dump,0o600)
network='wallet-alerts-rehearsal-20261005';name='wallet-alerts-rehearsal-pg-20261005'
if subprocess.run(['docker','network','inspect',network],capture_output=True).returncode:run(['docker','network','create','--internal',network])
credentials=private/'rehearsal.json'
if credentials.exists():password=json.loads(credentials.read_text())['password']
else:
 password=secrets.token_hex(24);credentials.write_text(json.dumps({'password':password}));os.chmod(credentials,0o600)
if subprocess.run(['docker','inspect',name],capture_output=True).returncode:
 run(['docker','run','-d','--name',name,'--network',network,'-e','POSTGRES_USER=fixture','-e','POSTGRES_DB=fixture','-e','POSTGRES_PASSWORD='+password,pg['Image']])
for _ in range(60):
 if subprocess.run(['docker','exec',name,'pg_isready','-U','fixture'],capture_output=True).returncode==0:break
 time.sleep(1)
else:raise RuntimeError('Rehearsal database not ready')
url='postgresql+psycopg://fixture:'+password+'@'+name+':5432/fixture'
# Restore separately for each role; financial originals remain in production untouched.
results=[]
for role in ('api','worker'):
 run(['docker','exec',name,'psql','-U','fixture','-d','postgres','-c','DROP DATABASE IF EXISTS fixture WITH (FORCE)'])
 run(['docker','exec',name,'createdb','-U','fixture','fixture'])
 with dump.open('rb') as source:
  subprocess.run(['docker','exec','-i',name,'pg_restore','-U','fixture','-d','fixture','--no-owner','--no-privileges','--exit-on-error'],stdin=source,check=True,capture_output=True)
 common=['docker','run','--rm','--network',network,'-e','BUSINESS_DATABASE_URL='+url]
 migration=run(common+['-w','/opt/business-api','--entrypoint','python',images['api'],'-m','alembic','upgrade','head'],text=True)
 (private/(role+'-migration.log')).write_text(migration.stdout+migration.stderr)
 probe=run(common+['-e','PROBE_ROLE='+role,'-e','PYTHONPATH='+('/opt/business-api' if role=='api' else '/opt/business-worker/app'),'-v',str(root/'domain_probe.py')+':/tmp/domain_probe.py:ro','--entrypoint','python',images[role],'/tmp/domain_probe.py'],text=True)
 (root/(role+'-domain-proof.json')).write_text(probe.stdout)
 results.append({'role':role,'passed':True})
watch=run(['docker','run','--rm','--network','none','-v',str(root/'watch-source')+':/opt/tron:ro','-e','PYTHONPATH=/opt','--entrypoint','python',summary['watch']['image'],'-c',"from tron.reader import TronTemporaryReadError;from tron.observer import Observer;assert TronTemporaryReadError('SOURCE_NETWORK_ERROR').reason=='SOURCE_NETWORK_ERROR';print('WATCH_IMPORT_PASS')"],text=True)
(root/'watch-proof.txt').write_text(watch.stdout)
print(json.dumps({'restored_database':True,'migration':'0095_wallet_source_alerts','results':results,'watch':watch.stdout.strip()}))
