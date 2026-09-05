from pathlib import Path

p = Path('tests/getui_bridge/test_error_semantics.py')
raw = p.read_text(encoding='utf-8')
start = raw.find('def test_call_kind_uses_transmission_wakeup_native_calservice')
end = raw.find('def test_message_kind_uses_transmission_for_dispatcher')
assert start > 0 and end > start, 'anchors missing'

new_test = '''def test_call_kind_uses_transmission_wakeup_native_calservice():
    """规格（原生 CallService/分发层）：call/message 均走透传唤醒（仅
    type 类别，无业务内容）；push_channel.ups 仅作离线厂商兜底展示。"""
    from app.getui_client import build_push_body
    import json as _json

    call_body = build_push_body("cid-call", "call", 300_000)
    assert _json.loads(call_body["push_message"]["transmission"]) == {"type": "call"}
    assert "notification" not in call_body["push_message"]
    assert "ups" in call_body["push_channel"]["android"]

    msg_body = build_push_body("cid-msg", "message", 300_000)
    assert _json.loads(msg_body["push_message"]["transmission"]) == {"type": "message"}
    assert "notification" not in msg_body["push_message"]
    assert "ups" in msg_body["push_channel"]["android"]


'''
p.write_text(raw[:start] + new_test + raw[end:], encoding='utf-8', newline='')
print('test rewritten')
