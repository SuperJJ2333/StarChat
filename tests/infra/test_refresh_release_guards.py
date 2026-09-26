import importlib.util
from pathlib import Path
import sys
import json
import hashlib
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def test_all_images_checked_before_any_switch():
    guard = load('business_release_guard')
    calls = []
    def check(image):
        calls.append(('check', image))
        if image.endswith('b' * 64):
            raise ValueError('incompatible')
    with pytest.raises(ValueError):
        guard.check_then_apply(['sha256:'+'a'*64, 'sha256:'+'b'*64], check,
                               lambda: calls.append(('switch',)))
    assert not any(c[0] == 'switch' for c in calls)


@pytest.mark.parametrize('image', ['latest', 'app:release', '', 'sha256:abc'])
def test_mutable_or_invalid_image_rejected(image):
    with pytest.raises(ValueError):
        load('business_release_guard').validate_image(image)


def test_window_counts_only_exact_route_without_retaining_credentials():
    watch = load('refresh_watchdog')
    lines = ['2026-09-24T00:00:00Z INFO: 1 - "POST /api/v1/auth/refresh HTTP/1.1" 422 Unprocessable',
             'GET /api/v1/moments/media/content/secret 200',
             'POST /api/v1/auth/refresh?token=secret HTTP/1.1" 401 Unauthorized']
    counts = watch.count_refresh('\n'.join(lines))
    assert counts == {'total': 2, '2xx': 0, '401': 1, '422': 1, '5xx': 0, 'other': 0}
    assert 'secret' not in str(counts)


def test_thresholds_and_quiet_low_traffic():
    w = load('refresh_watchdog')
    assert w.reasons({'total': 0, '2xx': 0, '401': 0, '422': 0, '5xx': 0, 'other': 0}, True) == []
    assert w.reasons({'total': 3, '2xx': 0, '401': 0, '422': 3, '5xx': 0, 'other': 0}, True) == ['REFRESH_422']
    assert 'REFRESH_FAILURE_RATE' in w.reasons({'total': 10, '2xx': 8, '401': 2, '422': 0, '5xx': 0, 'other': 0}, True)
    assert 'PROTOCOL_PROBE_FAILED' in w.reasons({'total': 0}, False)


def test_dedup_recovery_and_failed_delivery_remains_pending():
    w = load('refresh_watchdog')
    state, event = w.transition({}, ['REFRESH_422'], 1000)
    assert event['kind'] == 'alert'
    # A failed send does not mark delivery successful; retry the same event.
    state2, retry = w.transition(state, ['REFRESH_422'], 1061)
    assert retry['id'] == event['id']
    state2 = w.delivered(state2, 1061)
    _, quiet = w.transition(state2, ['REFRESH_422'], 1100)
    assert quiet is None
    state3, recovered = w.transition(state2, [], 1120)
    assert recovered['kind'] == 'recovery'
    assert recovered['id'] != event['id']


def test_collector_failure_never_looks_healthy():
    w = load('refresh_watchdog')
    state, event = w.transition({}, ['MONITOR_CHECK_FAILED'], 1000)
    assert event['kind'] == 'alert'
    assert state['active'] == ['MONITOR_CHECK_FAILED']


def test_own_synthetic_probe_does_not_inflate_failure_rate():
    w = load('refresh_watchdog')
    assert w.count_refresh('"POST /api/v1/auth/refresh?starchat_probe=1 HTTP/1.1" 401 Unauthorized')['total'] == 0


def test_delivery_backoff_is_bounded_and_does_not_acknowledge():
    w = load('refresh_watchdog')
    state, event = w.transition({}, ['REFRESH_422'], 1000)
    for i in range(12):
        state = w.failed_delivery(state, 1000+i)
        assert 60 <= state['retry_at']-(1000+i) <= 300
        assert state['pending']['id'] == event['id']
        assert 'last_delivered' not in state
    assert w.transition(state, ['REFRESH_422'], 1013)[1] is None


def test_install_hook_blocks_internal_and_explicit_rollback():
    installer = load('install_refresh_watchdog')
    source = "def compose(role, version):\n    return str(ROOT / (version + '-' + role + '-private.json'))\n\ndef rollback():\n    mutate()\n\nif mode == 'prepare':\n    pass\nelif mode == 'deploy':\n    mutate()\nelif mode == 'rollback':\n    rollback()\n"
    patched = installer.protect_release(source)
    calls = []
    class Subprocess:
        def check_output(self, command, text):
            calls.append('gate')
            raise ValueError('old protocol')
    for mode in ('deploy','rollback'):
        with pytest.raises(ValueError):
            exec(patched, {'mode':mode,'subprocess':Subprocess(), 'ROOT':ROOT, 'json':__import__('json'),
                          'mutate':lambda: calls.append('mutated')})
    assert calls == ['gate', 'gate']
    assert installer.protect_release(patched) == patched
    namespace={'mode':'prepare','ROOT':ROOT}
    exec(patched,namespace)
    namespace['mode']='deploy'
    with pytest.raises(KeyError):
        namespace['compose']('api','candidate')


