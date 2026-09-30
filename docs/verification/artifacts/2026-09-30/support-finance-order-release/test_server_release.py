from pathlib import Path
import sys,json
import pytest
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
import server_release as s
import public_verify as p
import release_prep as r

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
