from pathlib import Path

p = Path('services/getui-bridge/app/getui_client.py')
raw = p.read_text(encoding='utf-8')
old = """    return {
        "request_id": f"cf{time.time_ns()}{secrets.token_hex(4)}"[:32],
        "settings": {"ttl": ttl_ms},
        "audience": {"cid": [cid]},
        # 在线个推通道
        "push_message": {"notification": notification},
        # 离线厂商通道（App 被杀时的送达路径）——同样只有通用文案。
        "push_channel": {
            "android": {"ups": {"notification": dict(notification)}},
        },
    }"""
new = """    body: dict[str, Any] = {
        "request_id": f"cf{time.time_ns()}{secrets.token_hex(4)}"[:32],
        "settings": {"ttl": ttl_ms},
        "audience": {"cid": [cid]},
    }
    if kind == "call":
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
assert old in raw, 'getui_client anchor missing'
raw = raw.replace(old, new, 1)
if '\nimport json' not in raw:
    raw = raw.replace('import hashlib', 'import hashlib\nimport json', 1)
p.write_text(raw, encoding='utf-8', newline='')
print('bridge OK')
