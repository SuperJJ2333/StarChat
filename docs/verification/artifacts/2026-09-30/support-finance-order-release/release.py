"""Audited r3 primitives with strict Task14 schema/scope validation."""
from release_r3 import *
from release_r3 import _atomic_replace, _image
from release_prep import BASE_SCHEMA,TARGET_SCHEMA,API_SOURCES,STATIC_SOURCES,RELEASE_ID
from release_prep import validate_manifest as _validate, assert_inventory_delta
from pathlib import Path
PACKAGE=Path(__file__).resolve().parent
MANIFEST=PACKAGE/'manifest.json'
NEW_STATIC=None

def validate_manifest(data):
    _validate(data)
    for field in ('wallet_probe_sha256','rollback_fence_sha256','worker_probe_sha256','worker_expected_sources_sha256','worker_baseline_expected_sources_sha256'):
        if not isinstance(data.get(field),str) or not HEX.fullmatch(data[field]):raise ValueError('release probe/fence hashes required')
    return data

def assert_exact_inventory_delta(before,after,expected):
    assert_inventory_delta(before,after,expected)

IMAGE_ROOTS['worker'] += ['/opt/business-api/app','/opt/business-api/migrations']
