from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def test_compatibility_compiles_complete_production_app_without_plugin_exclusion() -> None:
    workflow = (ROOT / '.github/workflows/ios-compatibility.yml').read_text(encoding='utf-8')
    production = workflow.split('  production-compile:', 1)[1].split('  simulator:', 1)[0]
    assert 'flutter build ios --release --no-codesign' in production
    assert 'mobile_scanner' not in production
    assert 'production-compile.log' in production


def test_signed_candidate_can_be_dispatched_on_main_without_publishing() -> None:
    workflow = (ROOT / '.github/workflows/ios-0353.yml').read_text(encoding='utf-8')
    assert 'workflow_dispatch:' in workflow
    assert "github.ref == 'refs/heads/main'" in workflow
    assert 'if: false # Upload the verified candidate after release review.' in workflow
    assert 'flutter build ipa --release' in workflow


def test_native_harness_covers_actual_encoder_and_scoped_key_retention() -> None:
    harness = (ROOT / 'apps/mobile_flutter/integration_test/ios_compatibility_test.dart').read_text(encoding='utf-8')
    assert 'VideoCompress.compressVideo(' in harness
    assert 'ChatVideoProfile.aggressive(' in harness
    assert 'await engine.setEarpiece(!earpiece)' in harness
    assert 'await engine.dispose()' in harness
    assert "'account_scopes.json'" in harness
    assert "await storage.read('$_databaseKey.$scope')" in harness


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
