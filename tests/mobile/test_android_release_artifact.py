import importlib.util
from pathlib import Path
from zipfile import ZipFile

import pytest


def load_validator():
    path = Path(__file__).resolve().parents[2] / "scripts/verify_android_release.py"
    spec = importlib.util.spec_from_file_location("android_release_check", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.validate_apk


def make_apk(tmp_path, extras=()):
    path = tmp_path / "app.apk"
    with ZipFile(path, "w") as archive:
        for name in ("lib/arm64-v8a/libapp.so", "lib/arm64-v8a/libflutter.so", *extras):
            archive.writestr(name, b"test")
    return path


def test_arm64_release_accepts_only_complete_target(tmp_path):
    result = load_validator()(make_apk(tmp_path), "arm64-v8a")
    assert result["abis"] == ["arm64-v8a"]


@pytest.mark.parametrize("extra", ["lib/x86_64/libplugin.so", "lib/armeabi-v7a/libplugin.so"])
def test_rejects_plugin_libraries_for_unrequested_abi(tmp_path, extra):
    with pytest.raises(ValueError, match="ABI"):
        load_validator()(make_apk(tmp_path, [extra]), "arm64-v8a")


def test_rejects_debug_kernel(tmp_path):
    with pytest.raises(ValueError, match="debug"):
        load_validator()(make_apk(tmp_path, ["assets/flutter_assets/kernel_blob.bin"]), "arm64-v8a")


def test_requires_flutter_aot_library(tmp_path):
    path = tmp_path / "incomplete.apk"
    with ZipFile(path, "w") as archive:
        archive.writestr("lib/arm64-v8a/libplugin.so", b"plugin")
    with pytest.raises(ValueError, match="missing"):
        load_validator()(path, "arm64-v8a")
