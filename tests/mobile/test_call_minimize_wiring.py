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
