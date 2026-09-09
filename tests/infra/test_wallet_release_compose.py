"""Render release configuration using only public example inputs; never read .env."""
import json
import os
from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]
OVERLAY = ROOT / "infra/compose/docker-compose.wallet-release.yml"
IMAGES = {
    "BUSINESS_API_RELEASE_IMAGE": "starchat-business-api:2026.09.06-test",
    "BUSINESS_WORKER_RELEASE_IMAGE": "starchat-business-worker:2026.09.06-test",
}


def render(*, release=True, omit=None, rollback=False):
    # An allowlist prevents the developer's exported secrets or COMPOSE_FILE
    # from overriding the explicitly selected public fixture.
    env = {key: value for key, value in os.environ.items()
           if key.upper() in {"PATH", "SYSTEMROOT", "WINDIR", "TEMP", "TMP", "HOME", "USERPROFILE",
                              "APPDATA", "LOCALAPPDATA", "PROGRAMDATA", "PROGRAMFILES",
                              "PROGRAMFILES(X86)", "DOCKER_CONFIG"}}
    env.update(IMAGES)
    env.update(BUSINESS_API_ROLLBACK_IMAGE='starchat-business-api:2026.09.06-previous',
               BUSINESS_WORKER_ROLLBACK_IMAGE='starchat-business-worker:2026.09.06-previous')
    if omit:
        env.pop(omit)
    command = ["docker", "compose", "--env-file", ".env.example",
               "-f", "docker-compose.yml", "-f", "docker-compose.production.yml"]
    if release:
        assert OVERLAY.exists(), "Missing bounded production wallet release overlay"
        command += ["-f", str(OVERLAY)]
    if rollback:
        rollback_path = ROOT / 'infra/compose/docker-compose.wallet-rollback.yml'
        assert rollback_path.exists(), 'Missing explicit rollback overlay'
        command += ['-f', str(rollback_path)]
    command += ["config", "--format", "json"]
    return subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                          text=True, encoding="utf-8", timeout=30, check=False)


def test_rollback_starts_old_code_without_migrating_or_removing_data():
    result = render(release=False, rollback=True)
    assert result.returncode == 0, result.stderr
    services = json.loads(result.stdout)['services']
    assert services['business-api']['command'][0] == 'uvicorn'
    assert 'alembic' not in str(services['business-api']['command'])
    assert services['business-worker']['command'] == ['python', 'main.py']
    for name in ['business-api', 'business-worker']:
        assert services[name]['image'].endswith(':2026.09.06-previous')
        assert not services[name].get('build')


@pytest.fixture(scope="module")
def configs():
    baseline = render(release=False)
    release = render()
    assert baseline.returncode == 0, baseline.stderr
    assert release.returncode == 0, release.stderr
    return json.loads(baseline.stdout), json.loads(release.stdout)


def test_release_changes_only_api_and_worker(configs):
    before, after = configs
    assert before.keys() == after.keys()
    assert before["services"].keys() == after["services"].keys()
    for name, service in before["services"].items():
        if name not in {"business-api", "business-worker"}:
            assert after["services"][name] == service
    for key in before.keys() - {"services"}:
        assert before[key] == after[key]


@pytest.mark.parametrize("name,variable", [
    ("business-api", "BUSINESS_API_RELEASE_IMAGE"),
    ("business-worker", "BUSINESS_WORKER_RELEASE_IMAGE"),
])
def test_release_uses_explicit_images_and_preserves_runtime_mounts(configs, name, variable):
    before, after = configs
    old = before["services"][name]
    new = after["services"][name]
    assert new["image"] == IMAGES[variable]
    assert not new.get("build")
    assert new.get("ports") == old.get("ports")
    assert new["volumes"] == old["volumes"]
    assert new["depends_on"] == old["depends_on"]
    assert new["environment"]["BUSINESS_ENVIRONMENT"] == "production"
    assert new["environment"]["BUSINESS_WALLET_CONVERSIONS_ENABLED"] == "false"
    for key, value in old["environment"].items():
        if key != "BUSINESS_ENVIRONMENT":
            assert new["environment"][key] == value


def test_worker_has_same_production_settings_secrets_as_api(configs):
    _, after = configs
    api = after["services"]["business-api"]["environment"]
    worker = after["services"]["business-worker"]["environment"]
    for suffix in ("JWT_SECRET", "TOTP_ISSUER", "EMAIL_VERIFICATION_SECRET",
                   "PASSWORD_RESET_SECRET", "SYNAPSE_ADMIN_ACCESS_TOKEN",
                   "MATRIX_PROVISION_SECRET", "AVATAR_URL_SIGNING_SECRET",
                   "REFERRAL_CODE_SECRET", "MATRIX_PUBLIC_HOMESERVER_URL",
                   "AVATAR_PUBLIC_BASE_URL"):
        assert worker["BUSINESS_" + suffix] == api["BUSINESS_" + suffix]


def test_preflight_precedes_server_and_worker_without_automatic_migrations(configs):
    _, after = configs
    api = after["services"]["business-api"]
    worker = after["services"]["business-worker"]
    for service in (api, worker):
        command = service["command"]
        assert command[:2] == ["sh", "-c"]
        assert command[2].startswith("python /opt/business-api/release_preflight.py && exec ")
        assert "alembic" not in command[2]
    assert "exec uvicorn app.main:create_default_app --factory --host 0.0.0.0 --port 8082" in api["command"][2]
    assert "exec python main.py" in worker["command"][2]
    assert "/api/v1/health/ready" in " ".join(api["healthcheck"]["test"])
    assert worker["depends_on"]["business-api"]["condition"] == "service_healthy"


@pytest.mark.parametrize("variable", IMAGES)
def test_missing_release_image_is_rejected(variable):
    result = render(omit=variable)
    assert result.returncode != 0
    assert variable in result.stderr
