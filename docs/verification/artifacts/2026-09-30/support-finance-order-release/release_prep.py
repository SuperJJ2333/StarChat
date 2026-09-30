"""Inert Task14 release preparation. No production execution or deployment command.

Adapted from audited wallet release-package-r3 invariants, with explicit 0093
expand and fail-closed post-expand rollback. Candidate payload is not frozen by
this tool. Operators must complete release gates before any mutation.
"""
from __future__ import annotations
import argparse
import json
import os
from hashlib import sha256
from pathlib import Path, PurePosixPath
import re
import shutil
import tempfile

RELEASE_ID='support-finance-order-recovery-20260930-v1'
BASE_SCHEMA='0092_admin_session_entry_mode'
TARGET_SCHEMA='0093_support_finance_order_recovery'
BASE_API='sha256:fadabb52cd61c078599ceda2544cea6f34dd85b0dbc0b6c5d276c5d3a96ab7dd'
BASE_WORKER='sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf'
GUARD_SHA='78b2beb6c20484cea04fa8e77c1dd23b9a3e401af9d6fafd3e4b7d316d07beec'
PROBE_SHA='d77a83e89d848bfc8b6d7dad72b9abd01d60550a6e356d0a12b382674c37b678'
GUARD='/opt/starchat/ops/refresh-guards/business_release_guard.py'
MIGRATION='services/business-api/migrations/versions/0093_support_finance_order_recovery.py'
API_SOURCES=frozenset('services/business-api/'+name for name in (
 'app/api/recharge.py','app/api/support_payout.py','app/integrations/tron/reader.py',
 'app/modules/identity/operation_password.py','app/modules/identity/support_order_auth.py','app/modules/identity/totp.py',
 'app/modules/ledger/service.py','app/modules/recharge/models.py','app/modules/recharge/service.py','app/modules/recharge/workflow.py',
 'app/modules/wallet/binding_adapters.py','app/modules/wallet/conversions.py','app/modules/wallet/manual_payouts.py',
 'app/modules/wallet/recharge_binding_gate.py','app/modules/wallet/recharge_receipts.py','app/modules/wallet/runtime.py','app/modules/wallet/service.py','app/modules/wallet/support_payout.py',
 'migrations/versions/0093_support_finance_order_recovery.py'))
WORKER_SOURCES=frozenset('services/business-api/'+name for name in (
 'app/modules/wallet/manual_payouts.py','app/modules/wallet/support_payout.py',
 'app/modules/wallet/conversions.py','app/modules/wallet/service.py','app/modules/ledger/service.py'))
def worker_destinations():
    return {(source,root+source.removeprefix('services/business-api/app/'))
      for source in WORKER_SOURCES for root in ('/usr/local/lib/python3.12/site-packages/app/','/opt/business-api/app/')}|{(MIGRATION,'/opt/business-api/migrations/versions/0093_support_finance_order_recovery.py')}
STATIC_SOURCES=frozenset(('frontend/src/admin-api.js','frontend/src/admin-recharge-panel.js',
 'frontend/src/admin-support-payout-panel.js','frontend/src/styles/admin-wallet.css'))
CLONE_NAME='support-finance-release-clone'
IMAGE=re.compile(r'sha256:[0-9a-f]{64}\Z')
HEX=re.compile(r'[0-9a-f]{64}\Z')


def sha_bytes(data):return sha256(data).hexdigest()
def sha_file(path):return sha_bytes(Path(path).read_bytes())
def image_dest(source):
    if source not in API_SOURCES:raise ValueError('unlisted API source')
    return '/opt/business-api/'+source.removeprefix('services/business-api/')
def require_hash(value):
    if not isinstance(value,str) or not HEX.fullmatch(value):raise ValueError('SHA256 required')
def require_image(value):
    if not isinstance(value,str) or not IMAGE.fullmatch(value):raise ValueError('immutable sha256 image required')
