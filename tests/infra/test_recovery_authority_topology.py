"""Recovery auth must use the actual internal business listener, not its host port."""
import ast
from pathlib import Path
from urllib.parse import urlsplit

import yaml


ROOT = Path(__file__).resolve().parents[2]


def test_authority_port_matches_business_service():
    tree = ast.parse((ROOT / 'third_party/synapse/chatflow_recovery_vault.py').read_text(encoding='utf-8'))
    target = next(ast.literal_eval(node.value) for node in tree.body
                  if isinstance(node, ast.Assign)
                  and any(isinstance(name, ast.Name) and name.id == 'AUTHORITY' for name in node.targets))
    url = urlsplit(target)
    service = yaml.safe_load((ROOT / 'docker-compose.yml').read_text(encoding='utf-8'))['services']['business-api']
    # Host port is operator-configurable; container port and health listener are not.
    internal_port = int(service['ports'][0].rsplit(':', 1)[1])
    assert url.scheme == 'http'
    assert url.hostname == 'business-api'
    assert url.path == '/api/v1/auth/matrix-recovery-authorize'
    assert not url.query and not url.fragment and not url.username and not url.password
    assert url.port == internal_port
    assert f'127.0.0.1:{url.port}/api/v1/health/live' in service['healthcheck']['test'][-1]
