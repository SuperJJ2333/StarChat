"""The client's compiled-in release identity must match pubspec.yaml."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_app_config_build_matches_pubspec_version():
    pubspec = (ROOT / "apps" / "mobile_flutter" / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$", pubspec, re.MULTILINE)
    assert match, "pubspec.yaml must declare version: X.Y.Z+build"

    config = (ROOT / "apps" / "mobile_flutter" / "lib" / "core" / "app_config.dart").read_text(encoding="utf-8")
    name = re.search(r"appVersionName\s*=\s*'([^']+)'", config)
    build = re.search(r"appBuildNumber\s*=\s*(\d+)", config)
    assert name and build, "app_config.dart must pin appVersionName/appBuildNumber"

    expected_name = f"{match.group(1)}.{match.group(2)}.{match.group(3)}"
    assert name.group(1) == expected_name, f"appVersionName should be {expected_name}"
    assert build.group(1) == match.group(4), f"appBuildNumber should be {match.group(4)}"


def test_update_dialog_covers_both_update_scenarios():
    dialog = (ROOT / "apps" / "mobile_flutter" / "lib" / "features" / "update" / "app_update_dialog.dart").read_text(encoding="utf-8")
    assert "稍后再说" in dialog, "dismissible updates need a defer action"
    assert "立即更新" in dialog, "forced updates need an explicit update action"
    assert "canPop: !forced" in dialog, "forced updates must block route pops"
