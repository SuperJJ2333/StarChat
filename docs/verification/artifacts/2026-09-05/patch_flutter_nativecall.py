from pathlib import Path

p = Path('apps/mobile_flutter/lib/app_home.dart')
raw = p.read_text(encoding='utf-8')

# 1) native_call 通道：事件（incomingCall/callAccepted/callEnded）+ 控制（answer/reject/end）
anchor = "    _nativePushBridge = NativePushBridge("
inject = """    _nativeCallControl = const MethodChannel('native_call');
    _nativeCallControl?.setMethodCallHandler((call) async {
      // Native → Flutter 事件（Telecom/CallActivity 驱动）。
      switch (call.method) {
        case 'incomingCall':
        case 'callAccepted':
          // 来电/已接听：呈现通话页并走接听链路（含 8s 同步竞态窗口）。
          callUi.showIncomingCall(calls);
          if (calls.state.phase == CallPhase.ringing) {
            unawaited(calls.accept());
          } else {
            unawaited(_autoAcceptWhenRinging());
          }
          _dismissNativeCallLayer();
        case 'callEnded':
          if (calls.state.phase == CallPhase.connected ||
              calls.state.phase == CallPhase.connecting) {
            unawaited(calls.hangup());
          } else if (calls.state.phase == CallPhase.ringing) {
            unawaited(calls.reject());
          }
      }
      return true;
    });
    _nativePushBridge = NativePushBridge("""
assert anchor in raw
raw = raw.replace(anchor, inject, 1)

# 2) 字段
field = "  MethodChannel? _nativeCallChannel;"
raw = raw.replace(field, field + "\n  MethodChannel? _nativeCallControl;", 1)

# 3) resumed 恢复逻辑（§四）：回前台时若仍在响铃/通话 → 直接进通话页
resume_anchor = "  void didChangeAppLifecycleState(AppLifecycleState state) {"
resume_helper_anchor = "    if (state == AppLifecycleState.resumed) {"
if 'nativeCallResumeCheck' not in raw:
    old = """  void didChangeAppLifecycleState(AppLifecycleState state) {"""
    new = """  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 规格§四（后台恢复）：收到电话后回前台（点图标/切回）→ 立即
      // 进入通话页——不再"只响铃无页面"。
      final phase = calls.state.phase;
      if (phase == CallPhase.ringing ||
          phase == CallPhase.connecting ||
          phase == CallPhase.connected) {
        callUi.showIncomingCall(calls);
      }
    }"""
    assert old in raw
    raw = raw.replace(old, new, 1)
p.write_text(raw, encoding='utf-8', newline='')
print('app_home OK')
