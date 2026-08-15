from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def test_ios_workflow_builds_unsigned_simulator_app() -> None:
    workflow = (ROOT / ".github" / "workflows" / "ios-testflight.yml").read_text(encoding="utf-8")

    assert "simulator-build:" in workflow
    assert "flutter build ios --simulator --no-codesign" in workflow


def test_testflight_job_generates_signing_configuration_from_secrets() -> None:
    workflow = (ROOT / ".github" / "workflows" / "ios-testflight.yml").read_text(encoding="utf-8")

    assert "IOS_BUNDLE_ID" in workflow
    assert "APPLE_TEAM_ID" in workflow
    assert "Generate export options" in workflow
    assert "DEVELOPMENT_TEAM=$APPLE_TEAM_ID" in workflow
    assert "PRODUCT_BUNDLE_IDENTIFIER=$IOS_BUNDLE_ID" in workflow
