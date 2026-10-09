import json,subprocess,collections,time
from pathlib import Path
root=Path('/opt/starchat/releases/wallet-alerts-20261005')
source=(root/'deploy_release.py').read_text();exec(compile(source[:source.index("for role in ('api','worker','watch'):")],str(root/'deploy_release.py'),'exec'))
query="""import json;from sqlalchemy import select,create_engine;from app.core.config import Settings;from app.core.database import create_session_factory;from app.modules.wallet.monitoring import WalletMonitorHeartbeat;from app.modules.wallet.incident_models import WalletSourceAlertState;f=create_session_factory(create_engine(Settings().database_url));
with f() as s:
 rows=list(s.scalars(select(WalletMonitorHeartbeat)));state=s.get(WalletSourceAlertState,'global');print(json.dumps({'heartbeats':[{'id':r.id,'last_attempt_at':r.last_attempt_at.isoformat(),'last_success_at':r.last_success_at.isoformat() if r.last_success_at else None,'last_error_code':r.last_error_code} for r in rows],'source_alert_state':None if state is None else {'failed_since':state.failed_since.isoformat() if state.failed_since else None,'healthy_count':state.healthy_count,'conditions':state.latest_context.get('failed_conditions',[])}}))
"""
proof=json.loads(run(['docker','exec','-e','PYTHONPATH=/opt/business-api','starchat-business-api-1','python','-c',query]).splitlines()[-1]);proof['validated_prerequisites']=True
errors={}
for name in ('starchat-business-api-1','starchat-business-worker-1','starchat-tron-watch-tron-watch-1'):
 result=subprocess.run(['docker','logs','--since','10m',name],capture_output=True,text=True);count=collections.Counter()
 for line in (result.stdout+'\n'+result.stderr).splitlines():
  try:row=json.loads(line)
  except ValueError:continue
  if row.get('level') in ('ERROR','CRITICAL'):count[(str(row.get('event','UNKNOWN')),str(row.get('reason_code','UNKNOWN')))]+=1
 errors[name]=[{'event':key[0],'reason':key[1],'count':value} for key,value in count.items()]
proof['structured_errors']=errors
result=run(['curl','--silent','--show-error','--output','/dev/null','--write-out','%{http_code}','https://liuhetong888.com/api/v1/admin/wallet/incidents']);assert result=='401',result;proof['anonymous_admin_status']=int(result)
(root/'operational-proof.json').write_text(json.dumps(proof));print(json.dumps(proof))
