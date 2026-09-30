from pathlib import Path
import sys,json
import pytest
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
import server_release as s
import public_verify as p
import release_prep as r

def container(cid,image,restarts=0):
    return {'Id':cid,'Image':image,'RestartCount':restarts,'State':{'Status':'running','Health':{'Status':'healthy'}}}

@pytest.mark.parametrize('phase', ['activation','rollback'])
def test_intentional_worker_recreation_is_frozen_after_switch(monkeypatch,phase):
    original={role:container('old-'+role,'old-'+role) for role in ('api','worker')}
    current={role:container('new-'+role,'new-'+role) for role in ('api','worker')}
    monkeypatch.setattr(s.c,'docker_inspect',lambda name:current['api' if name.endswith('api-1') else 'worker'])
    result=s.c._selected_health({role:'new-'+role for role in current},wait=False,
        frozen=original,replaced_roles=('api','worker') if phase=='rollback' else ('worker','api'))
    assert result['worker']['Id']=='new-worker'
    assert s.c._selected_health({role:'new-'+role for role in current},wait=False,frozen=result)==result
    current['worker']=container('unplanned-worker','new-worker')
    with pytest.raises(ValueError,match='identity drift'):
        s.c._selected_health({role:'new-'+role for role in current},wait=False,frozen=result)

def test_recreated_worker_with_restart_is_rejected(monkeypatch):
    original={role:container('old-'+role,'old-'+role) for role in ('api','worker')}
    current=original|{'worker':container('new-worker','new-worker',1)}
    monkeypatch.setattr(s.c,'docker_inspect',lambda name:current['api' if name.endswith('api-1') else 'worker'])
    with pytest.raises(ValueError,match='restart count'):
        s.c._selected_health({'api':'old-api','worker':'new-worker'},wait=False,frozen=original,replaced_roles=('worker',))

def test_activation_freezes_worker_identity_and_verify_enforces_it(monkeypatch,tmp_path):
    images={'api':'fenced-api','worker':'safe-worker'}
    original={'api':container('bridge-api','fenced-api'),'worker':container('old-worker','old-worker')}
    current=original|{'worker':container('new-worker','safe-worker')}
    snapshot=tmp_path/'snapshot';snapshot.write_text('compose')
    for value in current.values():value['Config']={'Labels':{'com.docker.compose.project.config_files':str(snapshot)}}
    records={'bridge-result.json':{'images':{'api':'fenced-api','worker':'old-worker'},'containers':original},'images.json':images,'rollback-images.json':images,
        'api-rendered-compose.json':{},'worker-rendered-compose.json':{},'baseline.json':{},'switch-attempt.json':{'started_utc':'now'}}
    monkeypatch.setattr(s.c,'read_private',lambda name:records[name])
    monkeypatch.setattr(s.c,'write_private',lambda name,data:records.__setitem__(name,data))
    monkeypatch.setattr(s.c,'docker_inspect',lambda name:current['api' if name.endswith('api-1') else 'worker'])
    monkeypatch.setattr(s,'validate_restore',lambda m:None)
    monkeypatch.setattr(s,'before_switch',lambda *a:None)
    monkeypatch.setattr(s,'compose_with_image',lambda *a:{})
    monkeypatch.setattr(s.c,'_render_compose',lambda *a:None)
    monkeypatch.setattr(s.c,'protocol_images',lambda *a:{})
    monkeypatch.setattr(s.c,'_guard',lambda *a,**kw:{'snapshot':str(snapshot)})
    assert s.activate_safe_worker({})['safe_worker_active'] is True
    checkpoint=records['worker-bridge-result.json'];assert checkpoint['containers']['worker']['Id']=='new-worker'
    records['deployed.json']=checkpoint
    monkeypatch.setattr(s.c,'database_value',lambda *a:r.TARGET_SCHEMA)
    monkeypatch.setattr(s.c,'_other_containers_unchanged',lambda *a:None)
    monkeypatch.setattr(s.c,'_same_runtime_configuration',lambda *a:None)
    monkeypatch.setattr(s.c,'_post_switch_logs',lambda *a:{})
    m={'roles':{'api':{'files':[]},'worker':{'files':[]}},'static':[]}
    assert s.verify(m)['verified'] is True
    current['worker']=container('unexpected-worker','safe-worker')
    with pytest.raises(ValueError,match='identity drift'):s.verify(m)

