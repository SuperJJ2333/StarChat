"""Runnable controlled Task14 operations; inherit r3 snapshot/Compose/guard checks.

All operations are explicit. There are no network, Docker or file writes at
import. A final frozen manifest/payload and dedicated server path are required.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import shutil
import copy
from contextlib import contextmanager
from uuid import uuid4
import server_r3 as c
from release import *
from release import _atomic_replace
from finance_write_fence import FACTORY_SUFFIX

ORIGINAL_BUILD=c.build
ORIGINAL_ROLLBACK=c.rollback
ORIGINAL_DEPLOY=c.deploy
ORIGINAL_COMPOSE_WITH_IMAGE=compose_with_image

def role_compose(config,service):
    services=config.get('services',{})
    if service not in ROLE_SERVICE.values() or service not in services or not set(services)<=set(ROLE_SERVICE.values()):
        raise ValueError('unexpected Compose service scope')
    result=copy.deepcopy(config);result['services']={service:result['services'][service]}
    return result

def compose_with_image(config,service,image):
    return ORIGINAL_COMPOSE_WITH_IMAGE(role_compose(config,service),service,image)

def render_role_compose(role,name,config,expected_image):
    path=c.write_private(role+'-'+name+'.json',config)
    rendered=json.loads(c.run('docker','compose','-p','starchat','-f',str(path),'config','--format','json'))
    expected=role_compose(c.read_private(role+'-rendered-compose.json'),ROLE_SERVICE[role])
    expected['services'][ROLE_SERVICE[role]]['image']=expected_image
    if rendered!=expected:raise ValueError('role Compose changed beyond its own image')

def check_frozen_role_compose(version,images):
    if version not in ('candidate','rollback') or set(images)!={'api','worker'}:raise ValueError('frozen Compose roles/version required')
    for role,service in ROLE_SERVICE.items():
        path=c.PRIVATE/(role+'-'+version+'.json')
        rendered=json.loads(c.run('docker','compose','-p','starchat','-f',str(path),'config','--format','json'))
        expected=role_compose(c.read_private(role+'-rendered-compose.json'),service)
        expected['services'][service]['image']=images[role]
        if rendered!=expected:raise ValueError('frozen role Compose configuration drift')

c._render_compose=render_role_compose
c._check_frozen_compose=check_frozen_role_compose

def own_role_compose_input(container,role,expected_sha):
    labels=container['Config']['Labels'];service=ROLE_SERVICE[role]
    if labels.get('com.docker.compose.project')!='starchat' or labels.get('com.docker.compose.service')!=service:
        raise ValueError('container is outside expected Compose project/service')
    files=labels['com.docker.compose.project.config_files'].split(',')
    if len(files)!=1:raise ValueError('unexpected Compose layer count; manual rebase required')
    path=Path(files[0])
    if c.sha_file(path)!=expected_sha:raise ValueError('Compose source SHA drift')
    config=json.loads(c.run('docker','compose','-p','starchat','-f',str(path),'config','--format','json'))
    owned=role_compose(config,service)['services'][service]
    if owned.get('image')!=container['Image']:raise ValueError('own-role Compose image mismatch')
    runtime_env=dict(item.split('=',1) for item in container['Config']['Env'] if '=' in item)
    if any((key in runtime_env if value is None else runtime_env.get(key)!=str(value)) for key,value in owned.get('environment',{}).items()):
        raise ValueError('own-role running environment differs from Compose')
    return path,config

def own_role_source_consistency(configs):
    if set(configs)!={'api','worker'}:raise ValueError('both Compose role sources are required')
    top=None
    for role,record in configs.items():
        config=role_compose(record['rendered'],ROLE_SERVICE[role])
        current={key:value for key,value in config.items() if key!='services'}
        if top is not None and current!=top:raise ValueError('Compose source top-level configuration differs')
        top=current

def own_role_merged_baseline(manifest,configs):
    import tempfile,os
    own_role_source_consistency(configs)
    expected=copy.deepcopy(configs['api']['rendered'])
    expected['services']={ROLE_SERVICE[role]:copy.deepcopy(configs[role]['rendered']['services'][ROLE_SERVICE[role]]) for role in ('api','worker')}
    # Preflight precedes PRIVATE creation. Derived inputs never expose runtime environment.
    with tempfile.TemporaryDirectory(prefix='support-role-compose-') as directory:
        os.chmod(directory,0o700)
        command=['docker','compose','-p','starchat']
        for role in ('api','worker'):
            path=Path(directory)/(role+'.json')
            descriptor=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
            with os.fdopen(descriptor,'w',encoding='utf-8') as stream:
                json.dump(role_compose(configs[role]['rendered'],ROLE_SERVICE[role]),stream)
            command+=['-f',str(path)]
        merged=json.loads(c.run(*command,'config','--format','json'))
    if merged!=expected:raise ValueError('merged baseline differs from authoritative role configurations')
    for role,service in ROLE_SERVICE.items():
        runtime=c.docker_inspect(ROLE_CONTAINER[role])
        if merged['services'][service].get('image')!=manifest['roles'][role]['base_image'] or runtime['Image']!=manifest['roles'][role]['base_image']:
            raise ValueError('merged baseline Compose image mismatch')
        env=dict(item.split('=',1) for item in runtime['Config']['Env'] if '=' in item)
        if any((key in env if value is None else env.get(key)!=str(value)) for key,value in merged['services'][service].get('environment',{}).items()):
            raise ValueError('merged baseline Compose environment mismatch')
    return merged

c.compose_input=own_role_compose_input
c.assert_source_compose_consistency=own_role_source_consistency
c.render_merged_baseline=own_role_merged_baseline

def verify_existing_overlay(role,base,image,files):
    # Config includes Cmd/Entrypoint/Env/User/WorkingDir and all other image runtime fields.
    if c.docker_inspect(base)['Config']!=c.docker_inspect(image)['Config']:
        raise ValueError('reused image runtime Config differs from frozen base')
    before=c.image_inventory(base,role)
    for item in files:
        if before.get(item['dest'])!=item['before_sha256'] or sha_file(Path(item['payload']))!=item['after_sha256']:
            raise ValueError('reused overlay source or base SHA drift')
    assert_exact_inventory_delta(before,c.image_inventory(image,role),{item['dest']:item['after_sha256'] for item in files})

ACTUAL_API_CMD=['uvicorn','app.main:create_default_app','--factory','--host','0.0.0.0','--port','8082','--workers','2']

def validate_actual_startup(config):
    if config.get('Cmd')!=ACTUAL_API_CMD or config.get('Entrypoint') not in (None,[]):
        raise ValueError('unreviewed API actual startup/entry')
    return list(config['Cmd'])

@contextmanager
def exclusive_bridge_lock():
    import fcntl
    with (c.PRIVATE/'bridge-operation.lock').open('a',encoding='utf-8') as lock:
        fcntl.flock(lock.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
        try:yield
        finally:fcntl.flock(lock.fileno(),fcntl.LOCK_UN)

LIVE_FENCE_CODE='''
import json,urllib.request,urllib.error,shutil
assert shutil.which('timeout'),'remote bounded process runner unavailable'
base='http://127.0.0.1:8082/api/v1'
with urllib.request.urlopen(base+'/health/ready',timeout=10) as response:
    ready=json.load(response)
    assert response.status==200 and ready.get('ok') is True and ready.get('database')=='ready'
paths=['/admin/support-orders/payouts/release-synthetic/adjust-rate','/wallet/manual/admin/payouts/release-synthetic/void-unbroadcast','/recharge/admin/requests/release-synthetic/execute-settlement']
for path in paths:
    request=urllib.request.Request(base+path,data=b'{}',headers={'Content-Type':'application/json'},method='POST')
    try:response=urllib.request.urlopen(request,timeout=10)
    except urllib.error.HTTPError as error:response=error
    with response:
        body=json.load(response)
        assert response.status==503 and body['error']['code']=='SUPPORT_FINANCE_RELEASE_WRITE_FENCE'
        assert set(body['error'])=={'code','message','trace_id','fields'} and body['error']['fields']=={}
        assert response.headers.get('Cache-Control')=='no-store'
print(json.dumps({'passed':True,'actual_http':True,'ready_json':True,'blocked_routes':paths,'remote_timeout_available':True}))
'''

def bridge_runtime_fence(health,snapshot):
    current=c.docker_inspect(health['api']['Id'])
    if (current['Id']!=health['api']['Id'] or current['Image']!=health['api']['Image']
            or current['Config']['Labels']['com.docker.compose.project.config_files']!=str(snapshot)):
        raise ValueError('bridge identity or guarded Compose changed')
    validate_actual_startup(current['Config']);c._same_runtime_configuration('api')
    proof=json.loads(c.run('docker','exec',current['Id'],'python','-c',LIVE_FENCE_CODE,timeout=60))
    if proof.get('passed') is not True or proof.get('actual_http') is not True:
        raise ValueError('actual bridge HTTP fence required')
    return {**proof,'container_id':current['Id'],'image':current['Image'],'guard_snapshot':str(snapshot),'guard_snapshot_sha256':sha_file(Path(snapshot))}

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
    validate_actual_startup(api_config)
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
    return finalize_built_images(m,images,back)

def finalize_built_images(m,images,back):
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

def frozen_rollback_sources(m):
    base=m['roles']['api']['base_image'];inventory=c.image_inventory(base,'api')
    main_dest='/opt/business-api/app/main.py'
    code=c.run('docker','run','--rm','--pull','never','--network','none','--read-only','--cap-drop','ALL','--security-opt','no-new-privileges','--entrypoint','python',base,'-c',"from pathlib import Path; import base64; print(base64.b64encode(Path('/opt/business-api/app/main.py').read_bytes()).decode())")
    import base64
    original=base64.b64decode(code)
    if sha_bytes(original)!=inventory.get(main_dest):raise ValueError('original rollback factory changed')
    generated=c.PRIVATE/'rollback-generated'/'main.py'
    if generated.is_symlink() or generated.read_bytes()!=original+FACTORY_SUFFIX.encode():raise ValueError('generated rollback factory differs from frozen intent')
    fence=PACKAGE/'finance_write_fence.py'
    if sha_file(fence)!=m['rollback_fence_sha256']:raise ValueError('rollback fence source differs from manifest')
    migration=next(x for x in m['roles']['api']['files'] if x['source'].endswith('0094_support_finance_order_recovery.py'))
    expected=[{'dest':main_dest,'before_sha256':inventory[main_dest],'after_sha256':sha_file(generated),'payload':str(generated)},
      {'dest':'/opt/business-api/app/release_finance_write_fence.py','before_sha256':None,'after_sha256':sha_file(fence),'payload':str(fence)},
      {**migration,'payload':str(PACKAGE/'payload'/migration['source'])}]
    if c.read_private('rollback-overlay.json')!=expected:raise ValueError('saved rollback source intent drift')
    return expected

def resume_build(m,expected):
    c.check_prepared(m)
    validate_actual_startup(c.read_private('api-container-inspect.json')['Config'])
    if set(expected)!={'api','worker','rollback_api'}:raise ValueError('three explicit immutable resume IDs required')
    for image in expected.values():c._image(image)
    blocked=['images.json','rollback-images.json','build-protocol-proofs.json','compatible-images.tar','compatible-archive.json','bridge-attempt.json','worker-bridge-result.json','deployed.json']
    if any((c.PRIVATE/name).exists() for name in blocked):raise ValueError('build already finalized or production phase attempted; reviewed recovery required')
    labels={'api':'candidate-api','worker':'candidate-worker','rollback_api':'rollback-api-fenced'}
    for key,label in labels.items():
        tag='starchat-'+RELEASE_ID+'-'+label
        if c.docker_inspect(tag)['Id']!=expected[key]:raise ValueError('existing build tag differs from explicit frozen image ID')
    images={role:expected[role] for role in ('api','worker')};back={'api':expected['rollback_api'],'worker':expected['worker']}
    for role in ('api','worker'):
        verify_existing_overlay(role,m['roles'][role]['base_image'],images[role],role_payload(m['roles'][role]))
    verify_existing_overlay('api',m['roles']['api']['base_image'],back['api'],frozen_rollback_sources(m))
    # Keep contexts/generated sources untouched. Preserve only old derived files
    # under a unique0700 attempt directory before writing role-only replacements.
    attempt='resume-build-'+uuid4().hex;directory=c.PRIVATE/attempt;directory.mkdir(mode=0o700)
    evidence={'started_utc':utc(),'manifest_sha256':sha_file(MANIFEST),'images':images,'rollback_images':back,'preserved_derived':{},'contexts_retained':True}
    for role in ('api','worker'):
        for version in ('candidate','rollback'):
            name=role+'-'+version+'.json';path=c.PRIVATE/name
            if path.exists():
                if path.is_symlink() or not path.is_file():raise ValueError('unsafe old derived Compose path')
                evidence['preserved_derived'][name]=sha_file(path);path.rename(directory/name)
    c.write_private(attempt+'/attempt.json',evidence)
    try:
        result=finalize_built_images(m,images,back)
        c.write_private(attempt+'/result.json',{'completed_utc':utc(),'images':images,'rollback_images':back,'fresh_role_compose':True,'guard_check_and_archive':True})
        return {**result,'resumed_existing_images':True,'attempt':attempt}
    except Exception:
        c.write_private(attempt+'/failure.json',{'failed_utc':utc(),'recovery':'preserve contexts and this attempt; inspect phase artifacts before a separately reviewed retry'})
        raise

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
    with exclusive_bridge_lock():return _bridge_expand_locked(m)

def _bridge_expand_locked(m):
    # Preserve direct Uvicorn startup. Fence first on0093, then one bounded DDL process.
    c.check_prepared(m);validate_restore(m)
    if (c.PRIVATE/'bridge-attempt.json').exists():raise ValueError('bridge already attempted; reviewed recovery required')
    candidate=c.read_private('images.json');back=c.read_private('rollback-images.json')
    if back['api']==m['roles']['api']['base_image'] or back['worker']!=candidate['worker']:raise ValueError('unsafe rollback identity')
    bridge={'api':back['api'],'worker':m['roles']['worker']['base_image']}
    for role in ('api','worker'):
        config=c.read_private(role+'-rendered-compose.json')
        c._render_compose(role,'bridge',compose_with_image(config,ROLE_SERVICE[role],bridge[role]),bridge[role])
    c._guard('check',c.protocol_images(candidate,back))
    c.write_private('bridge-attempt.json',{'started_utc':utc(),'images':bridge})
    result={};phase='guarded-fence-switch'
    try:
        result=c._guard('deploy',services=['business-api'],version='bridge')
        phase='guarded-fence-health'
        health=c._selected_health(bridge,wait=True,replaced_roles=('api',))
        if c.database_value('select version_num from alembic_version')!=BASE_SCHEMA:raise ValueError('bridge must serve on frozen0093 before migration')
        proof=bridge_runtime_fence(health,result['snapshot'])
        c.write_private('bridge-fenced.json',{'images':bridge,'schema':BASE_SCHEMA,'fence':proof,'containers':health,'guard_snapshot':result['snapshot'],'guard_snapshot_sha256':sha_file(Path(result['snapshot']))})
        phase='single-bounded-expand'
        current=c.docker_inspect(health['api']['Id'])
        if current['Id']!=health['api']['Id'] or current['Image']!=bridge['api'] or c.database_value('select version_num from alembic_version')!=BASE_SCHEMA:raise ValueError('bridge ID/image/schema changed before migration')
        c.write_private('bridge-migration-attempt.json',{'started_utc':utc(),'container_id':current['Id'],'image':current['Image'],'before_schema':BASE_SCHEMA,'target_schema':TARGET_SCHEMA,'process_timeout_seconds':150,'lock_timeout_ms':5000,'statement_timeout_ms':120000})
        c.run('docker','exec','-e','PGOPTIONS=-c lock_timeout=5000 -c statement_timeout=120000',current['Id'],'timeout','--signal=TERM','--kill-after=10s','150s','python','-m','alembic','upgrade',TARGET_SCHEMA,output_file=c.PRIVATE/'bridge-migration.private.log',timeout=180)
        if c.database_value('select version_num from alembic_version')!=TARGET_SCHEMA:raise ValueError('explicit bridge expansion did not reach0094')
        phase='expanded-bridge-health'
        health=c._selected_health(bridge,wait=True,frozen=health)
        c.write_private('bridge-result.json',{'images':bridge,'schema':TARGET_SCHEMA,'guard_snapshot':result['snapshot'],'guard_snapshot_sha256':sha_file(Path(result['snapshot'])),'restart_counts':c._restart_counts(health),'containers':health,'fence_before_migration':proof,'migration':'single bounded docker exec'})
    except Exception:
        c.write_private('bridge-failure.json',{'failed_utc':utc(),'phase':phase,'images':bridge,'guard_snapshot':result.get('snapshot'),'recovery':'retain actual guarded state; inspect containers, fence, head and process; no automatic retry, Worker or final API switch'})
        raise
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
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('operation',choices=['preflight','prepare','build','resume-build','restore','probe-clone','probe-worker','restore-finalize','bridge-expand','activate-safe-worker','deploy','rollback','verify'])
    p.add_argument('--candidate-api');p.add_argument('--candidate-worker');p.add_argument('--rollback-api');args=p.parse_args()
    if args.operation=='resume-build' and not all((args.candidate_api,args.candidate_worker,args.rollback_api)):p.error('resume-build requires all three immutable image IDs')
    if args.operation!='resume-build' and any((args.candidate_api,args.candidate_worker,args.rollback_api)):p.error('immutable resume IDs apply only to resume-build')
    if PACKAGE!=c.RELEASE_ROOT:raise SystemExit('dedicated server release directory required')
    m=validate_manifest(json.loads(MANIFEST.read_text(encoding='utf-8')))
    operations={'preflight':lambda:{'schema':c.preflight(m)['schema']},'prepare':lambda:c.prepare(m),'build':lambda:build(m),'resume-build':lambda:resume_build(m,{'api':args.candidate_api,'worker':args.candidate_worker,'rollback_api':args.rollback_api}),'restore':lambda:c.restore(m),'probe-clone':lambda:probe_clone(m),'probe-worker':lambda:probe_worker(m),'restore-finalize':lambda:restore_finalize(m),'bridge-expand':lambda:bridge_expand(m),'activate-safe-worker':lambda:activate_safe_worker(m),'deploy':lambda:deploy(m),'rollback':lambda:rollback(m),'verify':lambda:verify(m)}
    print(json.dumps(operations[args.operation](),ensure_ascii=False),flush=True)
if __name__=='__main__':main()
