"""Freeze reviewed git-blob bytes after live baseline reconciliation only."""
import argparse,json,subprocess
from pathlib import Path
from datetime import datetime,timezone
import release_prep as r
from release import validate_manifest
PACKAGE=Path(__file__).resolve().parent

def git(repo,*args):
    proc=subprocess.run(['git','-C',str(repo),*args],capture_output=True)
    if proc.returncode:raise ValueError('git source identity command failed')
    return proc.stdout

def freeze(snapshot,repo,commit):
    full=git(repo,'rev-parse',commit+'^{commit}').decode().strip()
    if snapshot['schema']!=r.BASE_SCHEMA:raise ValueError('schema baseline drift')
    for role,image in [('api',r.BASE_API),('worker',r.BASE_WORKER)]:
        if snapshot['roles'][role]['base_image']!=image or snapshot['roles'][role]['health']!='healthy' or snapshot['roles'][role]['restarts']!=0:raise ValueError('baseline roles not healthy immutable approved identities')
    if snapshot['guard_sha256']!=r.GUARD_SHA or snapshot['guard_probe_sha256']!=r.PROBE_SHA:raise ValueError('installed guard drift')
    if (PACKAGE/'manifest.json').exists() or (PACKAGE/'payload').exists():raise ValueError('frozen package already exists')
    m={'release_id':r.RELEASE_ID,'frozen':True,'frozen_utc':datetime.now(timezone.utc).isoformat(),'source_commit':full,
      'before_schema':r.BASE_SCHEMA,'after_schema':r.TARGET_SCHEMA,'guard_sha256':r.GUARD_SHA,'guard_probe_sha256':r.PROBE_SHA,
      'clone_image':snapshot['clone_image'],'baseline_captured_utc':snapshot['captured_utc'],'line_endings':'exact git-blob bytes; no line-ending rewriting',
      'roles':snapshot['roles'],'static':snapshot['static'],
      'wallet_probe_sha256':r.sha_file(PACKAGE/'clone-fence-probe.py'),'rollback_fence_sha256':r.sha_file(PACKAGE/'finance_write_fence.py'),
      'worker_probe_sha256':r.sha_file(PACKAGE/'worker-probe.py')}
    sources={x['source'] for record in m['roles'].values() for x in record['files']}|r.STATIC_SOURCES
    blobs={name:git(repo,'show',full+':'+name) for name in sources}
    for record in m['roles'].values():
        for item in record['files']:item['after_sha256']=r.sha_bytes(blobs[item['source']])
    for item in m['static']:item['after_sha256']=r.sha_bytes(blobs[item['source']])
    task=(PACKAGE/'worker-task-readonly-hash.txt').read_text(encoding='utf-8-sig').split()[0];r.require_hash(task)
    candidate={name.removeprefix('services/business-api/').removesuffix('.py').replace('/','.'):r.sha_bytes(blobs[name]) for name in r.WORKER_SOURCES};candidate['tasks.manual_wallet']=task
    baseline={item['source'].removeprefix('services/business-api/').removesuffix('.py').replace('/','.'):item['before_sha256'] for item in m['roles']['worker']['files'] if item['source'] in r.WORKER_SOURCES and item['dest'].startswith('/usr/local/lib/')};baseline['tasks.manual_wallet']=task
    for name,data in [('worker-expected-sources.json',candidate),('worker-baseline-expected-sources.json',baseline)]:
        (PACKAGE/name).write_text(json.dumps(data,indent=2)+'\n',encoding='utf-8')
    m['worker_expected_sources_sha256']=r.sha_file(PACKAGE/'worker-expected-sources.json');m['worker_baseline_expected_sources_sha256']=r.sha_file(PACKAGE/'worker-baseline-expected-sources.json')
    validate_manifest(m)
    for name,blob in blobs.items():
        target=PACKAGE/'payload'/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(blob)
    (PACKAGE/'manifest.json').write_text(json.dumps(m,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
    return {'frozen':True,'source_commit':full,'api_files':len(m['roles']['api']['files']),'worker_files':len(m['roles']['worker']['files']),'static_files':len(m['static'])}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--snapshot',required=True,type=Path);p.add_argument('--repo',required=True,type=Path);p.add_argument('--source-commit',required=True);p.add_argument('--live-deltas-reconciled',action='store_true');a=p.parse_args()
    if not a.live_deltas_reconciled:p.error('root must reconcile live source deltas before freeze')
    print(json.dumps(freeze(json.loads(a.snapshot.read_text(encoding='utf-8-sig')),a.repo,a.source_commit)))
if __name__=='__main__':main()