@pytest.mark.parametrize('state', [{'active':'bad'}, {'last_delivered':'bad'}, {'pending':{'id':'bad'}}, {'announced':'bad'}, {'sent_at':{'REFRESH_422':'bad'}}])
def test_malformed_monitor_state_is_rejected(state):
    with pytest.raises(ValueError):
        load('refresh_watchdog').validate_state(state)


def test_pending_alert_survives_recovery_and_additional_reason_is_not_duplicated():
    w = load('refresh_watchdog')
    state, alert = w.transition({}, ['REFRESH_422'], 1000)
    failed = w.failed_delivery(state, 1000)
    recovered_state, retry = w.transition(failed, [], 1060)
    assert retry['id'] == alert['id']
    acknowledged = w.delivered(recovered_state, 1060)
    _, recovery = w.transition(acknowledged, [], 1061)
    assert recovery['kind'] == 'recovery'
    state, _ = w.transition({}, ['REFRESH_422'], 1000)
    state = w.delivered(state, 1000)
    _, new = w.transition(state, ['REFRESH_422','REFRESH_5XX'], 1001)
    assert new['reasons'] == ['REFRESH_5XX']


def test_compose_image_mismatch_rejected_before_freeze(tmp_path, monkeypatch):
    guard = load('business_release_guard')
    image = 'sha256:'+'a'*64
    (tmp_path/'images.json').write_text(json.dumps({'api':image,'worker':image}))
    monkeypatch.setattr(guard.subprocess,'run',lambda *a,**k: SimpleNamespace(stdout=json.dumps(
        {'services':{'business-api':{'image':'sha256:'+'b'*64}}})))
    monkeypatch.setattr(guard,'verify_image',lambda _: pytest.fail('No image test after mismatch'))
    with pytest.raises(ValueError,match='mismatch'):
        guard.freeze_release(tmp_path,'candidate')
    assert not list(tmp_path.glob('guarded-*'))


def test_freeze_keeps_the_checked_config_when_original_changes(tmp_path, monkeypatch):
    guard = load('business_release_guard')
    image='sha256:'+'a'*64
    (tmp_path/'rollback-images.json').write_text(json.dumps({'api':image,'worker':image}))
    config={'services':{'business-api':{'image':image,'environment':{'TEST_VALUE':'original'}}}}
    def render(args,**kwargs):
        role='worker' if 'worker' in args[5] else 'api'
        return SimpleNamespace(stdout=json.dumps({'services':{'business-'+role:config['services']['business-api']}}))
    monkeypatch.setattr(guard.subprocess,'run',render)
    def check(_):
        config['services']['business-api']['image']='sha256:'+'b'*64
        return {'passed':True}
    monkeypatch.setattr(guard,'verify_image',check)
    result=guard.freeze_release(tmp_path,'rollback')
    frozen=json.loads(Path(result['configs']['api']).read_text())
    assert frozen['services']['business-api']['image']==image


def test_install_restore_is_repeatable_and_rejects_later_drift(tmp_path, monkeypatch):
    installer=load('install_refresh_watchdog')
    target=tmp_path/'target.py'
    target.write_bytes(b'new')
    backup=tmp_path/'backup'
    backup.mkdir()
    (backup/'0').write_bytes(b'old')
    sha=lambda b:hashlib.sha256(b).hexdigest()
    manifest={'files':{str(target):{'existed':True,'backup':'0','old_sha256':sha(b'old'),
        'new_sha256':sha(b'new'),'old_mode':0o600}},'timer':{'is-enabled':'enabled','is-active':'active'}}
    (backup/'manifest.json').write_text(json.dumps(manifest))
    calls=[]
    monkeypatch.setattr(installer.subprocess,'run',lambda args,**kwargs: calls.append(args))
    installer.restore(backup)
    installer.restore(backup)
    assert target.read_bytes()==b'old'
    assert ['systemctl','enable','starchat-refresh-watch.timer'] in calls
    target.write_bytes(b'later-work')
    calls.clear()
    with pytest.raises(ValueError,match='drift'):
        installer.restore(backup)
    assert not calls


def test_frozen_compose_escapes_literal_dollars():
    guard=load('business_release_guard')
    config={'environment':{'VALUE':'literal$NAME${OTHER}$$'},'command':['echo','$VALUE']}
    escaped=guard.escape_interpolation(config)
    assert escaped['environment']['VALUE']=='literal$$NAME$${OTHER}$$$$'
    assert escaped['command']==['echo','$$VALUE']
    assert config['command']==['echo','$VALUE']


@pytest.mark.parametrize('roles',[{}, {'api':'sha256:'+'a'*64}, {'worker':'sha256:'+'a'*64}])
def test_release_requires_both_roles_before_docker(tmp_path, monkeypatch, roles):
    guard=load('business_release_guard')
    (tmp_path/'rollback-images.json').write_text(json.dumps(roles))
    monkeypatch.setattr(guard.subprocess,'run',lambda *a,**k: pytest.fail('No Docker with incomplete roles'))
    with pytest.raises(ValueError,match='roles'):
        guard.freeze_release(tmp_path,'rollback')
