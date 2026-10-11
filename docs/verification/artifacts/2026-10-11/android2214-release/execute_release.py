"""Explicit, reviewed, one-phase-at-a-time publication. Default is local plan only.

This file is preparation code. No remote action runs at import or without
--execute and a review bound to the exact package and operation identifier.
"""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import subprocess
import tarfile
from datetime import datetime, timezone
from types import ModuleType

HERE = Path(__file__).resolve().parent
package = ModuleType('package_release_execute'); package.__file__=str(HERE/'package_release.py')
exec(compile((HERE/'package_release.py').read_bytes(),package.__file__,'exec'),package.__dict__)
fail, digest, read_json, member = package.fail, package.digest, package.read_json, package.member
OPERATIONS = ('preflight', 'runtime', 'upload', 'assemble', 'hk-install', 'cdn-install',
              'cdn-check', 'hk-switch', 'publish', 'inspect', 'audit')
READ_ONLY = frozenset(('preflight', 'cdn-check', 'inspect', 'audit'))
PREVIOUS = {'upload':'runtime', 'assemble':'upload', 'hk-install':'assemble',
            'cdn-install':'hk-install', 'cdn-check':'cdn-install', 'hk-switch':'cdn-install',
            'publish':'hk-switch', 'inspect':'runtime', 'audit':'runtime'}


def validate_package(root):
    root = Path(root)
    frozen = read_json(root/'freeze-manifest.json')
    fail(frozen.get('schema') == 1 and isinstance(frozen.get('files'), dict), 'package schema')
    for name, expected in frozen['files'].items():
        fail(digest(member(root,name)) == expected, 'frozen file drift: '+name)
    for name in ('package_release.py','execute_release.py'):
        fail(frozen['files'].get('orchestrator/'+name)==digest(HERE/name), 'local orchestrator drift: '+name)
    needed = {'delivery/'+package.NAME, 'evidence/artifact.json', 'evidence/steps.tsv',
        'evidence/gates.json', 'evidence/mobile-inputs.json', 'runtime-2214.tar.gz',
        'runtime/prepared-2214/release.json', 'source-backfill/plan.json'}
    fail(needed <= set(frozen['files']), 'incomplete frozen package')
    artifact = read_json(root/'evidence/artifact.json')
    identity = package.validate_build(root/'delivery'/package.NAME,artifact,
                                     root/'evidence/steps.tsv',root/'evidence/gates.json')
    fail(all(frozen.get(k) == v for k,v in identity.items()), 'frozen build identity drift')
    fail(digest(root/'evidence/mobile-inputs.json') == identity['source_manifest_sha256'], 'manifest binding')
    archive = member(root,'runtime-2214.tar.gz')
    fail(digest(archive) == frozen.get('runtime_sha256') and archive.stat().st_size == frozen.get('runtime_bytes'), 'archive identity')
    expected = frozen.get('runtime_files')
    fail(isinstance(expected,dict) and expected and all(frozen['files'].get('runtime/'+n)==h for n,h in expected.items()), 'runtime file binding')
    with tarfile.open(archive) as tar:
        entries = tar.getmembers()
        fail(len(entries)==len(expected) and {m.name for m in entries}==set(expected), 'archive member set')
        for item in entries:
            name=PurePosixPath(item.name)
            fail(item.isfile() and not name.is_absolute() and '..' not in name.parts, 'unsafe archive member')
            with tar.extractfile(item) as stream:
                fail(hashlib.file_digest(stream,'sha256').hexdigest()==expected[item.name], 'archive member drift')
    release_path=root/'runtime/prepared-2214/release.json'
    fail(digest(release_path)==frozen.get('release_sha256'), 'release identity')
    release=package.load_release(root/'runtime/release_2214.py')
    r=read_json(release_path); release.validate_release(r)
    fail(all(r.get(k)==v for k,v in identity.items() if k!='pubspec_lock_sha256'), 'record/build identity')
    return frozen


def validate_review(review_path, root, frozen, operation, operation_id):
    fail(review_path is not None, 'explicit artifact-bound review required')
    review=read_json(review_path)
    for key,value in {'freeze_sha256':digest(Path(root)/'freeze-manifest.json'),
            'artifact_sha256':frozen['artifact_sha256'], 'runtime_sha256':frozen['runtime_sha256'],
            'source_commit':frozen['source_commit'], 'operation_id':operation_id}.items():
        fail(review.get(key)==value, 'review binding drift: '+key)
    fail(operation in review.get('authorized_operations',[]), 'operation not authorized by release review')
    fail(set(review.get('checks',{}))=={'spec_domain','quality_security'}, 'both ordered reviews required')
    for key in ('spec_domain','quality_security'):
        check=review['checks'][key]
        fail(check.get('status')=='pass' and digest(member(Path(review_path).parent,check.get('path')))==check.get('sha256'), 'review evidence drift: '+key)