def validate_manifest(m):
    if not isinstance(m,dict) or m.get('frozen') is not True:raise ValueError('final reviewed frozen manifest required')
    if (m.get('release_id'),m.get('before_schema'),m.get('after_schema'))!=(RELEASE_ID,BASE_SCHEMA,TARGET_SCHEMA):raise ValueError('schema or release identity changed')
    if not re.fullmatch('[0-9a-f]{40}',m.get('source_commit','')):raise ValueError('final source commit required')
    if m.get('guard_sha256')!=GUARD_SHA or m.get('guard_probe_sha256')!=PROBE_SHA:raise ValueError('reviewed guard/probe identity changed')
    require_image(m.get('clone_image'))
    roles=m.get('roles',{})
    if set(roles)!={'api','worker'}:raise ValueError('both roles required')
    for role,base in [('api',BASE_API),('worker',BASE_WORKER)]:
        record=roles[role]
        if record.get('base_image')!=base:raise ValueError('live image drift requires new baseline review')
        require_hash(record.get('compose_sha256'))
        files=record.get('files')
        if not isinstance(files,list):raise ValueError('explicit files required')
        expected={(source,image_dest(source)) for source in API_SOURCES} if role=='api' else worker_destinations()
        if len(files)!=len(expected) or {(x.get('source'),x.get('dest')) for x in files}!=expected:raise ValueError('exact role source/destination allowlist required')
        for item in files:
            if item['source']==MIGRATION:
                if item.get('before_sha256') is not None:raise ValueError('0093 must be absent at0092 baseline')
            else:require_hash(item.get('before_sha256'))
            require_hash(item.get('after_sha256'))
    static=m.get('static',[])
    if len(static)!=len(STATIC_SOURCES) or {x.get('source') for x in static}!=STATIC_SOURCES:raise ValueError('exact static allowlist required')
    for item in static:
        if item.get('dest')!=item['source'].removeprefix('frontend/'):raise ValueError('exact static destination required')
        require_hash(item.get('before_sha256'));require_hash(item.get('after_sha256'))
    return m

def assert_inventory_delta(before,after,expected):
    # Allow listed files whose reviewed bytes happen to match the live baseline;
    # migration additions remain explicit. All actual changes must be listed.
    changed={p for p in before.keys()|after.keys() if before.get(p)!=after.get(p)}
    if not changed<=expected.keys() or any(after.get(p)!=h for p,h in expected.items()):raise ValueError('unlisted image change or final SHA mismatch')

def stage_payload(m,repo,package):
    validate_manifest(m);repo=Path(repo).resolve(strict=True);target=Path(package)/'payload'
    if target.exists():raise ValueError('payload already exists; do not overwrite frozen package')
    records=m['roles']['api']['files']+m['roles']['worker']['files']+m['static']
    for item in records:
        source=repo/item['source']
        if source.is_symlink() or not source.resolve(strict=True).is_relative_to(repo) or sha_file(source)!=item['after_sha256']:raise ValueError('source SHA or path changed')
    target.mkdir(parents=True)
    for item in records:
        destination=target/item['source'];destination.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(repo/item['source'],destination)
        if sha_file(destination)!=item['after_sha256']:raise ValueError('payload SHA changed')
    return len(records)

def validate_guard_proof(proof,images):
    if set(images)!={'api','worker'}:raise ValueError('both roles required')
    expected={(role,image) for role,values in images.items() for image in values}
    if not isinstance(proof,list) or len(proof)!=len(expected) or {(x.get('role'),x.get('image')) for x in proof if x.get('passed') is True}!=expected:raise ValueError('incomplete role-qualified protocol proof')

def clone_runner(image):
    require_image(image)
    return ['docker','run','--rm','--pull','never','--network','container:'+CLONE_NAME,
      '--read-only','--cap-drop','ALL','--security-opt','no-new-privileges',
      '--memory','1g','--cpus','2','--pids-limit','256','--tmpfs','/tmp:rw,nosuid,size=128m',
      '--workdir','/opt/business-api','-e','PYTHONDONTWRITEBYTECODE=1','-e','BUSINESS_ENVIRONMENT=test',
      '-e','BUSINESS_DATABASE_URL=postgresql+psycopg://postgres@127.0.0.1:5432/clone',
      '-e','PGOPTIONS=-c lock_timeout=5000 -c statement_timeout=60000','--entrypoint','python',image]

