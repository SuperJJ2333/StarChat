import subprocess,json
from pathlib import Path
root=Path('/opt/starchat/releases/wallet-alerts-20261005');password=json.loads((root/'private/rehearsal.json').read_text())['password'];images=json.loads((root/'rollback-images.json').read_text());candidate=json.loads((root/'images.json').read_text())
proof=[]
for role,image in [('producer',candidate['api']),('api',images['api']),('worker',images['worker'])]:
 path='/opt/business-worker/app' if role=='worker' else '/opt/business-api'
 result=subprocess.run(['docker','run','--rm','--network','wallet-alerts-rehearsal-20261005','-e','BUSINESS_DATABASE_URL=postgresql+psycopg://fixture:'+password+'@wallet-alerts-rehearsal-pg-20261005:5432/fixture','-e','PROBE_ROLE='+role,'-e','PYTHONPATH='+path,'-v',str(root/'rollback_probe.py')+':/tmp/probe.py:ro','--entrypoint','python',image,'/tmp/probe.py'],capture_output=True,text=True)
 if result.returncode:print(result.stderr.replace(password,'REDACTED'));raise RuntimeError('Rollback rehearsal failed')
 proof.append(json.loads(result.stdout.splitlines()[-1]))
(root/'rollback-domain-proof.json').write_text(json.dumps(proof));print(json.dumps(proof))
