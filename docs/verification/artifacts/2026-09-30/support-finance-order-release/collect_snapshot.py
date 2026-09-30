"""Read-only remote inventory collector. Prints hashes/identities, never configs."""
import hashlib,json,subprocess
from datetime import datetime,timezone

def run(*cmd):
    p=subprocess.run(cmd,capture_output=True,text=True,check=False)
    if p.returncode:raise RuntimeError('read-only inventory command failed')
    return p.stdout.strip()
def sha(path):
    try:
        with open(path,'rb') as f:return hashlib.sha256(f.read()).hexdigest()
    except FileNotFoundError:return None
API_SOURCES=['services/business-api/app/api/recharge.py', 'services/business-api/app/api/support_payout.py', 'services/business-api/app/integrations/tron/reader.py', 'services/business-api/app/modules/identity/operation_password.py', 'services/business-api/app/modules/identity/support_order_auth.py', 'services/business-api/app/modules/identity/totp.py', 'services/business-api/app/modules/ledger/service.py', 'services/business-api/app/modules/recharge/models.py', 'services/business-api/app/modules/recharge/service.py', 'services/business-api/app/modules/recharge/workflow.py', 'services/business-api/app/modules/wallet/binding_adapters.py', 'services/business-api/app/modules/wallet/conversions.py', 'services/business-api/app/modules/wallet/manual_payouts.py', 'services/business-api/app/modules/wallet/recharge_binding_gate.py', 'services/business-api/app/modules/wallet/recharge_receipts.py', 'services/business-api/app/modules/wallet/runtime.py', 'services/business-api/app/modules/wallet/service.py', 'services/business-api/app/modules/wallet/support_payout.py', 'services/business-api/migrations/versions/0093_support_finance_order_recovery.py']
WORKER_PAIRS=[('services/business-api/app/modules/ledger/service.py', '/opt/business-api/app/modules/ledger/service.py'), ('services/business-api/app/modules/ledger/service.py', '/usr/local/lib/python3.12/site-packages/app/modules/ledger/service.py'), ('services/business-api/app/modules/wallet/conversions.py', '/opt/business-api/app/modules/wallet/conversions.py'), ('services/business-api/app/modules/wallet/conversions.py', '/usr/local/lib/python3.12/site-packages/app/modules/wallet/conversions.py'), ('services/business-api/app/modules/wallet/manual_payouts.py', '/opt/business-api/app/modules/wallet/manual_payouts.py'), ('services/business-api/app/modules/wallet/manual_payouts.py', '/usr/local/lib/python3.12/site-packages/app/modules/wallet/manual_payouts.py'), ('services/business-api/app/modules/wallet/service.py', '/opt/business-api/app/modules/wallet/service.py'), ('services/business-api/app/modules/wallet/service.py', '/usr/local/lib/python3.12/site-packages/app/modules/wallet/service.py'), ('services/business-api/app/modules/wallet/support_payout.py', '/opt/business-api/app/modules/wallet/support_payout.py'), ('services/business-api/app/modules/wallet/support_payout.py', '/usr/local/lib/python3.12/site-packages/app/modules/wallet/support_payout.py'), ('services/business-api/migrations/versions/0093_support_finance_order_recovery.py', '/opt/business-api/migrations/versions/0093_support_finance_order_recovery.py')]
STATIC_SOURCES=['frontend/src/admin-api.js', 'frontend/src/admin-recharge-panel.js', 'frontend/src/admin-support-payout-panel.js', 'frontend/src/styles/admin-wallet.css']
def main():
    roles={}
    for role in ('api','worker'):
        info=json.loads(run('docker','inspect','starchat-business-'+role+'-1'))[0]
        config=info['Config']['Labels']['com.docker.compose.project.config_files']
        if ',' in config:raise ValueError('multi-source Compose needs independent baseline review')
        files=[(source,'/opt/business-api/'+source.removeprefix('services/business-api/')) for source in API_SOURCES] if role=='api' else WORKER_PAIRS
        code='import hashlib,json,pathlib,sys; pairs=json.loads(sys.argv[1]); print(json.dumps({dest:hashlib.sha256(pathlib.Path(dest).read_bytes()).hexdigest() if pathlib.Path(dest).is_file() else None for source,dest in pairs}))'
        hashes=json.loads(run('docker','exec','starchat-business-'+role+'-1','python','-c',code,json.dumps(files)))
        roles[role]={'base_image':info['Image'],'compose_path':config,'compose_sha256':sha(config),'health':info['State'].get('Health',{}).get('Status'),'restarts':info['RestartCount'],'files':[{'source':source,'dest':dest,'before_sha256':hashes[dest]} for source,dest in files]}
    postgres=json.loads(run('docker','inspect','starchat-business-postgres-1'))[0]['Image']
    schema=run('docker','exec','starchat-business-postgres-1','sh','-c','psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atqc "select version_num from alembic_version"')
    print(json.dumps({'captured_utc':datetime.now(timezone.utc).isoformat(),'schema':schema,'roles':roles,'clone_image':postgres,
      'guard_sha256':sha('/opt/starchat/ops/refresh-guards/business_release_guard.py'),'guard_probe_sha256':sha('/opt/starchat/ops/refresh-guards/business_refresh_image_probe.py'),
      'static':[{'source':source,'dest':source.removeprefix('frontend/'),'before_sha256':sha('/opt/starchat/'+source)} for source in STATIC_SOURCES]}))
if __name__=='__main__':main()
