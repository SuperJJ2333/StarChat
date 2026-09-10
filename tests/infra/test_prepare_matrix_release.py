"""Candidate preparation must retain the existing deployment's identity."""
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / 'scripts/prepare_matrix_release.py'


def put(root, name, content):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding='utf-8')


@pytest.fixture
def deployment(tmp_path):
    root, source, out = (tmp_path / name for name in ('live', 'source', 'candidate'))
    for name in ('infra/render_config.py', 'infra/synapse/homeserver.yaml.template',
                 'infra/synapse/worker-sync.yaml.template', 'infra/nginx/nginx.conf.template',
                 'docker-compose.yml'):
        put(source, name, (REPO / name).read_text(encoding='utf-8'))
    spec = importlib.util.spec_from_file_location('render_fixture', source / 'infra/render_config.py')
    renderer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(renderer)
    templates = ''.join(p.read_text(encoding='utf-8') for p in source.rglob('*.template'))
    values = {token[2:-2]: 'private-value' for token in renderer.TOKEN_RE.findall(templates)}
    values.update(MATRIX_SERVER_NAME='matrix.example.org', SYNAPSE_PUBLIC_BASEURL='https://matrix.example.org/',
                  POSTGRES_PORT='5432', TURN_URI_UDP='turn:turn.example.org:3478?transport=udp',
                  TURN_URI_TCP='turn:turn.example.org:3478?transport=tcp', TURN_URI_TLS='turns:turn.example.org:5349')
    put(root, '.env', '\n'.join(f'{k}={v}' for k, v in values.items()))
    main = yaml.safe_load(renderer.render((source / 'infra/synapse/homeserver.yaml.template').read_text(encoding='utf-8'), values))
    main['listeners'] = [item for item in main['listeners'] if item['port'] != 9093]
    main['database']['args']['cp_max'] = 10
    main.pop('redis')
    put(root, 'data/synapse/homeserver.yaml', yaml.safe_dump(main))
    nginx = 'upstream synapse_upstream {\n    server synapse:8008;\n}\nserver {\n    location /ios-call { return 200 "keep-ios"; }\n    location /_matrix/ {\n        proxy_pass http://synapse_upstream;\n    }\n}\n'
    put(root, 'data/nginx/nginx.conf', nginx)
    put(root, 'infra/nginx/nginx.conf.template', nginx)
    compose = {'name': 'existing-production', 'services': {
        'postgres': {'image': 'postgres:16', 'volumes': ['./real:/data']},
        'synapse': {'image': 'synapse:old', 'depends_on': {'postgres': {'condition': 'service_healthy'}},
                    'environment': {'EXISTING_SETTING': 'keep'}, 'volumes': ['./data/synapse:/data']},
        'business-api': {'image': 'business:42', 'environment': {'SECRET': 'preserved'}}},
        'networks': {'default': {'name': 'existing-net'}}}
    put(root, 'docker-compose.yml', yaml.safe_dump(compose))
    return root, source, out, compose, main, nginx


def run_candidate(deployment, image='starchat-synapse:release-20260910'):
    root, source, out, *_ = deployment
    return subprocess.run([sys.executable, str(SCRIPT), '--root', str(root), '--source', str(source),
                           '--output', str(out), '--image', image], capture_output=True, text=True)


def test_candidate_preserves_business_identity_credentials_and_ios(deployment):
    root, source, out, before, main, nginx = deployment
    result = run_candidate(deployment)
    assert result.returncode == 0, result.stderr
    assert 'private-value' not in result.stdout + result.stderr
    after = yaml.safe_load((out / 'docker-compose.yml').read_text(encoding='utf-8'))
    assert after['services']['business-api'] == before['services']['business-api']
    assert after['networks'] == before['networks']
    assert after['services']['synapse']['environment']['EXISTING_SETTING'] == 'keep'
    assert after['services']['synapse']['image'] == after['services']['synapse-sync-worker']['image']
    assert 'build' not in after['services']['synapse-sync-worker']
    candidate = yaml.safe_load((out / 'data/synapse/homeserver.yaml').read_text(encoding='utf-8'))
    assert candidate['server_name'] == main['server_name']
    assert candidate['database']['args']['password'] == main['database']['args']['password']
    for name in ('data/nginx/nginx.conf', 'infra/nginx/nginx.conf.template'):
        content = (out / name).read_text(encoding='utf-8')
        assert 'location /ios-call { return 200 "keep-ios"; }' in content
        assert content.count('upstream synapse_sync_upstream {') == 1
    assert (root / 'data/nginx/nginx.conf').read_text(encoding='utf-8') == nginx
    assert json.loads(result.stdout)['sha256'] == json.loads((out / 'manifest.json').read_text())['sha256']


