from pathlib import Path
import re
import tomllib

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name

ROOT = Path(__file__).resolve().parents[2]


def test_project_dependencies_have_matching_lock_versions():
    project = tomllib.loads((ROOT / 'services/business-api/pyproject.toml').read_text(encoding='utf-8'))
    locked = {}
    for line in (ROOT / 'services/business-api/requirements.lock').read_text(encoding='utf-8').splitlines():
        name, version = line.split('==')
        locked[canonicalize_name(name)] = version
    for raw in project['project']['dependencies']:
        dependency = Requirement(raw)
        version = locked.get(canonicalize_name(dependency.name))
        assert version is not None, f'{dependency.name} is missing from the Docker dependency lock'
        assert version in dependency.specifier, f'{dependency.name} lock does not satisfy {raw}'


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