def remote(host, code, *, stream_path=None, timeout=600):
    """Fixed destinations, verified host keys, bounded wait; no secret output."""
    base=['ssh','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=10',
          '-o','ServerAliveInterval=15','-o','ServerAliveCountMax=3','-J','jumper']
    if host=='hk': base += ['-p','23421','root@207.56.8.8']
    elif host=='sg': base += ['-o','HostKeyAlias=13.229.60.153','-i',str(Path.home()/'.ssh/tee_13153299.pem'),'ec2-user@18.143.207.225']
    else: raise ValueError('unknown host')
    command=base+['python3 -c '+shlex.quote(code)]
    with package.regular(stream_path).open('rb') if stream_path else contextlib.nullcontext(subprocess.DEVNULL) as stream:
        result=subprocess.run(command,stdin=stream,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    if result.returncode:
        raise RuntimeError('remote '+host+' returned exit '+str(result.returncode)+'; inspect privately, do not replay')
    return json.loads(result.stdout.decode('utf-8'))


def stages(operation_id):
    fail(isinstance(operation_id,str) and re.fullmatch('[a-z0-9][a-z0-9-]{7,63}',operation_id), 'safe unique operation ID required')
    return {'hk':'/opt/starchat/releases/android2214-'+operation_id,
            'sg':'/home/ec2-user/starchat-android2214-'+operation_id,
            'backup':'/opt/starchat/docs/verification/artifacts/2026-10-11/android2214-'+operation_id}


def compare_baseline(host, current, root):
    runtime=Path(root)/'runtime'
    before=read_json(runtime/(host+'-live-snapshot.json'))
    if host=='hk':
        for key in ('registry','aliases','old_artifact','target_exists','settings','schema'):
            fail(current.get(key)==before[key], 'live HK baseline drift: '+key)
        fail(sorted(current.get('runtime',[]),key=lambda x:x['name'])==sorted(before['runtime'],key=lambda x:x['name']), 'running container identity drift')
        static=read_json(runtime/'static-baseline.json')['files']
        actual=current.get('files',{})
        fail(set(actual)==set(static) and all(actual[n].get('sha256')==v['sha256'] and actual[n].get('bytes')==v['bytes'] for n,v in static.items()), 'static baseline drift')
    else:
        for key in ('cloudfront','policy','identity','status'):
            fail(current.get(key)==before[key], 'live SG baseline drift: '+key)
        fail(current['status']=='Deployed','baseline not deployed')


def preflight(root, runner):
    for host in ('hk','sg'):
        code=member(Path(root)/'runtime',host+'-projection-source.py').read_text(encoding='utf-8')
        compare_baseline(host,runner(host,code,timeout=180),root)
    return {'status':'BASELINE_EXACT','platforms':'android2213-ios2213','containers':35}


def guarded_command(stage, frozen, arguments):
    # Recheck every frozen runtime input immediately before executing its code.
    return ('import hashlib,json,subprocess\nfrom pathlib import Path\n'
            f'root=Path({stage!r})\nexpected={frozen["runtime_files"]!r}\n'
            'for name,sha in expected.items():\n'
            ' p=root/name\n'
            ' if not p.is_file() or any(x.is_symlink() for x in (p,*p.parents)) or hashlib.sha256(p.read_bytes()).hexdigest()!=sha: raise ValueError("remote runtime drift")\n'
            'if list(root.rglob("*.pyc")): raise ValueError("unfrozen bytecode in private runtime")\n'
            f'result=subprocess.run({[arguments[0],"-B",*arguments[1:]]!r},capture_output=True,timeout=240)\n'
            'if result.returncode: raise RuntimeError("guarded payload failed; inspect private state")\n'
            'print(json.dumps(json.loads(result.stdout)))\n')


def delivery_command(stage, frozen, operation):
    arguments=['python3',stage+'/delivery_2214.py',operation,stage+'/prepared-2214/release.json','--stage',stage]
    if operation in ('hk-install','hk-switch'):
        # The public phase may be hours after upload. Recheck the service/ABI
        # preservation boundary now; the payload still takes the host lock.
        code=('import sys,subprocess\n'+f'sys.path.insert(0,{stage!r})\n'
              'import release_2214 as release\nrelease.host_preservation("/opt/starchat/frontend")\n'
              f'subprocess.run({[arguments[0],"-B",*arguments[1:]]!r},check=True,timeout=180)\n')
        arguments=['python3','-c',code]
    return guarded_command(stage,frozen,arguments)


def cdn_ready(runner, paths, frozen):
    state=runner('sg',delivery_command(paths['sg'],frozen,'cdn-check'))
    fail(state.get('cloudfront')=='complete' and state.get('status')=='Deployed'
         and state.get('policy')=='unchanged' and state.get('artifact_sha256')==frozen['artifact_sha256']
         and state.get('artifact_bytes')==frozen['artifact_bytes']
         and state.get('public')=={'head':200,'cors':'https://www.liuhetong888.com'},
         'fresh deployed CDN HEAD/CORS required; wait and check again')
    return state


def receive_code(destination, source):
    """Exclusive receiver, bounded declared bytes and streamed SHA, 0600."""
    size=Path(source).stat().st_size; sha=digest(source)
    return ('import hashlib,json,os,sys\nfrom pathlib import Path\n'
        f'p=Path({destination!r}); expected={sha!r}; size={size}\n'
        'if any(x.is_symlink() for x in (p,*p.parents)): raise ValueError("symlink receiver")\n'
        'h=hashlib.sha256(); count=0\n'
        'with p.open("xb") as f:\n'
        ' os.chmod(p,0o600)\n'
        ' while True:\n'
        '  block=sys.stdin.buffer.read(1024*1024)\n'
        '  if not block: break\n'
        '  count+=len(block)\n'
        '  if count>size: raise ValueError("oversized stream")\n'
        '  f.write(block);h.update(block)\n'
        ' f.flush();os.fsync(f.fileno())\n'
        'if count!=size or h.hexdigest()!=expected: raise ValueError("stream identity")\n'
        'print(json.dumps({"sha256":expected,"bytes":count}))\n')


def install_runtime(root, frozen, paths, runner):
    archive=Path(root)/'runtime-2214.tar.gz'
    for host in ('hk','sg'):
        stage=paths[host]
        runner(host,'import json,os\nfrom pathlib import Path\n'+f'p=Path({stage!r})\n'
            'if any(x.is_symlink() for x in (p,*p.parents)): raise ValueError("unsafe stage")\n'
            'p.mkdir(mode=0o700,parents=False,exist_ok=False);os.chmod(p,0o700)\nprint(json.dumps({"created":str(p)}))')
        runner(host,receive_code(stage+'/runtime-2214.tar.gz',archive),stream_path=archive)
        code=('import hashlib,json,os,tarfile\nfrom pathlib import Path\n'
            f'root=Path({stage!r});a=root/"runtime-2214.tar.gz";expected={frozen["runtime_files"]!r}\n'
            f'if hashlib.sha256(a.read_bytes()).hexdigest()!={frozen["runtime_sha256"]!r}: raise ValueError("archive drift")\n'
            'with tarfile.open(a) as tar:\n'
            ' entries=tar.getmembers()\n'
            ' if len(entries)!=len(expected) or {m.name for m in entries}!=set(expected): raise ValueError("archive member set")\n'
            ' for m in entries:\n'
            '  if not m.isfile() or Path(m.name).is_absolute() or ".." in Path(m.name).parts: raise ValueError("unsafe archive")\n'
            '  data=tar.extractfile(m).read()\n'
            '  if hashlib.sha256(data).hexdigest()!=expected[m.name]: raise ValueError("archive content")\n'
            '  p=root/m.name;p.parent.mkdir(mode=0o700,parents=True,exist_ok=True)\n'
            '  if any(x.is_symlink() for x in (p,*p.parents)): raise ValueError("archive symlink")\n'
            '  with p.open("xb") as f: f.write(data)\n'
            '  os.chmod(p,0o600)\n'
            'print(json.dumps({"runtime":"verified","files":len(expected)}))\n')
        runner(host,code)
    return {'runtime':'verified-both-hosts'}


def upload(root, paths, runner, execution):
    # Reuse the tested split/assemble contract without loading a mutable import
    # search path. Split runs locally; exclusive receivers reject replay.
    chunks=execution/'chunks'
    args=['python','-B',str(Path(root)/'runtime/delivery_2214.py'),'split',
          str(Path(root)/'runtime/prepared-2214/release.json'),'--stage',str(chunks),
          '--source',str(Path(root)/'delivery'/package.NAME)]
    import sys
    args[0]=sys.executable
    subprocess.run(args,check=True,capture_output=True,timeout=120)
    manifest=read_json(chunks/'chunks.json')
    for part in manifest['parts']:
        source=member(chunks,part['name'])
        fail(digest(source)==part['sha256'] and source.stat().st_size==part['bytes'],'local chunk drift')
        runner('hk',receive_code(paths['hk']+'/'+part['name'],source),stream_path=source)
    source=chunks/'chunks.json'
    runner('hk',receive_code(paths['hk']+'/chunks.json',source),stream_path=source)
    return {'uploaded_parts':len(manifest['parts']),'sha256':manifest['sha256'],'bytes':manifest['bytes']}


def run(root, operation, operation_id, *, execute=False, review_path=None, runner=None):
    root=Path(root); paths=stages(operation_id)
    fail(operation in OPERATIONS,'unknown operation')
    frozen=validate_package(root); binding=digest(root/'freeze-manifest.json')
    plan={'status':'PLAN_ONLY','operation':operation,'operation_id':operation_id,'stages':paths,
          'freeze_sha256':binding,'artifact_sha256':frozen['artifact_sha256'],
          'note':'No upload/cloud/service action. --execute requires exact bound release review.'}
    if not execute: return plan
    validate_review(review_path,root,frozen,operation,operation_id)
    runner=runner or remote
    execution=root/'execution'/operation_id
    fail(not any(x.is_symlink() for x in (execution,*execution.parents)),'execution directory symlink')
    if operation not in READ_ONLY:
        fail(not (execution/'outcome-unknown.json').exists(),'uncertain prior outcome; only read-only inspection is allowed')
        fail(not (execution/(operation+'.json')).exists(),'phase already attempted; do not replay')
    if operation in PREVIOUS:
        receipt=execution/(PREVIOUS[operation]+'.json')
        fail(receipt.is_file(),'previous successful phase required: '+PREVIOUS[operation])
        value=read_json(receipt)
        fail(value.get('status')=='PASS' and value.get('freeze_sha256')==binding,'phase receipt identity')
    # Repeat the actual baseline immediately before creating any remote stage.
    if operation in ('preflight','runtime'): preflight(root,runner)
    # A previous receipt never substitutes for the live distribution/HEAD/CORS.
    if operation in ('hk-switch','publish'): cdn_ready(runner,paths,frozen)
    execution.mkdir(mode=0o700,parents=True,exist_ok=True)
    inflight=execution/'inflight.json'
    with inflight.open('x',encoding='utf-8') as file:
        json.dump({'operation':operation,'freeze_sha256':binding},file)
    try:
        if operation=='preflight': result={'status':'BASELINE_EXACT'}
        elif operation=='runtime': result=install_runtime(root,frozen,paths,runner)
        elif operation=='upload': result=upload(root,paths,runner,execution)
        elif operation in ('assemble','hk-install','hk-switch','cdn-install','cdn-check'):
            host='sg' if operation.startswith('cdn') else 'hk'
            result=runner(host,delivery_command(paths[host],frozen,operation))
        elif operation=='publish':
            stage=paths['hk']; args=['python3',stage+'/release_2214.py','publish',stage+'/prepared-2214/release.json',
                '--backup',paths['backup'],'--trace','android2214-'+operation_id]
            result=runner('hk',guarded_command(stage,frozen,args))
        elif operation=='inspect':
            stage=paths['hk']
            # Read partial states without trying to repair or classify them as
            # committed. Audit is a separate read of the public API and trace.
            code=('import json,os,sys\nfrom pathlib import Path\n'+f'sys.path.insert(0,{stage!r})\n'
                'import release_2214 as release\n'+f'r=release.read_json(Path({stage!r})/"prepared-2214/release.json")\n'
                'print(json.dumps({"settings":release.db("inspect",r),"alias":os.readlink("/opt/starchat/frontend/downloads/latest-arm64.apk"),'
                '"static":{n:release.digest(Path("/opt/starchat/frontend")/n) for n in r["deployment"]["static"]}}))')
            result=runner('hk',guarded_command(stage,frozen,['python3','-c',code]))
        else:
            stage=paths['hk']; args=['python3',stage+'/verify_production_2214.py',stage+'/prepared-2214/release.json','android2214-'+operation_id]
            result=runner('hk',guarded_command(stage,frozen,args))
        receipt={'status':'PASS','operation':operation,'freeze_sha256':binding,
                 'checked_at_utc':datetime.now(timezone.utc).isoformat(),'result':result}
        target=execution/(operation+'.json')
        if operation in READ_ONLY and target.exists():
            target=execution/(operation+'-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%f')+'.json')
        with target.open('x',encoding='utf-8') as file: json.dump(receipt,file,indent=2,sort_keys=True)
        return receipt
    except BaseException as error:
        if operation not in READ_ONLY:
            package.write_json(execution/'outcome-unknown.json',{'operation':operation,'freeze_sha256':binding,
                'error_type':type(error).__name__,'action':'Stop mutations. Inspect remote private stage, alias, settings and audit trace. No automatic replay or rollback.'})
        raise
    finally:
        inflight.unlink()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation',choices=OPERATIONS); parser.add_argument('--package',type=Path,required=True)
    parser.add_argument('--operation-id',required=True); parser.add_argument('--review',type=Path)
    parser.add_argument('--execute',action='store_true')
    args=parser.parse_args()
    print(json.dumps(run(args.package,args.operation,args.operation_id,execute=args.execute,review_path=args.review),ensure_ascii=False,sort_keys=True))


if __name__=='__main__': main()
