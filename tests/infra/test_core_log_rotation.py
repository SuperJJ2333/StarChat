"""Core service logs must have an explicit disk bound after container recreation."""
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]


class ComposeLoader(yaml.SafeLoader):
    pass


ComposeLoader.add_constructor('!override', lambda loader, node: loader.construct_sequence(node))


@pytest.mark.parametrize(('file', 'service'), [
    ('docker-compose.yml', 'synapse'),
    ('docker-compose.yml', 'synapse-sync-worker'),
    ('docker-compose.production.yml', 'gateway'),
])
def test_core_logs_have_explicit_rotation(file, service):
    config = yaml.load((ROOT / file).read_text(encoding='utf-8'), Loader=ComposeLoader)
    logging = config['services'][service].get('logging', {})
    assert logging.get('driver') == 'json-file'
    assert logging['options']['max-size'] == '20m'
    assert logging['options']['max-file'] == '10'
