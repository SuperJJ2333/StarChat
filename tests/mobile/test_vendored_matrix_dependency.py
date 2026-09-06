"""A clean checkout must contain the SDK used by Flutter's path dependency."""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps/mobile_flutter"
SDK = APP / "third_party/matrix"


def test_matrix_path_dependency_is_self_contained():
    assert "path: third_party/matrix" in (APP / "pubspec.yaml").read_text(
        encoding="utf-8"
    )
    required = (
        "pubspec.yaml",
        "LICENSE",
        "CHATFLOW_PATCH.md",
        "UPSTREAM_SHA256.json",
        "lib/matrix.dart",
        "lib/encryption.dart",
        "lib/src/voip/call_session.dart",
    )
    missing = [name for name in required if not (SDK / name).is_file()]
    assert not missing, f"Matrix path dependency missing from checkout: {missing}"


def test_vendored_matrix_snapshot_has_all_upstream_files():
    manifest = SDK / "UPSTREAM_SHA256.json"
    assert manifest.is_file(), "Matrix SDK source provenance must ship with checkout"
    original_files = json.loads(manifest.read_text(encoding="utf-8-sig"))
    assert original_files, "Upstream source manifest must not be empty"
    missing = [name for name in original_files if not (SDK / name).is_file()]
    assert not missing, f"Matrix SDK snapshot is incomplete: {missing}"