def release_plan(m,candidate):
    validate_manifest(m);require_image(candidate)
    images={'api':[candidate,BASE_API],'worker':[BASE_WORKER,BASE_WORKER]}
    guard=['python3',GUARD,'check']
    for role,values in images.items():
        for image in values:guard+=['--'+role+'-image',image]
    return {
      'release_id':RELEASE_ID,'execution_status':'PREPARATION ONLY: no production mutation executor',
      'schema_before':BASE_SCHEMA,'schema_after':TARGET_SCHEMA,
      'guard_check':guard,'guard_expected_roles':images,
      'backup':['docker','exec','starchat-business-postgres-1','sh','-c','pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc'],
      'backup_stdout':'private/business.dump',
      'image_archive':['docker','save',BASE_API,BASE_WORKER],'image_archive_stdout':'private/rollback-images.tar',
      'clone_start':['docker','run','-d','--pull','never','--name',CLONE_NAME,'--network','none','-e','POSTGRES_HOST_AUTH_METHOD=trust','-e','POSTGRES_DB=clone',m['clone_image']],
      'clone_restore':['docker','exec','-i',CLONE_NAME,'pg_restore','-h','127.0.0.1','-U','postgres','-d','clone','--no-owner','--no-privileges','--exit-on-error'],
      'clone_restore_stdin':'private/business.dump',
      'clone_before_head':['docker','exec',CLONE_NAME,'psql','-X','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-U','postgres','-d','clone','-Atqc','select version_num from alembic_version'],
      'clone_migrate':clone_runner(candidate)+['-m','alembic','upgrade',TARGET_SCHEMA],
      'clone_candidate_probe':clone_runner(candidate)+['-c',READY_CODE],
      'clone_base_probe':clone_runner(BASE_API)+['-c',READY_CODE],
      'clone_after_head':['docker','exec',CLONE_NAME,'psql','-X','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-U','postgres','-d','clone','-Atqc','select version_num from alembic_version'],
      'clone_cleanup':['docker','rm','-f','-v',CLONE_NAME],
      'required_manual_gates':['verify clone identity/network and TCP readiness before restore',
        'restore backup SHA; sole head 0092 before and 0093 after; fingerprints unchanged',
        'synthetic isolated new-state old-write failure proof; no production financial writes',
        'reinspect clone identity/mounts before cleanup; prove container and anonymous volume removed',
        'fresh live image/schema/Compose/guard/static drift preflight before each future production step',
        'freeze compatible rollback image or tested write fence before production migration'],
    }
READY_CODE="from fastapi.testclient import TestClient; from app.main import create_default_app; app=create_default_app();\nwith TestClient(app) as c:\n r=c.get('/api/v1/health/ready'); assert r.status_code==200 and r.json().get('ok') is True and r.json().get('database')=='ready'"

def validate_clone_proof(e):
    if (e.get('before_schema'),e.get('after_schema'),e.get('clone_network'))!=(BASE_SCHEMA,TARGET_SCHEMA,'none'):raise ValueError('clone heads/network mismatch')
    for before,after in [('backup_sha256','restored_backup_sha256'),('before_ledger_sha256','after_ledger_sha256'),('before_payout_sha256','after_payout_sha256'),('before_recharge_sha256','after_recharge_sha256')]:
        require_hash(e.get(before));require_hash(e.get(after))
        if e[before]!=e[after]:raise ValueError('restored/migrated financial fingerprint changed')
    for name in ('candidate_ready','base_ready_after_expand','new_state_old_writes_fail_closed'):
        if e.get(name) is not True:raise ValueError('clone compatibility evidence missing')

