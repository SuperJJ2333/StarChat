"""Exercise the release bump entry point against isolated repository copies."""
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = ROOT / "docs/verification/artifacts/2026-09-27/android-public-update/version-tool"
PWSH = shutil.which("pwsh.exe") or shutil.which("pwsh")
pytestmark = pytest.mark.skipif(PWSH is None, reason="PowerShell 7 is required to exercise the release entry point")


def run_bump(config: str, version: str = "0.4.16+2185", *, bom: bool = False):
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="fixture-", dir=ARTIFACTS) as folder:
        root = Path(folder)
        mobile = root / "apps/mobile_flutter"
        (root / "scripts").mkdir()
        (root / "tests/mobile").mkdir(parents=True)
        (mobile / "lib/core").mkdir(parents=True)
        (mobile / "lib/features/update").mkdir(parents=True)
        shutil.copy2(ROOT / "scripts/bump_version.ps1", root / "scripts/bump_version.ps1")
        shutil.copy2(ROOT / "tests/mobile/test_app_build_contract.py", root / "tests/mobile/test_app_build_contract.py")
        (mobile / "lib/features/update/app_update_dialog.dart").write_text(
            "// 稍后再说 立即更新 canPop: !forced\n", encoding="utf-8"
        )
        pubspec_path = mobile / "pubspec.yaml"
        config_path = mobile / "lib/core/app_config.dart"
        encoding = "utf-8-sig" if bom else "utf-8"
        pubspec_path.write_bytes(b"version: 0.4.15+2184\r\n")
        config_path.write_bytes(config.replace("\n", "\r\n").encode(encoding))
        before = (pubspec_path.read_bytes(), config_path.read_bytes())
        result = subprocess.run(
            [PWSH, "-NoProfile", "-File", str(root / "scripts/bump_version.ps1"), "-Version", version],
            cwd=root, capture_output=True, text=True, encoding="utf-8", timeout=30,
        )
        return result, before, (pubspec_path.read_bytes(), config_path.read_bytes())


PINNED = """class AppConfig {
  static String appVersionName = '0.4.15';
  static const int compiledBuildNumber = 2184;
  static int appBuildNumber = compiledBuildNumber;
}
"""
LEGACY = """class AppConfig {
  static const String appVersionName = '0.4.15';
  static const int appBuildNumber = 2184;
}
"""


@pytest.mark.parametrize("bom", [False, True])
def test_bump_pinned_build_preserves_runtime_initializer_and_encoding(bom):
    result, before, after = run_bump(PINNED, bom=bom)
    assert result.returncode == 0, result.stdout + result.stderr
    assert b"version: 0.4.16+2185\r\n" in after[0]
    assert b"compiledBuildNumber = 2185;" in after[1]
    assert b"appBuildNumber = compiledBuildNumber;" in after[1]
    assert b"appVersionName = '0.4.16';" in after[1]
    assert not after[0].startswith(b"\xef\xbb\xbf")
    assert after[1].startswith(b"\xef\xbb\xbf") == bom
    assert after[1].count(b"\r\n") == before[1].count(b"\r\n")


def test_bump_legacy_numeric_build():
    result, _, after = run_bump(LEGACY)
    assert result.returncode == 0, result.stdout + result.stderr
    assert b"appBuildNumber = 2185;" in after[1]
    assert b"compiledBuildNumber" not in after[1]


def test_bump_changes_only_release_declarations():
    config = LEGACY.replace("static const int", "static int").replace(
        "}\n", "  static void restore() { appBuildNumber = 2184; }\n}\n"
    )
    result, _, after = run_bump(config)
    assert result.returncode == 0, result.stdout + result.stderr
    assert b"static int appBuildNumber = 2185;" in after[1]
    assert b"static void restore() { appBuildNumber = 2184; }" in after[1]


@pytest.mark.parametrize("config", [PINNED, LEGACY])
def test_same_version_is_byte_identical(config):
    result, before, after = run_bump(config, "0.4.15+2184")
    assert result.returncode == 0, result.stdout + result.stderr
    assert before == after


@pytest.mark.parametrize("config", [
    PINNED.replace("compiledBuildNumber = 2184", "compiledBuildNumber = 2184oops"),
    PINNED.replace("appBuildNumber = compiledBuildNumber", "appBuildNumber = compiledBuildNumber + 1"),
    PINNED.replace("  static const int compiledBuildNumber = 2184;", ""),
    PINNED.replace("  static const int compiledBuildNumber = 2184;", "  static const int compiledBuildNumber = 2184;\n  static const int compiledBuildNumber = 2184;"),
    PINNED.replace("  static int appBuildNumber = compiledBuildNumber;", "  static int appBuildNumber = compiledBuildNumber;\n  static int appBuildNumber = 2184;"),
    PINNED.replace("appBuildNumber = compiledBuildNumber", "appBuildNumber = 2184"),
    LEGACY.replace("appBuildNumber = 2184", "appBuildNumber = 2184oops"),
    LEGACY.replace("appVersionName = '0.4.15';", "appVersionName = '0.4.15' + suffix;"),
])
def test_ambiguous_or_malformed_identity_rejects_before_any_mutation(config):
    result, before, after = run_bump(config)
    assert result.returncode != 0
    assert after == before


def test_invalid_target_version_rejects_before_any_mutation():
    result, before, after = run_bump(PINNED, "0.4.16+2185oops")
    assert result.returncode != 0
    assert after == before
