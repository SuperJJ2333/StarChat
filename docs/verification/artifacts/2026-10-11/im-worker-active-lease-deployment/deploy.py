"""Switch only reviewed worker after immutable image guards; preserve rollback."""
import fcntl,hashlib,json,os,signal,subprocess,sys,time,urllib.request
from pathlib import Path
ROOT=Path('/opt/starchat/releases/im-worker-active-lease-20261011')
PRIVATE=ROOT/'private'
GUARD=Path('/opt/starchat/ops/refresh-guards/business_release_guard.py')
PROBE=GUARD.with_name('business_refresh_image_probe.py')
os.umask(0o077)
if __name__ != '__main__' or sys.argv[1:] != ['--execute-after-android-publication']:
    raise SystemExit('prepared only; explicit post-Android execution is required')
roles=json.loads((ROOT/'services-manifest.json').read_text())['roles']
def emit(stage, **data):
    print(json.dumps({'stage': stage, **data}), flush=True)

def inspect(name):
    return json.loads(subprocess.check_output(['docker', 'inspect', name], timeout=10))[0]

def guard_identity():
    assert hashlib.sha256(GUARD.read_bytes()).hexdigest() == '46d98c6e2d9632b8168d20748b697744d89396852363f259d5eb0d83a7653b9b'
    assert hashlib.sha256(PROBE.read_bytes()).hexdigest() == '2a6de21ddc26b12bf4b0124365ba20834f821e0ea2d2700fe077f16e96b84a15'

def schema():
    return read_scalar('SELECT version_num FROM alembic_version')

def probe_https(path):
    with urllib.request.urlopen('https://liuhetong888.com' + path, timeout=10) as response:
        assert response.status == 200
        return json.load(response)

def same_runtime(old, new):
    for key in ('Env', 'Cmd', 'Entrypoint', 'User', 'WorkingDir', 'Healthcheck', 'ExposedPorts'):
        before, after = old['Config'].get(key), new['Config'].get(key)
        if key == 'Env':
            before, after = sorted(before or []), sorted(after or [])
        assert before == after, 'runtime Config drift: ' + key
    for key in ('PortBindings', 'RestartPolicy', 'LogConfig', 'Memory', 'NanoCpus', 'CpuQuota',
                'CpuPeriod', 'PidsLimit', 'ReadonlyRootfs', 'SecurityOpt', 'CapAdd', 'CapDrop', 'Ulimits', 'NetworkMode'):
        assert old['HostConfig'].get(key) == new['HostConfig'].get(key), 'runtime HostConfig drift: ' + key
    mounts = lambda item: sorted((m['Source'], m['Destination'], m['RW']) for m in item['Mounts'])
    assert mounts(old) == mounts(new), 'runtime mount drift'

def read_scalar(query):
    code = "from app.core.config import Settings;from sqlalchemy import create_engine,text;e=create_engine(Settings().database_url,connect_args={'connect_timeout':3});\nwith e.begin() as c:\n c.execute(text('SET TRANSACTION READ ONLY'))\n c.execute(text(\"SET LOCAL statement_timeout='5s'\"))\n print(c.execute(text("+repr(query)+")).scalar_one())\ne.dispose()"
    return subprocess.check_output(['docker','exec',roles['api']['name'],'python','-c',code],text=True,timeout=12).strip()

def processing_count():
    return int(read_scalar("SELECT count(*) FROM outbox_events WHERE status='PROCESSING'"))

def source_sha(name, target):
    code = ("import hashlib,stat;from pathlib import Path;p=Path(" + repr(target) + ");\n"
            "try:s=p.lstat()\nexcept FileNotFoundError:print('ABSENT')\n"
            "else:\n assert stat.S_ISREG(s.st_mode),'nonregular source'\n"
            " print(hashlib.sha256(p.read_bytes()).hexdigest())")
    return subprocess.check_output(['docker','exec',name,'python','-c',code],text=True,timeout=10).strip()

def default_runtime_evidence():
    receipt=json.loads((ROOT/'default-runtime-receipt.json').read_text())
    assert receipt['image']==roles['worker']['candidate_image']
    assert receipt['manifest_sha256']==hashlib.sha256((ROOT/'services-manifest.json').read_bytes()).hexdigest()
    assert set(receipt['checks'])=={'default_entry','default_pytest'}
    assert all(row['exit_code']==0 and row['cleanup_exit']==0 for row in receipt['checks'].values())
    required={'validate_default_runtime.py','default_entry_probe.py','test-tools.zip',
        'tests/test_worker_active_lease.py','tests/test_published_worker_entrypoint.py',
        'tests/test_worker_claim_fencing.py','tests/test_worker_lease_window.py'}
    assert set(receipt['input_sha256'])==required
    for path,digest in receipt['input_sha256'].items():
        assert hashlib.sha256((ROOT/path).read_bytes()).hexdigest()==digest, 'validation input drift'

class UncertainSwitch(RuntimeError):
    pass

