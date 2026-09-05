from pathlib import Path

# ── 服务端：kind=call → 透传 {"type":"call","video":bool} ────────────
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
        # 来电：透传唤醒指令（原生 CallForegroundService → CallStyle 通知，
        # 微信级锁屏来电）。载荷只有 type/video，无任何业务内容（E2EE 红线；
        # video 细分不在此处——Synapse 通知不携带，实际媒体类型由信令定）。
        body["push_message"] = {
            "transmission": json.dumps(
                {"type": "call", "video": False}, ensure_ascii=False
            ),
        }
        return body
    # 消息：通知通道（通用文案）+ 离线厂商通道——同样只有通用文案。
    body["push_message"] = {"notification": notification}
    body["push_channel"] = {
        "android": {"ups": {"notification": dict(notification)}},
    }
    return body""""""
assert old in raw, 'getui_client anchor missing'
raw = raw.replace(old, new, 1)
if 'import json' not in raw:
    raw = raw.replace('import hashlib', 'import hashlib\nimport json', 1)
p.write_text(raw, encoding='utf-8', newline='')
print('bridge OK')

# ── Flutter：app_home 挂 chatflow/call 处理器 ───────────────────────
p = Path('apps/mobile_flutter/lib/app_home.dart')
raw = p.read_text(encoding='utf-8')
anchor = "    callUi.attach("
inject = """    _nativeCallChannel = const MethodChannel('chatflow/call');
    _nativeCallChannel?.setMethodCallHandler((call) async {
      // 原生 CallStyle 通知动作：接听=开页+accept；拒绝=reject。
      // 两动作后统一通知原生停服务（Flutter 侧接管后续 UI/媒体）。
      final action = call.method;
      if (action == 'openIncomingCall') {
        callUi.showIncomingCall(calls);
        if (calls.state.phase == CallPhase.ringing) {
          unawaited(calls.accept());
        } else {
          // 推送先于同步到达：等待响铃事件后自动接听（最多 8s）。
          unawaited(_autoAcceptWhenRinging());
        }
        _dismissNativeCallLayer();
      } else if (action == 'rejectIncomingCall') {
        if (calls.state.phase == CallPhase.ringing) {
          unawaited(calls.reject());
        }
        _dismissNativeCallLayer();
      }
      return true;
    });
    callUi.attach("""
assert anchor in raw
raw = raw.replace(anchor, inject, 1)

# 帮手方法 + 字段（插到 dispose 之前的类成员区：用 _handleCallState 前缀锚）
anchor2 = "  /// 规格§三：来电委托管理器呈现"
helpers = """  MethodChannel? _nativeCallChannel;

  Future<void> _autoAcceptWhenRinging() async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    void Function() listener;
    listener = () {
      if (calls.state.phase == CallPhase.ringing) {
        calls.removeListener(listener);
        unawaited(calls.accept());
      }
    };
    calls.addListener(listener);
    while (DateTime.now().isBefore(deadline) &&
        calls.state.phase != CallPhase.ringing &&
        calls.state.phase != CallPhase.ended) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (calls.state.phase == CallPhase.ringing) {
      calls.removeListener(listener);
      await calls.accept();
    } else {
      calls.removeListener(listener);
    }
  }

  void _dismissNativeCallLayer() {
    _nativeCallChannel?.invokeMethod('dismiss');
  }

  /// 规格§三：来电委托管理器呈现"""
assert anchor2 in raw
raw = raw.replace(anchor2, helpers, 1)
p.write_text(raw, encoding='utf-8', newline='')
print('app_home OK')
