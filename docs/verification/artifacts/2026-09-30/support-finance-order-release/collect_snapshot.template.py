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
API_SOURCES=__API_SOURCES__
WORKER_PAIRS=__WORKER_PAIRS__
STATIC_SOURCES=__STATIC_SOURCES__
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