def guarded_process(command, output):
    # Inner maximum: render30 + 2*(probe90+cleanup15) + Compose180 = 420s.
    # A timeout is uncertain: terminate only this new session, then stop without
    # starting a concurrent rollback. Docker daemon state needs a fresh review.
    process=subprocess.Popen(command,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
    try:
        result=process.wait(timeout=480)
    except subprocess.TimeoutExpired:
        try:
            for sig in (signal.SIGTERM,signal.SIGKILL):
                try:os.killpg(process.pid,sig)
                except ProcessLookupError:pass
                try:process.wait(timeout=5)
                except subprocess.TimeoutExpired:pass
        finally:
            # Cleanup itself may fail. This still cannot prove a settled switch.
            raise UncertainSwitch('guard timeout; inspect settled runtime before recovery')
    except Exception as error:
        raise UncertainSwitch('guard wait failed; inspect settled runtime before recovery') from error
    # The frozen guard maps its own Compose timeout to exit1. Any nonzero
    # result lacks proof that daemon-side switching settled; do not race it.
    if result:raise UncertainSwitch('guard nonzero; inspect settled runtime before recovery')

def switch(operation):
    guard_identity()
    kind='candidate' if operation=='deploy' else 'rollback'
    for role in ('api','worker'):
        path=PRIVATE/(role+'-'+kind+'.json')
        assert hashlib.sha256(path.read_bytes()).hexdigest()==roles[role]['config_hashes'][kind]
    command=['python3',str(GUARD),operation,'--compose',str(PRIVATE/('api-'+kind+'.json')),
             '--compose',str(PRIVATE/('worker-'+kind+'.json')),'--service','business-worker']
    with (PRIVATE/('worker-'+operation+'-output.txt')).open('a') as output:
        guarded_process(command,output)
    expected=roles['worker']['candidate_image'] if operation=='deploy' else roles['worker']['old_image']
    for _ in range(30):
        current=inspect(roles['worker']['name'])
        assert current['State']['Running'] and not current['State'].get('OOMKilled')
        if current['State'].get('Health',{}).get('Status')=='healthy':break
        time.sleep(2)
    else:raise RuntimeError('worker readiness deadline')
    assert current['Image']==expected
    same_runtime(json.loads((PRIVATE/'worker-inspect.json').read_text()),current)
    for target,old_sha,new_sha in roles['worker']['files'].values():
        actual=source_sha(roles['worker']['name'],target)
        assert actual==(new_sha if operation=='deploy' else old_sha)
    return current

lock=(PRIVATE/'deploy.lock').open('w')
fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
assert not (ROOT/'deployment.json').exists(), 'inspect previous receipt before retry'
guard_identity()
default_runtime_evidence()
for role,row in roles.items():
    live=inspect(row['name'])
    assert live['Id']==row['id'] and live['Image']==row['old_image']
    same_runtime(json.loads((PRIVATE/(role+'-inspect.json')).read_text()),live)
    for path,expected in row['source_hashes'].items():
        assert hashlib.sha256(Path(path).read_bytes()).hexdigest()==expected
    for target,old_sha,_new_sha in row['files'].values():
        assert source_sha(row['name'],target)==old_sha, 'live runtime source drift'
assert schema()=='0095_wallet_source_alerts'
assert probe_https('/_matrix/client/versions').get('versions')
probe_https('/api/v1/health/ready')
# Refuse a currently active outbox batch; this is a release precondition only,
# not an atomic drain or an exactly-once claim. Existing SIGTERM handling stays.
assert processing_count()==0, 'active worker events; defer release'
time.sleep(2)
assert processing_count()==0, 'active worker events; defer release'
archive=PRIVATE/'previous-worker-logs'
archive.mkdir(mode=0o700,exist_ok=False)
live=inspect(roles['worker']['name'])
path=Path(live['LogPath'])
assert path.parent==Path('/var/lib/docker/containers')/live['Id']
for source in path.parent.glob(path.name+'*'):
    assert source.is_file() and not source.is_symlink()
    os.link(source,archive/source.name)
receipt={'stage':'deploying','started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
(ROOT/'deployment.json').write_text(json.dumps(receipt,indent=2))
try:
    current=switch('deploy')
    assert schema()=='0095_wallet_source_alerts'
    probe_https('/api/v1/health/ready')
    assert probe_https('/_matrix/client/versions').get('versions')
    before=dict(line.split(' ',1) for line in (PRIVATE/'services-before-container-ids.txt').read_text().splitlines())
    after=dict(line.split(' ',1) for line in subprocess.check_output(['docker','ps','-a','--no-trunc','--format','{{.Names}} {{.ID}}'],text=True,timeout=10).splitlines())
    allowed=roles['worker']['name']
    assert {k:v for k,v in before.items() if k!=allowed}=={k:v for k,v in after.items() if k!=allowed}
    receipt.update(stage='PASS',id=current['Id'],image=current['Image'],schema='0095_wallet_source_alerts',
        source_sha256={name:row[2] for name,row in roles['worker']['files'].items()},unrelated_containers_unchanged=True,
        completed_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()))
except Exception as error:
    receipt.update(stage='FAILED',failure_type=type(error).__name__)
    if isinstance(error,UncertainSwitch):
        receipt['recovery_required']='inspect settled runtime; automatic rollback withheld'
    else:
        try:switch('rollback');receipt['rolled_back']=True
        except Exception as rollback_error:receipt['rollback_failure_type']=type(rollback_error).__name__
    (ROOT/'deployment.json').write_text(json.dumps(receipt,indent=2))
    emit('failed',receipt=receipt)
    raise SystemExit(1)
(ROOT/'deployment.json').write_text(json.dumps(receipt,indent=2))
emit('complete',receipt=receipt)
