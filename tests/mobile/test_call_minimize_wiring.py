from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_leaving_outgoing_call_does_not_hang_up():
    home = (ROOT / 'apps/mobile_flutter/lib/app_home.dart').read_text(encoding='utf-8')
    open_call = home.split('Future<void> _openCall(', 1)[1].split('Future<void> _openMessage(', 1)[0]
    cleanup = open_call.split('finally {', 1)[1]
    assert 'calls.hangup()' not in cleanup
    assert 'onMinimize:' in open_call


def test_starting_from_another_page_restores_existing_call():
    home = (ROOT / 'apps/mobile_flutter/lib/app_home.dart').read_text(encoding='utf-8')
    open_call = home.split('Future<void> _openCall(', 1)[1].split('Future<void> _openMessage(', 1)[0]
    assert open_call.count('callUi.restoreCall()') >= 2

def test_outgoing_identity_is_stored_before_restoration():
    home = (ROOT / 'apps/mobile_flutter/lib/app_home.dart').read_text(encoding='utf-8')
    start = home.split('await calls.start(', 1)[1].split(');', 1)[0]
    assert 'identity:' in start
    controller = (ROOT / 'apps/mobile_flutter/lib/features/matrix/call_controller.dart').read_text(encoding='utf-8')
    retry = controller.split('Future<void> retryAfterFailure()', 1)[1].split('void _acceptFailed', 1)[0]
    assert 'identity: state.identity' in retry


def test_native_overlay_uses_peer_avatar_and_stable_connection_time():
    base = ROOT / 'apps/mobile_flutter/android/app/src/main/kotlin/com/liuhetong/mobile/call'
    overlay = (base / 'CallOverlayService.kt').read_text(encoding='utf-8')
    assert 'setImageResource(applicationInfo.icon)' not in overlay
    assert 'CallManager.avatarBytes' in overlay
    assert 'CallManager.connectedAtMs' in overlay
    assert 'CallManager.video' in overlay


def test_native_avatar_cache_is_scoped_to_the_owning_coordinator():
    source = (ROOT / 'apps/mobile_flutter/lib/features/matrix/native_call_coordinator.dart').read_text(encoding='utf-8')
    assert "avatarCacheKey(identity)" in source
    assert "_instanceId" in source.split('String avatarCacheKey(', 1)[1].split(';', 1)[0]
