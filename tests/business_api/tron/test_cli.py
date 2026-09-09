import json

import pytest

from app.integrations.tron.cli import load_config, write_status, healthy


def test_configuration_requires_explicit_address_and_start():
    with pytest.raises(ValueError):
        load_config({})
    with pytest.raises(ValueError):
        load_config({'TRON_WATCH_ADDRESS': 'not-an-address', 'TRON_WATCH_START_MS': '1'})


def test_status_is_atomic_redacted_and_health_requires_recent_success(tmp_path):
    path = tmp_path / 'status.json'
    write_status(path, {'status': 'OK', 'checkpoint_ms': 12, 'address': 'sensitive',
                        'error': 'secret URL', 'events_added': 2, 'balance_units': '123456'}, now_ms=1000)
    report = json.loads(path.read_text())
    assert report['financial_writes_enabled'] is False
    assert 'balance_units' not in report
    assert report['caught_up'] is False
    assert 'sensitive' not in path.read_text() and 'secret' not in path.read_text()
    assert healthy(path, now_ms=2000)
    assert not healthy(path, now_ms=200000)
    write_status(path, {'status': 'ERROR', 'error_code': 'READ_FAILED'}, now_ms=3000)
    assert not healthy(path, now_ms=3001)


def test_health_rejects_future_or_missing_status(tmp_path):
    path = tmp_path / 'status.json'
    assert not healthy(path, now_ms=1000)
    write_status(path, {'status': 'OK'}, now_ms=2000)
    assert not healthy(path, now_ms=1000)