@pytest.mark.parametrize('key,value', [('server_name', 'wrong.example.org'), ('enable_registration', True)])
def test_unexpected_main_drift_refused(deployment, key, value):
    root, _, out, _, main, _ = deployment
    main[key] = value
    put(root, 'data/synapse/homeserver.yaml', yaml.safe_dump(main))
    result = run_candidate(deployment)
    assert result.returncode != 0
    assert 'main configuration drift' in result.stderr
    assert not out.exists()


@pytest.mark.parametrize('image', ['synapse', 'synapse:latest', 'synapse:${TAG}', 'x:tag\nattack'])
def test_unpinned_images_refused(deployment, image):
    result = run_candidate(deployment, image)
    assert result.returncode != 0
    assert 'explicit release image' in result.stderr


def test_existing_mismatched_sync_route_refused(deployment):
    root, _, _, _, _, nginx = deployment
    put(root, 'data/nginx/nginx.conf', nginx.replace('location /_matrix/', 'location ~ ^/_matrix/client/(r0|v3)/(sync|events)$'))
    result = run_candidate(deployment)
    assert result.returncode != 0
    assert 'nginx' in result.stderr


def test_output_cannot_overlap_live_root(deployment):
    root, source, _, *rest = deployment
    result = run_candidate((root, source, root, *rest))
    assert result.returncode != 0
    assert 'output' in result.stderr


@pytest.mark.parametrize('change', ['password', 'listener'])
def test_credentials_and_existing_listeners_cannot_change(deployment, change):
    root, _, _, _, main, _ = deployment
    if change == 'password':
        main['database']['args']['password'] = 'a-different-production-secret'
    else:
        main['listeners'][0]['x_forwarded'] = False
    put(root, 'data/synapse/homeserver.yaml', yaml.safe_dump(main))
    result = run_candidate(deployment)
    assert result.returncode != 0
    assert 'main configuration drift' in result.stderr
    assert 'production-secret' not in result.stderr


def test_matching_existing_sync_blocks_are_idempotent(deployment):
    root, source, out, *rest = deployment
    assert run_candidate(deployment).returncode == 0
    for name in ('data/nginx/nginx.conf', 'infra/nginx/nginx.conf.template'):
        put(root, name, (out / name).read_text(encoding='utf-8'))
    next_out = out.with_name('second-candidate')
    result = run_candidate((root, source, next_out, *rest))
    assert result.returncode == 0, result.stderr
    assert (out / 'data/nginx/nginx.conf').read_bytes() == (next_out / 'data/nginx/nginx.conf').read_bytes()


def test_ambiguous_nginx_anchor_refused(deployment):
    root, _, _, _, _, nginx = deployment
    put(root, 'data/nginx/nginx.conf', nginx + '\nserver {\n    location /_matrix/ { proxy_pass http://synapse_upstream; }\n}\n')
    result = run_candidate(deployment)
    assert result.returncode != 0
    assert 'ambiguous' in result.stderr


def test_yaml_error_does_not_print_secret_lines(deployment):
    root, *_ = deployment
    put(root, 'data/synapse/homeserver.yaml', 'secret: [super-private-password\n')
    result = run_candidate(deployment)
    assert result.returncode != 0
    assert 'super-private-password' not in result.stdout + result.stderr


def test_source_symlink_escape_refused(deployment):
    root, source, out, *_ = deployment
    path = source / 'infra/synapse/homeserver.yaml.template'
    path.unlink()
    try:
        path.symlink_to(root / 'data/synapse/homeserver.yaml')
    except OSError:
        pytest.skip('symlink creation unavailable on this host')
    result = run_candidate(deployment)
    assert result.returncode != 0
    assert 'escapes' in result.stderr
    assert not out.exists()


def test_preparation_does_not_create_source_bytecode(deployment):
    _, source, *_ = deployment
    for path in source.rglob('*.pyc'):
        path.unlink()
    result = run_candidate(deployment)
    assert result.returncode == 0, result.stderr
    assert not list(source.rglob('*.pyc'))
