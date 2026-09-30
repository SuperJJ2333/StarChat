from pathlib import Path
import importlib.util
import json
import sys
import pytest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('support_release', HERE / 'release_prep.py')
r = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = r
spec.loader.exec_module(r)
H = 'a'*64
CANDIDATE = 'sha256:'+'b'*64

def manifest():
    return {'release_id':r.RELEASE_ID,'frozen':True,'source_commit':'c'*40,
      'before_schema':r.BASE_SCHEMA,'after_schema':r.TARGET_SCHEMA,
      'guard_sha256':r.GUARD_SHA,'guard_probe_sha256':r.PROBE_SHA,
      'clone_image':'sha256:'+'d'*64,
      'roles':{role:{'base_image':image,'compose_sha256':H,'files':[
        {'source':source,'dest':r.image_dest(source),'before_sha256':None if source==r.MIGRATION else H,'after_sha256':H}
        for source in sorted(r.API_SOURCES)] if role=='api' else [{'source':source,'dest':dest,'before_sha256':None if source==r.MIGRATION else H,'after_sha256':H} for source,dest in sorted(r.worker_destinations())]}
        for role,image in [('api',r.BASE_API),('worker',r.BASE_WORKER)]},
      'static':[{'source':source,'dest':source.removeprefix('frontend/'),'before_sha256':H,'after_sha256':H} for source in sorted(r.STATIC_SOURCES)]}

def test_exact_allowlists_and_base_identity():
    m=manifest();r.validate_manifest(m)
    assert r.MIGRATION in r.API_SOURCES
    assert len(m['roles']['worker']['files'])==11
    assert len(m['static'])==4
    for change in ('extra','missing','base','worker','destination','new-existing'):
        value=manifest()
        if change=='extra':value['roles']['api']['files'].append({'source':'services/business-api/app/main.py','dest':'/opt/business-api/app/main.py','before_sha256':H,'after_sha256':H})
        if change=='missing':value['roles']['api']['files'].pop()
        if change=='base':value['roles']['api']['base_image']='sha256:'+'e'*64
        if change=='worker':value['roles']['worker']['files']=[value['roles']['api']['files'][0]]
        if change=='destination':value['static'][0]['dest']='../admin.html'
        if change=='new-existing':next(x for x in value['roles']['api']['files'] if x['source']==r.MIGRATION)['before_sha256']=H
        with pytest.raises(ValueError):r.validate_manifest(value)

def test_unfrozen_candidate_cannot_stage_or_plan(tmp_path):
    value=manifest();value['frozen']=False
    with pytest.raises(ValueError):r.stage_payload(value,tmp_path,tmp_path/'out')
    with pytest.raises(ValueError):r.release_plan(value,CANDIDATE)

def test_inventory_overlay_accepts_one_new_migration_and_rejects_unlisted_change():
    before={'/opt/business-api/app/main.py':H,'/opt/business-api/app/api/recharge.py':'e'*64}
    expected={'/opt/business-api/app/api/recharge.py':H,'/opt/business-api/migrations/versions/0093.py':H}
    after=before|expected;r.assert_inventory_delta(before,after,expected)
    with pytest.raises(ValueError):r.assert_inventory_delta(before,after|{'/opt/business-api/app/main.py':'f'*64},expected)

def test_declared_unchanged_binding_gate_remains_hash_bound():
    gate='/opt/business-api/app/modules/wallet/recharge_binding_gate.py'
    changed='/opt/business-api/app/api/recharge.py'
    before={gate:H,changed:'e'*64}
    expected={gate:H,changed:'f'*64}
    r.assert_inventory_delta(before,before|expected,expected)
    with pytest.raises(ValueError):
        r.assert_inventory_delta(before,{gate:'b'*64,changed:'f'*64},expected)

