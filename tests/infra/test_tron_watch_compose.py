from pathlib import Path

import yaml


def test_watch_module_does_not_require_access_to_business_source_tree():
    root = Path(__file__).resolve().parents[2]
    service = yaml.safe_load((root / 'infra/compose/docker-compose.tron-watch.yml').read_text(encoding='utf-8'))['services']['tron-watch']
    assert service['user'] == '10001:10001'
    assert service['command'] == ['python', '-m', 'tron.cli']
    assert service['environment']['PYTHONPATH'] == '/opt'
    assert any(value.endswith(':/opt/tron:ro') for value in service['volumes'])
    assert not any('business-api' in value for value in service['volumes'])
    assert not any(key.startswith('BUSINESS_') for key in service['environment'])
    assert 'ports' not in service
