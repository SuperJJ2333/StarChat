"""Ensure the signing pipeline builds the current source version, not an old IPA."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def test_unsigned_pipeline_uses_current_source_version_at_every_handoff_boundary():
    version, build = re.search(r"^version: ([0-9.]+)\+([0-9]+)$",
        (ROOT / "apps/mobile_flutter/pubspec.yaml").read_text(encoding="utf8"), re.M).groups()
    workflow = (ROOT / ".github/workflows/ios-enterprise-package.yml").read_text(encoding="utf8")
    assert f"--build-name={version} --build-number={build}" in workflow
    assert f"--version {version} --build {build}" in workflow
    assert workflow.count(f"ChatFlow-{version}-build{build}-unsigned") == 4
    assert "--no-codesign" in workflow
    assert "altool --upload-app" not in workflow