def test_dual_role_guard_and_clone_migration_commands_are_isolated():
    m=manifest();plan=r.release_plan(m,CANDIDATE)
    check=plan['guard_check'];assert check.count('--api-image')==2;assert check.count('--worker-image')==2
    assert r.BASE_API in check and r.BASE_WORKER in check and CANDIDATE in check
    clone=plan['clone_start'];assert clone[clone.index('--network')+1]=='none';assert '-p' not in clone and '-v' not in clone
    migrate=plan['clone_migrate'];assert 'container:'+r.CLONE_NAME in migrate
    assert '--read-only' in migrate and '--cap-drop' in migrate and 'no-new-privileges' in migrate
    assert migrate[-3:]==['alembic','upgrade',r.TARGET_SCHEMA]
    assert plan['clone_restore'][0:3]==['docker','exec','-i']
    assert plan['clone_restore_stdin']=='private/business.dump'
    assert 'downgrade' not in json.dumps(plan)
    assert 'deploy' not in plan

def test_guard_requires_exact_role_assertions():
    images={'api':[CANDIDATE,r.BASE_API],'worker':[r.BASE_WORKER,r.BASE_WORKER]}
    proof=[{'role':role,'image':image,'passed':True} for role,values in images.items() for image in set(values)]
    r.validate_guard_proof(proof,images)
    with pytest.raises(ValueError):r.validate_guard_proof(proof[:-1],images)
    with pytest.raises(ValueError):r.validate_guard_proof(proof+[proof[0]],images)

def test_post_expand_old_image_rollback_requires_real_write_fence():
    with pytest.raises(ValueError):r.rollback_gate({'schema':r.TARGET_SCHEMA,'write_fence':{'closed':True}})
    with pytest.raises(ValueError):r.rollback_gate({'schema':r.TARGET_SCHEMA,'write_fence':{'closed':True,'payout':True,'recharge':False,'tested':True,'sha256':H}})
    proof={'schema':r.TARGET_SCHEMA,'write_fence':{'closed':True,'payout':True,'recharge':True,'tested':True,'sha256':H}}
    r.rollback_gate(proof)
    assert proof['schema']==r.TARGET_SCHEMA

def test_atomic_static_backup_switch_and_drift_refusal(tmp_path):
    live=tmp_path/'live';payload=tmp_path/'payload';backup=tmp_path/'backup';live.mkdir();payload.mkdir()
    targets=[]
    for name in ['src/a.js','src/b.js']:
        old=b'before';new=b'after';(live/name).parent.mkdir(exist_ok=True,parents=True);(payload/name).parent.mkdir(exist_ok=True,parents=True)
        (live/name).write_bytes(old);(payload/name).write_bytes(new)
        targets.append({'dest':name,'before_sha256':r.sha_bytes(old),'after_sha256':r.sha_bytes(new)})
    r.backup_static(targets,live,backup)
    (live/'src/b.js').write_bytes(b'drift')
    with pytest.raises(ValueError):r.publish_static(targets,live,payload)
    assert (live/'src/a.js').read_bytes()==b'before'
    (live/'src/b.js').write_bytes(b'before');r.publish_static(targets,live,payload)
    assert (live/'src/a.js').read_bytes()==b'after'
    r.restore_static(targets,live,backup)
    assert (live/'src/b.js').read_bytes()==b'before'

def test_clone_proof_requires_heads_and_preserved_financial_fingerprints():
    evidence={'before_schema':r.BASE_SCHEMA,'after_schema':r.TARGET_SCHEMA,
      'backup_sha256':H,'restored_backup_sha256':H,'before_ledger_sha256':H,'after_ledger_sha256':H,
      'before_payout_sha256':H,'after_payout_sha256':H,'before_recharge_sha256':H,'after_recharge_sha256':H,
      'candidate_ready':True,'base_ready_after_expand':True,'new_state_old_writes_fail_closed':True,'clone_network':'none'}
    r.validate_clone_proof(evidence)
    evidence['after_ledger_sha256']='e'*64
    with pytest.raises(ValueError):r.validate_clone_proof(evidence)
