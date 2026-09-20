from pathlib import Path
import importlib.util
import pytest

ROOT = Path(__file__).resolve().parents[2]


def test_testflight_signing_uses_profile_contents_and_preserves_app_identity():
    workflow = (ROOT / '.github/workflows/ios-testflight.yml').read_text(encoding='utf-8')
    assert "PROFILE_BASE64: ${{ secrets.IOS_PROVISIONING_PROFILE_NAME }}" not in workflow
    assert "IOS_PROFILE_BASE64: ${{ secrets.IOS_PROFILE_BASE64 }}" in workflow
    assert "assert data['Entitlements']['application-identifier']" in workflow
    assert "flutter create" not in workflow
    assert 'LIUHETONG_IN_APP_UPDATE=false' in workflow
    assert 'build-unsigned-ipa:' not in workflow
    assert 'preflight-only:' in workflow
    assert 'scripts/testflight_status.mjs preflight' in workflow
    assert 'scripts/check_ios_permission_binary.py' in workflow


def test_permission_binary_gate_rejects_placeholder_classes_and_requires_each_capability():
    path = ROOT / 'scripts/check_ios_permission_binary.py'
    spec = importlib.util.spec_from_file_location('permission_binary', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    empty_classes = b'AudioVideoPermissionStrategy\0PhotoPermissionStrategy\0NotificationPermissionStrategy'
    with pytest.raises(ValueError):
        module.verify_permission_binary(empty_classes)
    complete = b'\0'.join(item.encode() for item in module.REQUIRED_METHODS)
    module.verify_permission_binary(complete)
    for missing in module.REQUIRED_METHODS:
        with pytest.raises(ValueError):
            module.verify_permission_binary(b'\0'.join(item.encode() for item in module.REQUIRED_METHODS if item != missing))


def test_simulator_validates_real_permission_plugin_without_importing_excluded_scanner():
    workflow = (ROOT / '.github/workflows/ios-testflight.yml').read_text(encoding='utf-8')
    simulator = workflow.split('  simulator-build:', 1)[1].split('  build-upload:', 1)[0]
    assert '-t integration_test/ios_permission_capabilities_test.dart' in simulator
    assert 'simctl privacy' in simulator
    assert 'flutter test integration_test/ios_permission_capabilities_test.dart' in simulator
