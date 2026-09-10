from pathlib import Path
import json
import os
import subprocess
import yaml


def test_manual_wallet_overlay_shares_explicit_config_and_readonly_observer():
    path = Path(__file__).resolve().parents[2] / 'infra/compose/docker-compose.wallet-manual.yml'
    assert path.is_file(), 'manual wallet deployment wiring missing'
    services = yaml.safe_load(path.read_text(encoding='utf-8'))['services']
    api, worker = services['business-api'], services['business-worker']
    for service in (api, worker):
        env = service['environment']
        assert env['BUSINESS_WALLET_REAL_MODE'] == 'manual_tron'
        assert env['BUSINESS_WALLET_REAL_FUNDS_ENABLED'] == '${BUSINESS_WALLET_REAL_FUNDS_ENABLED:?explicit legacy gate required}'
        for key in ('WALLET_TOTP_ENCRYPTION_KEY','WALLET_OFFICIAL_ADDRESS','WALLET_FUNDING_BASELINE_AT',
                    'WALLET_FUNDING_BASELINE_HEIGHT','WALLET_MANUAL_OWNER_ADMIN_ID','WALLET_ALERT_RECIPIENT'):
            assert '${BUSINESS_' + key + ':?' in env['BUSINESS_' + key]
        assert env['BUSINESS_TRON_OBSERVER_DATABASE_PATH'] == '/data/tron-watch/observations.sqlite3'
    budget = 'BUSINESS_WALLET_MANUAL_STALE_RESAMPLE_BUDGET_SECONDS'
    assert budget not in api['environment']
    assert worker['environment'][budget] == '${' + budget + ':-60}'
    assert api['environment'] == {key: value for key, value in worker['environment'].items() if key != budget}
    for service in (api, worker):
        assert {mount['target'] for mount in service['volumes']} == {'/data/tron-watch', '/data/wallet-handover.json'}
        for mount in service['volumes']:
            assert mount['read_only'] is True and mount['bind']['create_host_path'] is False
    assert set(services) == {'business-api','business-worker'}


def test_manual_overlay_renders_after_release_and_preserves_both_readonly_mounts():
    root = Path(__file__).resolve().parents[2]
    env = {key: value for key, value in os.environ.items() if key.upper() in {
        'PATH','SYSTEMROOT','WINDIR','TEMP','TMP','HOME','USERPROFILE','APPDATA','LOCALAPPDATA',
        'PROGRAMDATA','PROGRAMFILES','PROGRAMFILES(X86)','DOCKER_CONFIG'}}
    raw = yaml.safe_load((root / 'infra/compose/docker-compose.wallet-manual.yml').read_text(encoding='utf-8'))
    for key, value in raw['services']['business-api']['environment'].items():
        if ':?' in value:
            env[key] = 'isolated-render-fixture'
    env.update(BUSINESS_API_RELEASE_IMAGE='starchat-business-api:2026.09.07-test',
        BUSINESS_WORKER_RELEASE_IMAGE='starchat-business-worker:2026.09.07-test',
        BUSINESS_WALLET_REAL_FUNDS_ENABLED='false',
        WALLET_HANDOVER_RECORD=str(root / 'docs/verification/artifacts/2026-09-10/main-integration/fixture-handover.json'),
        TRON_WATCH_DATA_DIR=str(root / 'docs/verification/artifacts/2026-09-10/main-integration/fixture-observer'))
    command = ['docker','compose','--env-file','.env.example']
    for filename in ('docker-compose.yml','docker-compose.production.yml','infra/compose/docker-compose.wallet-release.yml',
                     'infra/compose/docker-compose.wallet-chain.yml','infra/compose/docker-compose.wallet-manual.yml'):
        command.extend(['-f',filename])
    result = subprocess.run(command+['config','--format','json'], cwd=root, env=env,
        capture_output=True, text=True, encoding='utf-8', timeout=30)
    assert result.returncode == 0, result.stderr
    services = json.loads(result.stdout)['services']
    for name in ('business-api','business-worker'):
        service = services[name]
        assert service['environment']['BUSINESS_WALLET_REAL_FUNDS_ENABLED'] == 'false'
        for target in ('/data/tron-watch', '/data/wallet-handover.json'):
            mount, = [item for item in service['volumes'] if item['target'] == target]
            assert mount['read_only'] and not mount.get('bind', {}).get('create_host_path', False)
        assert service['image'].endswith(':2026.09.07-test')
