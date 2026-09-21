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


def test_simulator_validates_real_permission_plugin_without_importing_excluded_scanner():
    workflow = (ROOT / '.github/workflows/ios-testflight.yml').read_text(encoding='utf-8')
    simulator = workflow.split('  simulator-build:', 1)[1].split('  build-upload:', 1)[0]
    assert '-t integration_test/ios_permission_capabilities_test.dart' in simulator
    assert 'simctl privacy' in simulator
    assert 'flutter drive --driver=integration_test/permission_driver.dart' in simulator
    assert '--use-existing-app="$vm_uri"' in simulator


def test_reused_checks_require_success_and_exact_repository_workflow():
    spec = importlib.util.spec_from_file_location('reuse', ROOT / 'scripts/reuse_flutter_checks.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    run = {'repository': {'full_name': 'SuperJJ2333/StarChat'}, 'path': '.github/workflows/ios-testflight.yml', 'head_sha': module.EVIDENCE_SHA, 'id': int(module.EVIDENCE_RUN)}
    jobs = {'jobs': [{'name': 'flutter-checks', 'conclusion': 'success', 'steps': [{'name': 'Flutter checks', 'conclusion': 'success'}]}]}
    assert module.verified_sha(run, jobs) == module.EVIDENCE_SHA
    for status in ['failure', 'cancelled', None]:
        with pytest.raises(ValueError):
            module.verified_sha(run, {'jobs': [{'name': 'flutter-checks', 'conclusion': status}]})
    with pytest.raises(ValueError):
        module.verified_sha({**run, 'repository': {'full_name': 'other/repo'}}, jobs)
    with pytest.raises(ValueError):
        module.verified_sha({**run, 'path': 'different.yml'}, jobs)

    with pytest.raises(ValueError):
        module.verified_sha({**run, 'id': 123}, jobs)
    with pytest.raises(ValueError):
        module.verified_sha({**run, 'head_sha': 'b' * 40}, jobs)
    with pytest.raises(ValueError):
        module.verified_sha(run, {'jobs': [{'name': 'flutter-checks', 'conclusion': 'success', 'steps': []}]})


def test_native_reuse_requires_completed_assertions_and_unchanged_job():
    spec = importlib.util.spec_from_file_location('native_reuse', ROOT / 'scripts/reuse_native_checks.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    run = {'id': module.EVIDENCE_RUN, 'head_sha': module.EVIDENCE_SHA,
           'repository': {'full_name': 'SuperJJ2333/StarChat'}, 'path': module.WORKFLOW}
    job = {'name': 'simulator-build', 'conclusion': 'success',
           'steps': [{'name': 'Exercise real native permission strategies', 'conclusion': 'success'}]}
    module.verify_native_evidence(run, {'jobs': [job]})
    for patch in [{'head_sha': 'a' * 40}, {'id': 1}, {'path': 'other.yml'}, {'repository': {}}]:
        with pytest.raises(ValueError):
            module.verify_native_evidence({**run, **patch}, {'jobs': [job]})
    for patch in [{'conclusion': 'failure'}, {'steps': []}]:
        with pytest.raises(ValueError):
            module.verify_native_evidence(run, {'jobs': [{**job, **patch}]})
    source = '  simulator-build:\n    runs-on: macos-15\n    steps:\n      - run: native-check\n  build-upload:\n'
    current = source.replace('    runs-on:', '    if: ${{ !inputs.reuse-native-run }}\n    runs-on:')
    assert module.native_job(source) == module.native_job(current)
    assert module.native_job(source) != module.native_job(current.replace('native-check', 'different-check'))
