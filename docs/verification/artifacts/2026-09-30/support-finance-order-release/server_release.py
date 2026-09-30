"""Runnable controlled Task14 operations; inherit r3 snapshot/Compose/guard checks.

All operations are explicit. There are no network, Docker or file writes at
import. A final frozen manifest/payload and dedicated server path are required.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import shutil
from uuid import uuid4
import server_r3 as c
from release import *
from release import _atomic_replace
from finance_write_fence import FACTORY_SUFFIX

ORIGINAL_BUILD=c.build
ORIGINAL_ROLLBACK=c.rollback
ORIGINAL_DEPLOY=c.deploy

def overlay(role,base,inventory,files,label):
    context=c.PRIVATE/'build'/label;context.mkdir(parents=True)
    tag='starchat-'+RELEASE_ID+'-'+label
    base_tag=tag+'-base';c.run('docker','tag',base,base_tag)
    if c.docker_inspect(base_tag)['Id']!=base:raise ValueError('immutable build base changed')
    lines=['FROM '+base_tag]
    expected={}
    for index,item in enumerate(files):
        if inventory.get(item['dest'])!=item['before_sha256']:raise ValueError('base image source differs')
        payload=Path(item['payload']);name='file-%03d.py'%index
        if sha_file(payload)!=item['after_sha256']:raise ValueError('overlay source changed')
        shutil.copyfile(payload,context/name);lines.append('COPY '+json.dumps([name,item['dest']]))
        expected[item['dest']]=item['after_sha256']
    (context/'Dockerfile').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    c.run('docker','build','--network','none','--pull=false','--no-cache','-t',tag,str(context),output_file=c.PRIVATE/(label+'.build.private.log'),timeout=900)
    image=c.docker_inspect(tag)['Id'];assert_exact_inventory_delta(inventory,c.image_inventory(image,role),expected)
    return image

def role_payload(record):
    return [{**item,'payload':str(PACKAGE/'payload'/item['source'])} for item in record['files']]

def build(m):
    c.check_prepared(m)
    api_config=c.read_private('api-container-inspect.json')['Config']
    startup=' '.join(api_config.get('Cmd') or [])
    if not all(token in startup for token in ('alembic','upgrade head','app.main:create_default_app','--factory')):raise ValueError('unreviewed API actual startup/entry')
    if api_config.get('Entrypoint') not in (None,[]):raise ValueError('unexpected API entrypoint')
    if (c.PRIVATE/'images.json').exists():raise ValueError('candidate already built')
    images={};back={}
    for role in ('api','worker'):
        record=m['roles'][role];base=record['base_image'];inventory=c.image_inventory(base,role)
        files=role_payload(record)
        images[role]=overlay(role,base,inventory,files,'candidate-'+role) if files else base
        back[role]=images[role] if role=='worker' else base
    # A fenced API on the actual 0093 baseline, with 0094 migration context.
    base=m['roles']['api']['base_image'];inventory=c.image_inventory(base,'api')
    main_dest='/opt/business-api/app/main.py'
    code=c.run('docker','run','--rm','--pull','never','--network','none','--read-only','--cap-drop','ALL','--security-opt','no-new-privileges','--entrypoint','python',base,'-c',"from pathlib import Path; import base64; print(base64.b64encode(Path('/opt/business-api/app/main.py').read_bytes()).decode())")
    import base64
    original=base64.b64decode(code)
    if sha_bytes(original)!=inventory.get(main_dest):raise ValueError('rollback factory source changed')
    generated=c.PRIVATE/'rollback-generated';generated.mkdir()
    (generated/'main.py').write_bytes(original+FACTORY_SUFFIX.encode())
    fence=PACKAGE/'finance_write_fence.py'
    if sha_file(fence)!=m['rollback_fence_sha256']:raise ValueError('rollback fence source changed')
    migration=next(x for x in m['roles']['api']['files'] if x['source'].endswith('0094_support_finance_order_recovery.py'))
    rollback_files=[{'dest':main_dest,'before_sha256':inventory[main_dest],'after_sha256':sha_file(generated/'main.py'),'payload':str(generated/'main.py')},
      {'dest':'/opt/business-api/app/release_finance_write_fence.py','before_sha256':None,'after_sha256':sha_file(fence),'payload':str(fence)},
      {**migration,'payload':str(PACKAGE/'payload'/migration['source'])}]
    back['api']=overlay('api',base,inventory,rollback_files,'rollback-api-fenced')
    c.write_private('rollback-overlay.json',rollback_files)
    for role in ('api','worker'):
        original=c.read_private(role+'-rendered-compose.json')
        c._render_compose(role,'candidate',compose_with_image(original,ROLE_SERVICE[role],images[role]),images[role])
        c._render_compose(role,'rollback',compose_with_image(original,ROLE_SERVICE[role],back[role]),back[role])
    c.check_merged_compose('candidate',images);c.check_merged_compose('rollback',back)
    proof=c._guard('check',c.protocol_images(images,back));c.write_private('build-protocol-proofs.json',proof)
    c.write_private('images.json',images);c.write_private('rollback-images.json',back)
    c.run('docker','save',images['api'],images['worker'],back['api'],output_file=c.PRIVATE/'compatible-images.tar')
    c.write_private('compatible-archive.json',{'sha256':sha_file(c.PRIVATE/'compatible-images.tar')})
    return {'built':True,'images':images,'rollback_images':back,'worker_safety_retained':True,'rollback_api_write_fenced':True}

def fingerprint(clone):
    # Normalize expansion-only columns so migration proves existing facts intact.
    tables={'ledger_transactions':[],'ledger_entries':[],'wallet_manual_payout_orders':[],
      'wallet_support_payout_states':['prepared_rate','prepared_receive','prepared_digest','prepared_version','evidence_actor_id','evidence_token_hash','evidence_version'],
      'recharge_requests':['claim_version'],'recharge_credit_bindings':[]}
    result={}
    for table,excluded in tables.items():
        expression='to_jsonb(t)'+(' - ARRAY['+','.join("'"+x+"'" for x in excluded)+']::text[]' if excluded else '')
        query="select md5(coalesce(string_agg(x,'|' order by x),'')) from (select ("+expression+")::text x from "+table+" t) q"
        result[table]=c.clone_database_value(clone,query)
    return result

def compatibility_proof():
    proof=c.read_private('clone-compatibility.json')
    if proof.get('before',{}).get('schema')!=BASE_SCHEMA or proof.get('after',{}).get('schema')!=TARGET_SCHEMA or proof.get('candidate_started') is not True or proof.get('rollback_started') is not True or proof.get('facts_before')!=proof.get('facts_after') or proof.get('fence_passed') is not True:raise ValueError('0094 expansion/compatibility evidence incomplete')
    return proof

def probe_clone(m):
    restored=c.read_private('restore-running.json');c.check_prepared(m,isolated_clone=restored)
    inspected=c.docker_inspect(restored['clone'])
    if inspected['Id']!=restored['clone_id'] or inspected['HostConfig']['NetworkMode']!='none':raise ValueError('clone identity changed')
    images=c.read_private('images.json');back=c.read_private('rollback-images.json')
    if restored['candidate_images']!=images or restored['rollback_images']!=back:raise ValueError('clone image identities changed')
    if c.clone_snapshot(restored['clone'],after=True)['schema']!=BASE_SCHEMA:raise ValueError('restore must start at0093')
    before=fingerprint(restored['clone'])
    c.run(*c._clone_runner(images['api'],restored['clone']),'--entrypoint','python',images['api'],'-m','alembic','upgrade',TARGET_SCHEMA,output_file=c.PRIVATE/'clone-migration.private.log')
    for label,image in [('candidate',images['api']),('rollback',back['api'])]:
        c.run(*c.clone_startup_command(image,restored['clone']),output_file=c.PRIVATE/(label+'-startup.private.log'),timeout=180)
    # Real ASGI fence probe on restored0093, with only synthetic route inputs.
    probe=PACKAGE/'clone-fence-probe.py'
    if sha_file(probe)!=m['wallet_probe_sha256']:raise ValueError('clone probe changed')
    c.run(*c._clone_runner(back['api'],restored['clone']),'--mount','type=bind,src='+str(probe)+',dst=/tmp/probe.py,readonly','--entrypoint','python',back['api'],'/tmp/probe.py',output_file=c.PRIVATE/'fence-probe.private.log',timeout=180)
    after=fingerprint(restored['clone']);snapshot=c.clone_snapshot(restored['clone'],after=True)
    if snapshot['schema']!=TARGET_SCHEMA or before!=after:raise ValueError('0094 migration changed existing financial facts')
    result={'clone_id':restored['clone_id'],'before':restored['before'],'after':snapshot,'facts_before':before,'facts_after':after,'candidate_started':True,'rollback_started':True,'fence_passed':True,'candidate_api_image':images['api'],'rollback_api_image':back['api']}
    c.write_private('clone-compatibility.json',result)
    return {'expand_clone_passed':True,'schema':TARGET_SCHEMA,'rollback_fence_passed':True,'financial_facts_unchanged':True}

def restore_finalize(m):
    restored=c.read_private('restore-running.json');proof=compatibility_proof()
    inspected=c.docker_inspect(restored['clone'])
    if inspected['Id']!=restored['clone_id'] or inspected['HostConfig']['NetworkMode']!='none' or proof['clone_id']!=restored['clone_id']:raise ValueError('clone changed before cleanup')
    if fingerprint(restored['clone'])!=proof['facts_after']:raise ValueError('clone facts changed after proof')
    cleanup=c._remove_clone_with_volumes(restored['clone'],inspected)
    c.write_private('restore.json',{'before_schema':BASE_SCHEMA,'after_schema':TARGET_SCHEMA,'clone_before':proof['before'],'clone_after':proof['after'],
      'clone_id':restored['clone_id'],'backup_sha256':restored['backup_sha256'],'candidate_images':restored['candidate_images'],'rollback_images':restored['rollback_images'],
      'candidate_and_rollback_started':True,'wallet_probe_sha256':m['wallet_probe_sha256'],'wallet_cases_exit':0,'fence_passed':True,**cleanup})
    return {'restore_completed':True,'clone_removed':True,'clone_volume_removed':True}

# Legacy helpers are reused with deliberately replaced schema/build/rehearsal paths.
c.build=build;c.probe_clone=probe_clone;c.restore_finalize=restore_finalize;c.clone_compatibility_proof=compatibility_proof
# Before restore production remains0093. After expansion preserve the identity check.
def assert_identity_schema(shape):
    if shape['schema'] not in (BASE_SCHEMA,TARGET_SCHEMA) or shape['column']!='YES:character varying:16' or not all(x in shape['check'] for x in ('entry_mode','STAFF','ADMIN')):raise ValueError('admin entry schema changed')
c.assert_production_0092=assert_identity_schema



def probe_worker(m):
    restored=c.read_private('restore-running.json');compatibility_proof()
    c.check_prepared(m,isolated_clone=restored)
    clone=c.docker_inspect(restored['clone'])
    if clone['Id']!=restored['clone_id'] or clone['HostConfig']['NetworkMode']!='none':raise ValueError('worker probe clone identity changed')
    image=c.read_private('images.json')['worker']
    probe=PACKAGE/'worker-probe.py';expected=PACKAGE/'worker-expected-sources.json'
    if sha_file(probe)!=m['worker_probe_sha256'] or sha_file(expected)!=m['worker_expected_sources_sha256']:raise ValueError('Worker probe manifest changed')
    # Worker real imports need its configured task workdir and installed app;
    # never inject PYTHONPATH or /opt/business-api into sys.path.
    command=['docker','run','--rm','--pull','never','--network','container:'+restored['clone'],'--read-only','--cap-drop','ALL','--security-opt','no-new-privileges','--memory','1g','--cpus','2','--pids-limit','256','--tmpfs','/tmp:rw,nosuid,size=128m','--workdir','/opt/business-worker/app','-e','PYTHONDONTWRITEBYTECODE=1','-e','BUSINESS_ENVIRONMENT=test','-e','SUPPORT_WORKER_PROBE_DATABASE_URL='+c.CLONE_DSN,'--mount','type=bind,src='+str(probe)+',dst=/probe/worker_probe.py,readonly','--mount','type=bind,src='+str(expected)+',dst=/probe/expected_sources.json,readonly','--entrypoint','python',image,'-c',"import runpy;runpy.run_path('/probe/worker_probe.py',run_name='__main__')",'--installed','--expected-sources','/probe/expected_sources.json']
    # Prove actual original installed Worker is unsafe using its own hashes,
    # then verify the final installed safety candidate in the same clone.
    old_sources=PACKAGE/'worker-baseline-expected-sources.json'
    if sha_file(old_sources)!=m['worker_baseline_expected_sources_sha256']:raise ValueError('baseline Worker source manifest changed')
    old=list(command)
    old[old.index(image)]=m['roles']['worker']['base_image']
    old=[x.replace(str(expected),str(old_sources)) for x in old]
    import subprocess
    with (c.PRIVATE/'worker-baseline-red.private.log').open('wb') as output:
        result=subprocess.run(old,stdout=output,stderr=subprocess.PIPE,timeout=360)
    (c.PRIVATE/'worker-baseline-red.stderr.private.log').write_bytes(result.stderr)
    if result.returncode!=1 or b'Worker must reject ambiguous cross-user receipts' not in result.stderr:raise ValueError('old Worker expected domain red was not reproduced')
    c.run(*command,output_file=c.PRIVATE/'worker-probe.private.log',timeout=360)
    result={'passed':True,'image':image,'clone_id':restored['clone_id'],'probe_sha256':m['worker_probe_sha256'],'actual_installed_imports':True,'original_worker_domain_red':True}
    c.write_private('worker-probe-result.json',result);return result

def validate_restore(m):
    baseline=c.read_private('baseline.json');proof=c.read_private('restore.json')
    if proof.get('before_schema')!=BASE_SCHEMA or proof.get('after_schema')!=TARGET_SCHEMA or proof.get('backup_sha256')!=baseline['backup_sha256'] or proof.get('candidate_images')!=c.read_private('images.json') or proof.get('rollback_images')!=c.read_private('rollback-images.json') or any(proof.get(x) is not True for x in ('candidate_and_rollback_started','clone_removed','clone_volume_removed','fence_passed')) or proof.get('wallet_probe_sha256')!=m['wallet_probe_sha256']:raise ValueError('complete frozen restore proof required')
    worker=c.read_private('worker-probe-result.json')
    if worker.get('passed') is not True or worker.get('image')!=c.read_private('images.json')['worker'] or worker.get('probe_sha256')!=m['worker_probe_sha256'] or worker.get('clone_id')!=proof.get('clone_id') or worker.get('actual_installed_imports') is not True or worker.get('original_worker_domain_red') is not True:raise ValueError('actual installed Worker compatibility proof required')
    archive=c.read_private('compatible-archive.json')
    if sha_file(c.PRIVATE/'compatible-images.tar')!=archive['sha256']:raise ValueError('compatible image archive changed')
    return baseline

def before_switch(m,expected_images,expected_schema):
    c.check_guard_sources(m);c.package_payload(m);baseline=c.read_private('baseline.json')
    if baseline['manifest_sha256']!=sha_file(MANIFEST) or sha_file(c.PRIVATE/'business.dump')!=baseline['backup_sha256']:raise ValueError('manifest or backup changed')
    if c.database_value('select version_num from alembic_version')!=expected_schema:raise ValueError('production schema drift')
    for role in ('api','worker'):
        if c.docker_inspect(ROLE_CONTAINER[role])['Image']!=expected_images[role]:raise ValueError('production role image drift')
        c._same_runtime_configuration(role)
        if c.container_inventory(ROLE_CONTAINER[role],role)!=c.image_inventory(expected_images[role],role):raise ValueError('runtime code changed from immutable image')
    c._other_containers_unchanged(baseline,m)
    for item in m['static']:
        if sha_file(FRONTEND/item['dest'])!=item['before_sha256']:raise ValueError('static drift before switch')
    # Original config files must remain unchanged, even after guard snapshot use.
    for role in ('api','worker'):
        original=c.read_private(role+'-container-inspect.json')['Config']['Labels']['com.docker.compose.project.config_files']
        if sha_file(Path(original))!=m['roles'][role]['compose_sha256']:raise ValueError('original Compose source changed')
    return baseline

def bridge_expand(m):
    # The fenced API retains exact production startup; its Alembic auto-upgrade
    # expands0094 before serving. No financial writes can pass its middleware.
    c.check_prepared(m);validate_restore(m)
    if (c.PRIVATE/'bridge-result.json').exists():raise ValueError('bridge already attempted')
    candidate=c.read_private('images.json');back=c.read_private('rollback-images.json')
    if back['api']==m['roles']['api']['base_image'] or back['worker']!=candidate['worker']:raise ValueError('unsafe rollback identity')
    bridge={'api':back['api'],'worker':m['roles']['worker']['base_image']}
    for role in ('api','worker'):
        config=c.read_private(role+'-rendered-compose.json')
        c._render_compose(role,'bridge',compose_with_image(config,ROLE_SERVICE[role],bridge[role]),bridge[role])
    c._guard('check',c.protocol_images(candidate,back))
    c.write_private('bridge-attempt.json',{'started_utc':utc(),'images':bridge})
    result=c._guard('deploy',services=['business-api'],version='bridge')
    health=c._selected_health(bridge,wait=True,replaced_roles=('api',))
    if c.database_value('select version_num from alembic_version')!=TARGET_SCHEMA:raise ValueError('fenced bridge did not expand0094')
    c.write_private('bridge-result.json',{'images':bridge,'schema':TARGET_SCHEMA,'guard_snapshot':result['snapshot'],'guard_snapshot_sha256':sha_file(Path(result['snapshot'])),'restart_counts':c._restart_counts(health),'containers':health})
    return {'bridge_fenced':True,'schema':TARGET_SCHEMA,'worker_original_until_dual_candidate_switch':True}


def activate_safe_worker(m):
    validate_restore(m);bridge=c.read_private('bridge-result.json')
    before_switch(m,bridge['images'],TARGET_SCHEMA)
    images=c.read_private('images.json');back=c.read_private('rollback-images.json')
    target={'api':back['api'],'worker':images['worker']}
    for role in ('api','worker'):
        config=c.read_private(role+'-rendered-compose.json')
        c._render_compose(role,'worker-bridge',compose_with_image(config,ROLE_SERVICE[role],target[role]),target[role])
    c._guard('check',c.protocol_images(images,back))
    result=c._guard('deploy',services=['business-worker'],version='worker-bridge')
    health=c._selected_health(target,wait=True,frozen=bridge['containers'],replaced_roles=('worker',))
    c.write_private('worker-bridge-result.json',{'images':target,'guard_snapshot':result['snapshot'],'guard_snapshot_sha256':sha_file(Path(result['snapshot'])),'restart_counts':c._restart_counts(health),'containers':health,'started_utc':utc()})
    return {'safe_worker_active':True,'api_write_fenced':True,'images':target}

def deploy(m):
    validate_restore(m);bridge=c.read_private('worker-bridge-result.json')
    baseline=before_switch(m,bridge['images'],TARGET_SCHEMA)
    images=c.read_private('images.json');back=c.read_private('rollback-images.json')
    c.check_candidate_compose(m,images);c.check_rollback_compose(m,back)
    c.check_merged_compose('candidate',images);c.check_merged_compose('rollback',back)
    c._guard('check',c.protocol_images(images,back))
    c.write_private('switch-attempt.json',{'started_utc':utc(),'images':images})
    try:
        result=c._guard('deploy',services=['business-api'],version='candidate')
        health=c._selected_health(images,wait=True,frozen=bridge['containers'],replaced_roles=('api',));c._publish_static(m);c._other_containers_unchanged(baseline,m)
        c.write_private('deployed.json',{'deployed_utc':utc(),'images':images,'restart_counts':c._restart_counts(health),'containers':health,'guard_snapshot':result['snapshot'],'guard_snapshot_sha256':sha_file(Path(result['snapshot']))})
        return {'deployed':True,'images':images,'schema':TARGET_SCHEMA,'static_files':len(m['static'])}
    except Exception:
        rollback(m);raise

def rollback(m):
    validate_restore(m)
    # Patched r3 rollback rejects originalAPI, requires safeWorker and0094;
    # dual-role guard activates fencedAPI+safeWorker and preserves all records.
    return c.rollback(m)

def verify(m):
    result=c.read_private('deployed.json');images=c.read_private('images.json')
    if result['images']!=images or c.database_value('select version_num from alembic_version')!=TARGET_SCHEMA:raise ValueError('deployed identity drift')
    health=c._selected_health(images,wait=False,frozen=result['containers']);c._other_containers_unchanged(c.read_private('baseline.json'),m)
    snapshot=Path(result['guard_snapshot'])
    if snapshot.is_symlink() or sha_file(snapshot)!=result['guard_snapshot_sha256']:raise ValueError('guarded Compose snapshot changed')
    for role in ('api','worker'):
        info=c.docker_inspect(ROLE_CONTAINER[role]);labels=info['Config']['Labels']
        role_snapshot=snapshot if role=='api' else Path(c.read_private('worker-bridge-result.json')['guard_snapshot'])
        if labels['com.docker.compose.project.config_files']!=str(role_snapshot):raise ValueError('role not bound to its actual guard snapshot')
        if role=='worker' and sha_file(role_snapshot)!=c.read_private('worker-bridge-result.json')['guard_snapshot_sha256']:raise ValueError('Worker guard snapshot changed')
        c._same_runtime_configuration(role)
        for item in m['roles'][role]['files']:
            if c.live_hash(ROLE_CONTAINER[role],item['dest'])!=item['after_sha256']:raise ValueError('actual runtime source SHA changed')
    for item in m['static']:
        if sha_file(FRONTEND/item['dest'])!=item['after_sha256']:raise ValueError('public static source drift')
    logs=c._post_switch_logs(c.read_private('switch-attempt.json')['started_utc'])
    c.write_private('verified.json',{'verified_utc':utc(),'images':images,'schema':TARGET_SCHEMA,'restart_counts':c._restart_counts(health),'post_switch_logs':logs,'public_tls':'server and workstation checks still required'})
    return {'verified':True,'roles':2,'schema':TARGET_SCHEMA,'public_tls':'separate required'}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('operation',choices=['preflight','prepare','build','restore','probe-clone','probe-worker','restore-finalize','bridge-expand','activate-safe-worker','deploy','rollback','verify']);args=p.parse_args()
    if PACKAGE!=c.RELEASE_ROOT:raise SystemExit('dedicated server release directory required')
    m=validate_manifest(json.loads(MANIFEST.read_text(encoding='utf-8')))
    operations={'preflight':lambda:{'schema':c.preflight(m)['schema']},'prepare':lambda:c.prepare(m),'build':lambda:build(m),'restore':lambda:c.restore(m),'probe-clone':lambda:probe_clone(m),'probe-worker':lambda:probe_worker(m),'restore-finalize':lambda:restore_finalize(m),'bridge-expand':lambda:bridge_expand(m),'activate-safe-worker':lambda:activate_safe_worker(m),'deploy':lambda:deploy(m),'rollback':lambda:rollback(m),'verify':lambda:verify(m)}
    print(json.dumps(operations[args.operation](),ensure_ascii=False),flush=True)
if __name__=='__main__':main()
