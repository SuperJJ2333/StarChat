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

def test_unsigned_handoff_runs_production_ios_notification_bridge():
    workflow = (ROOT / '.github/workflows/ios-enterprise-package.yml').read_text(encoding='utf-8')
    simulator = workflow.split('  simulator:',1)[1]
    assert 'integration_test/ios_conversation_notification_native_test.dart' in simulator


def test_unsigned_handoff_executes_real_outbox_reopen_on_ios():
    """The simulator must exercise durable previews, not only compile their code."""
    import ast

    workflow = (ROOT / '.github/workflows/ios-enterprise-package.yml').read_text(encoding='utf-8')
    simulator = workflow.split('  simulator:', 1)[1]
    target_list = re.search(r'targets = (\[.*?\])', simulator, re.S).group(1)
    targets = ast.literal_eval(target_list)
    assert 'integration_test/media_outbox_persistence_native_test.dart' in targets
    assert len(targets) == len(set(targets))
    for target in targets:
        assert (ROOT / 'apps/mobile_flutter' / target).is_file()
    assert 'for target in targets:' in simulator
    assert "'flutter', 'test', '--no-pub', target" in simulator
