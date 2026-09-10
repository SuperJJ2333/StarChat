"""Ingress contract for the single-device Matrix login authority."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]


def test_all_supported_login_aliases_reach_broker_before_general_matrix_proxy():
    config = (ROOT / 'infra/nginx/nginx.conf.template').read_text(encoding='utf-8')
    pattern = r'^/_matrix/client/(api/v1|r0|v3|unstable)/login/?$'
    assert f'location ~ {pattern}' in config
    for version in ['api/v1', 'r0', 'v3', 'unstable']:
        for suffix in ['', '/']:
            assert re.match(pattern, f'/_matrix/client/{version}/login{suffix}')
    assert config.index(f'location ~ {pattern}') < config.index('location /_matrix/ {')
    assert 'rewrite ^ /api/v1/auth/matrix-broker break;' in config
    assert 'location ^~ /_synapse/client/ { return 403; }' in config
    for path in ['login/get_token', 'register', 'refresh', 'sso/redirect', 'cas/ticket', 'saml2/authn_response', 'oidc/callback']:
        assert re.match(r'^/_matrix/client/[^/]+/(login|register|refresh|sso|cas|saml2|oidc)(/|$)', f'/_matrix/client/v3/{path}')
    assert 'location ~ ^/_matrix/client/[^/]+/(login|register|refresh|sso|cas|saml2|oidc)(/|$) { return 403; }' in config


def test_native_synapse_port_is_private_in_base_and_production():
    for name in ['docker-compose.yml', 'docker-compose.production.yml']:
        assert '127.0.0.1:${SYNAPSE_HTTP_PORT:-8008}:8008' in (ROOT / name).read_text(encoding='utf-8')
    compose = (ROOT / 'docker-compose.yml').read_text(encoding='utf-8')
    assert 'MATRIX_HOMESERVER_URL: ${SYNAPSE_INTERNAL_BASEURL:-http://synapse:8008/}' in compose
    template = (ROOT / 'infra/synapse/homeserver.yaml.template').read_text(encoding='utf-8')
    assert 'chatflow_mobile_login.MobileLoginModule' in template
    assert 'enable_registration: false' in template
