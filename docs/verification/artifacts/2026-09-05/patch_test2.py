from pathlib import Path

# 1) bridge 白名单测试 → 新契约（透传 + ups 兜底）
p = Path('tests/getui_bridge/test_bridge.py')
raw = p.read_text(encoding='utf-8')
old = """        # 个推通道通知：仅通用文案 + startapp + 随机 notify_id。
        note = body["push_message"]["notification"]
        assert set(note.keys()) == {"title", "body", "click_type", "notify_id"}
        assert note["title"] == "畅聊"
        assert note["body"] == "您有一条新消息"
        assert note["click_type"] == "startapp"
        assert isinstance(note["notify_id"], int)"""
new = """        # 在线通道：透传唤醒指令（仅 type，无业务内容）。
        assert set(body["push_message"].keys()) == {"transmission"}
        import json as _json

        assert _json.loads(body["push_message"]["transmission"]) == {"type": "message"}
        # 离线厂商通道兜底：仅通用文案 + startapp + 随机 notify_id。
        note = body["push_channel"]["android"]["ups"]["notification"]
        assert set(note.keys()) == {"title", "body", "click_type", "notify_id"}
        assert note["title"] == "畅聊"
        assert note["body"] == "您有一条新消息"
        assert note["click_type"] == "startapp"
        assert isinstance(note["notify_id"], int)"""
assert old in raw, 'bridge whitelist anchor'
p.write_text(raw.replace(old, new), encoding='utf-8', newline='')
print('1 OK')

# 2) 合同测试：入口经 GetuiReceiver 分发
p = Path('tests/mobile/test_native_call_service_layer.py')
raw = p.read_text(encoding='utf-8')
old = """    assert "CallForegroundService.start" in entry
    assert '"call"' in entry"""
new = """    # 透传统一经 GetuiReceiver → PushEventDispatcher 分发
    assert "GetuiReceiver.onTransmit" in entry
    receiver = (KOTLIN.parent / "push/GetuiReceiver.kt").read_text(encoding="utf-8")
    assert "PushEventDispatcher.dispatch" in receiver"""
assert old in raw, 'contract anchor'
p.write_text(raw.replace(old, new), encoding='utf-8', newline='')
print('2 OK')
