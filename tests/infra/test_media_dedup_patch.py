import ast
import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = ROOT / "third_party/synapse"


def test_patch_pins_all_modified_upstream_files_and_has_lifecycle_hooks():
    manifest = json.loads((BUNDLE / "upstream-manifest.json").read_text(encoding="utf-8"))
    assert manifest["version"] == "1.132.0"
    assert len(manifest["files"]) == 5
    patch = (BUNDLE / "patches/0001-cross-user-media-dedup.patch").read_text(encoding="utf-8")
    for file, hashes in manifest["files"].items():
        assert "--- a/" + file in patch
        assert hashes["before"] != hashes["after"]
        assert len(hashes["before"]) == len(hashes["after"]) == 64
    assert "user_id=user_id" in patch
    assert "_chatflow_remove_local_media_original" in patch
    assert "@media_lifecycle" in patch
    assert "ContentAddressedMedia(self).update" in patch
    ast.parse((BUNDLE / "chatflow_media_dedup.py").read_text(encoding="utf-8"))


def test_wrong_upstream_is_rejected_before_writing(tmp_path):
    spec = importlib.util.spec_from_file_location("patch_installer", BUNDLE / "apply_patch.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    manifest = json.loads((BUNDLE / "upstream-manifest.json").read_text(encoding="utf-8"))
    for file in manifest["files"]:
        dest = tmp_path / file
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text("different upstream\n", encoding="utf-8")
    with pytest.raises(ValueError, match="does not match"):
        module.apply(tmp_path)
    assert all((tmp_path / file).read_text(encoding="utf-8") == "different upstream\n"
               for file in manifest["files"])