def test_real_rollback_accepts_guarded_worker_recreation(monkeypatch,tmp_path):
    images={'api':'candidate-api','worker':'safe-worker'};back={'api':'fenced-api','worker':'safe-worker'}
    records={'baseline.json':{'manifest_sha256':'hash'},'images.json':images,'rollback-images.json':back}
    records.update({role+'-container-inspect.json':container('old-'+role,'old-'+role) for role in ('api','worker')})
    current={role:container('recreated-'+role,back[role]) for role in ('api','worker')}
    monkeypatch.setattr(s.c,'PRIVATE',tmp_path)
    monkeypatch.setattr(s.c,'read_private',lambda name:records[name])
    monkeypatch.setattr(s.c,'write_private',lambda name,data:records.__setitem__(name,data))
    monkeypatch.setattr(s.c,'sha_file',lambda *a:'hash')
    monkeypatch.setattr(s.c,'database_value',lambda *a:r.TARGET_SCHEMA)
    monkeypatch.setattr(s.c,'docker_inspect',lambda name:current['api' if name.endswith('api-1') else 'worker'])
    for name in ('check_guard_sources','_check_rollback_archive','package_payload','_same_runtime_configuration','_other_containers_unchanged','check_rollback_compose','check_merged_compose','assert_managed_api_ingress'):
        monkeypatch.setattr(s.c,name,lambda *a:None)
    monkeypatch.setattr(s.c,'protocol_images',lambda *a:{})
    monkeypatch.setattr(s.c,'_guard',lambda *a,**kw:{'snapshot':'rollback-compose'})
    m={'roles':{role:{'base_image':'baseline-'+role} for role in ('api','worker')},'static':[]}
    result=s.c.rollback(m)
    assert result['containers']['worker']['Id']=='recreated-worker'
    assert result['restart_counts']=={'api':0,'worker':0}

def test_server_cli_includes_separate_safe_worker_stage():
    code=(HERE/'server_release.py').read_text(encoding='utf-8')
    assert "services=['business-api'],version='bridge'" in code
    assert "services=['business-worker'],version='worker-bridge'" in code
    assert "services=['business-api'],version='candidate'" in code
    assert "worker.get('original_worker_domain_red') is not True" in code
    assert "c._same_runtime_configuration(role)" in code
    assert "c.container_inventory(ROLE_CONTAINER[role],role)!=c.image_inventory(expected_images[role],role)" in code

def test_deploy_is_blocked_without_restore_worker_proof(monkeypatch):
    monkeypatch.setattr(s.c,'read_private',lambda name: {})
    with pytest.raises((KeyError,ValueError)):s.deploy({})

def test_restore_requires_preserved_facts_and_fenced_rollback(monkeypatch):
    good={'before':{'schema':r.BASE_SCHEMA},'after':{'schema':r.TARGET_SCHEMA},'candidate_started':True,'rollback_started':True,'facts_before':{'ledger':'x'},'facts_after':{'ledger':'x'},'fence_passed':True}
    monkeypatch.setattr(s.c,'read_private',lambda _:good)
    assert s.compatibility_proof()==good
    good['facts_after']={'ledger':'changed'}
    with pytest.raises(ValueError):s.compatibility_proof()

def test_actual_worker_runner_uses_cwd_runpy_without_pythonpath():
    code=(HERE/'server_release.py').read_text(encoding='utf-8')
    assert "--workdir','/opt/business-worker/app'" in code
    assert "runpy.run_path('/probe/worker_probe.py'" in code
    assert "'-e','PYTHONPATH=" not in code
    assert 'Worker must reject ambiguous cross-user receipts' in code

def test_public_health_rejects_html_and_checks_all_four_static_bytes(monkeypatch):
    m={'static':[{'dest':'src/a.js','after_sha256':r.sha_bytes(b'candidate'),'before_sha256':r.sha_bytes(b'old')} ]}
    paths={'/api/v1/admin/support-orders/payouts/{order_id}/takeover':{'post':{}},'/api/v1/admin/support-orders/payouts/{order_id}/select-discovered':{'post':{}},'/api/v1/recharge/admin/requests/{request_id}/takeover':{'post':{}}}
    def fetch(url,proxy,status=False):
        if status:return b'401'
        if url.endswith('/ready'):return b'{"ok":true,"database":"ready"}'
        if url.endswith('/openapi.json'):return json.dumps({'paths':paths}).encode()
        return b'candidate'
    monkeypatch.setattr(p,'curl',fetch)
    assert p.verify(m,None,'candidate')['strict_tls'] is True
    monkeypatch.setattr(p,'curl',lambda *args,**kwargs:b'<html>')
    with pytest.raises((ValueError,json.JSONDecodeError)):p.verify(m,None,'candidate')
