from pathlib import Path

p = Path('services/getui-bridge/app/getui_client.py')
raw = p.read_text(encoding='utf-8')
old = """    if kind == "call":
        # 来电：透传唤醒指令（原生 CallForegroundService → CallStyle 锁屏
        # 来电）。载荷仅 type/video，无任何业务内容（E2EE 红线；video 细分
        # 由实际信令定，通知一律语音样式）。
        body["push_message"] = {
            "transmission": json.dumps(
                {"type": "call", "video": False}, ensure_ascii=False
            )
        }
        return body
    # 消息：通知通道（通用文案）+ 离线厂商通道——同样只有通用文案。
    body["push_message"] = {"notification": notification}
    body["push_channel"] = {
        "android": {"ups": {"notification": dict(notification)}},
    }
    return body"""
new = """    # 透传唤醒指令（PushEventDispatcher 按 type 分发；载荷仅 type 类别，
    # 无任何业务内容——E2EE 红线：正文/发送者/房间永不出现在推送里）。
    # call → 原生 CallStyle 全屏来电；message → Flutter 通知协调器。
    body["push_message"] = {
        "transmission": json.dumps(
            {"type": kind if kind in ("call", "message") else "message"},
            ensure_ascii=False,
        )
    }
    # 离线厂商通道（进程被杀时的兜底展示）——同样只有通用文案。
    body["push_channel"] = {
        "android": {"ups": {"notification": dict(notification)}},
    }
    return body"""
assert old in raw, 'bridge anchor missing'
p.write_text(raw.replace(old, new, 1), encoding='utf-8', newline='')
print('bridge OK')
