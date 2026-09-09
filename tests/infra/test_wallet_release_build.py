from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]


def test_release_images_install_same_exact_locked_dependencies():
    lock = ROOT / 'services/business-api/requirements.lock'
    lines = lock.read_text(encoding='utf-8').splitlines()
    assert lines and all(re.fullmatch(r'[A-Za-z0-9_.-]+==[A-Za-z0-9_.+-]+', line) for line in lines)
    assert any(line.startswith('setuptools==') for line in lines)
    for service in ['business-api', 'business-worker']:
        content = (ROOT / 'services' / service / 'Dockerfile').read_text(encoding='utf-8')
        assert 'requirements.lock' in content
        assert '--no-deps --no-build-isolation' in content
        assert 'release_preflight.py' in content
        assert 'python:3.12.11-slim@sha256:' in content


def test_docker_context_excludes_secret_and_verification_material():
    content = (ROOT / '.dockerignore').read_text(encoding='utf-8')
    for exclusion in ['.env', '.env.*', 'docs/', '.git/', '**/*.key', '**/*.pem']:
        assert exclusion in content.splitlines()
