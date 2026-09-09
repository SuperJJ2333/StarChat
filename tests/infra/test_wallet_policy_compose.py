"""The release overlay must propagate the same explicit policy to both services."""
from pathlib import Path
import json
import os
import subprocess

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
POLICY = {
    'BUSINESS_WALLET_REAL_FUNDS_ENABLED': 'false',
    'BUSINESS_WALLET_DEPOSITS_ENABLED': 'true',
    'BUSINESS_WALLET_PAYOUT_REQUESTS_ENABLED': 'true',
    'BUSINESS_WALLET_PAYOUT_EXECUTION_ENABLED': 'true',
    'BUSINESS_WALLET_CONVERSIONS_ENABLED': 'true',
    'BUSINESS_WALLET_USER_AUTH_MODE': 'address_only',
    'BUSINESS_WALLET_ADMIN_AUTH_MODE': 'operation_password',
    'BUSINESS_WALLET_RESERVE_POLICY': 'manual_liquidity',
    'BUSINESS_WALLET_HANDOVER_PREPARATION_MODE': 'false',
}


def render(missing=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith('BUSINESS_')}
    raw = yaml.safe_load((ROOT / 'docker-compose.wallet-manual.yml').read_text(encoding='utf-8'))
    for key, value in raw['services']['business-api']['environment'].items():
        if ':?' in value:
            env[key] = 'synthetic-render-only'
    env.update(POLICY)
    env.update(TRON_WATCH_DATA_DIR='/synthetic/tron',
               WALLET_HANDOVER_RECORD='/synthetic/handover.json')
    if missing:
        # Empty process value overrides .env.example; :? rejects unset or empty.
        env[missing] = ''
    return subprocess.run(['docker', 'compose', '--env-file', '.env.example',
        '-f', 'docker-compose.yml', '-f', 'docker-compose.production.yml',
        '-f', 'docker-compose.wallet-manual.yml', 'config', '--format', 'json'],
        cwd=ROOT, env=env, capture_output=True, text=True, encoding='utf-8', timeout=30)


def test_both_services_receive_independent_policy_and_protected_mounts():
    result = render()
    assert result.returncode == 0, result.stderr
    services = json.loads(result.stdout)['services']
    for name in ('business-api', 'business-worker'):
        service = services[name]
        assert {key: service['environment'].get(key) for key in POLICY} == POLICY
        for target in ('/data/tron-watch', '/data/wallet-handover.json'):
            mount, = [m for m in service['volumes'] if m['target'] == target]
            assert mount['read_only'] and not mount['bind']['create_host_path']


@pytest.mark.parametrize('missing', POLICY)
def test_missing_explicit_policy_fails_render(missing):
    result = render(missing)
    assert result.returncode != 0
    assert missing in result.stderr