def rollback_gate(e):
    if e.get('schema')!=TARGET_SCHEMA:raise ValueError('rollback must retain expanded 0093 schema')
    fence=e.get('write_fence',{})
    if any(fence.get(x) is not True for x in ('closed','payout','recharge','tested')):raise ValueError('tested live payout and recharge write fence required before old API rollback')
    require_hash(fence.get('sha256'))

def checked_target(root,name):
    path=PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or '\\' in name or not name:raise ValueError('unsafe static path')
    root=Path(root).resolve(strict=True);target=root.joinpath(*path.parts)
    if target.is_symlink() or any(p.is_symlink() for p in target.parents if p!=root and root in p.parents):raise ValueError('symlinked static target')
    if not target.resolve().is_relative_to(root):raise ValueError('static target escapes root')
    return target

def atomic_replace(target,source):
    target.parent.mkdir(exist_ok=True,parents=True)
    fd,name=tempfile.mkstemp(prefix='.'+target.name+'.release-',dir=target.parent)
    try:
        with os.fdopen(fd,'wb') as out:out.write(source.read_bytes());out.flush();os.fsync(out.fileno())
        if target.exists():
            metadata=target.stat();os.chmod(name,metadata.st_mode&0o777)
            if hasattr(os,'chown'):os.chown(name,metadata.st_uid,metadata.st_gid)
        else:os.chmod(name,0o644)
        os.replace(name,target)
    finally:Path(name).unlink(missing_ok=True)

def backup_static(records,root,backup):
    backup=Path(backup)
    if backup.exists():raise ValueError('backup already exists')
    for item in records:
        if sha_file(checked_target(root,item['dest']))!=item['before_sha256']:raise ValueError('live static drift before backup')
    backup.mkdir(parents=True,mode=0o700)
    for item in records:
        target=backup/item['dest'];target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(checked_target(root,item['dest']),target);os.chmod(target,0o600)
        if sha_file(target)!=item['before_sha256']:raise ValueError('backup SHA mismatch')

def publish_static(records,root,payload):
    for item in records:
        if sha_file(checked_target(root,item['dest']))!=item['before_sha256'] or sha_file(checked_target(payload,item['dest']))!=item['after_sha256']:raise ValueError('static drift blocks switch')
    for item in records:
        target=checked_target(root,item['dest']);source=checked_target(payload,item['dest'])
        if sha_file(target)!=item['before_sha256'] or sha_file(source)!=item['after_sha256']:raise ValueError('static drift during switch')
        atomic_replace(target,source)
        if sha_file(target)!=item['after_sha256']:raise ValueError('static switch SHA mismatch')

def restore_static(records,root,backup):
    for item in records:
        if sha_file(checked_target(root,item['dest'])) not in {item['before_sha256'],item['after_sha256']} or sha_file(checked_target(backup,item['dest']))!=item['before_sha256']:raise ValueError('later static drift blocks rollback')
    for item in records:
        target=checked_target(root,item['dest']);source=checked_target(backup,item['dest'])
        if sha_file(target)==item['after_sha256']:atomic_replace(target,source)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('operation',choices=['validate','plan','stage']);p.add_argument('--manifest',required=True,type=Path);p.add_argument('--candidate-api');p.add_argument('--repo',type=Path);p.add_argument('--package',type=Path);args=p.parse_args()
    m=validate_manifest(json.loads(args.manifest.read_text(encoding='utf-8')))
    if args.operation=='plan':print(json.dumps(release_plan(m,args.candidate_api),indent=2))
    elif args.operation=='stage':
        if not args.repo or not args.package:p.error('--repo and --package required')
        print(json.dumps({'staged_files':stage_payload(m,args.repo,args.package)}))
    else:print(json.dumps({'validated':True,'release_id':m['release_id'],'api_files':len(API_SOURCES),'worker_files':0,'static_files':len(STATIC_SOURCES)}))
if __name__=='__main__':main()
