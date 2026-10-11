"""The app's own storage APIs must ship their required-reason declarations."""

import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / "apps/mobile_flutter/ios"


def test_app_storage_reasons_are_declared_and_added_to_runner_resources():
    manifest = IOS / "Runner/PrivacyInfo.xcprivacy"
    assert manifest.is_file(), "Runner storage APIs require an app privacy manifest"
    values = plistlib.loads(manifest.read_bytes())
    reasons = {
        row["NSPrivacyAccessedAPIType"]: row["NSPrivacyAccessedAPITypeReasons"]
        for row in values["NSPrivacyAccessedAPITypes"]
    }
    assert "E174.1" in reasons["NSPrivacyAccessedAPICategoryDiskSpace"]
    assert "C617.1" in reasons["NSPrivacyAccessedAPICategoryFileTimestamp"]
    assert "CA92.1" in reasons["NSPrivacyAccessedAPICategoryUserDefaults"]
    project = (IOS / "Runner.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    resources = project.split("97C146EC1CF9000F007C117D /* Resources */ = {", 1)[1]
    resources = resources.split("runOnlyForDeploymentPostprocessing", 1)[0]
    assert "PrivacyInfo.xcprivacy in Resources" in resources
