import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/call_controller.dart';
import 'package:liuhetong_mobile/features/matrix/incoming_call_overlay_state.dart';

void main() {
  test('被叫接听后页面保持挂载（BUG：接通不再卸载通话页）', () {
    final overlay = IncomingCallOverlayState();
    overlay.update(CallPhase.ringing, outgoingCallPageVisible: false);
    expect(overlay.ringing, isTrue);
    expect(overlay.pageVisible, isTrue, reason: '响铃期来电页挂载');
    overlay.update(CallPhase.connected, outgoingCallPageVisible: false);
    expect(overlay.ringing, isFalse, reason: '接通后不再是响铃语义');
    expect(overlay.pageVisible, isTrue, reason: '接通后通话页必须保持挂载');
  });

  test('connecting 中间态不丢页面', () {
    final overlay = IncomingCallOverlayState();
    overlay.update(CallPhase.ringing, outgoingCallPageVisible: false);
    overlay.update(CallPhase.connecting, outgoingCallPageVisible: false);
    expect(overlay.pageVisible, isTrue);
    overlay.update(CallPhase.connected, outgoingCallPageVisible: false);
    expect(overlay.pageVisible, isTrue);
  });

  test('终态卸载：ended/failed/permissionDenied', () {
    for (final phase in [
      CallPhase.ended,
      CallPhase.failed,
      CallPhase.permissionDenied,
    ]) {
      final overlay = IncomingCallOverlayState();
      overlay.update(CallPhase.ringing, outgoingCallPageVisible: false);
      overlay.update(phase, outgoingCallPageVisible: false);
      expect(overlay.pageVisible, isFalse, reason: '$phase 必须卸载通话页');
      expect(overlay.ringing, isFalse);
    }
  });

  test('主叫通话页已打开时，ringing 不触发来电覆盖层', () {
    final overlay = IncomingCallOverlayState();
    overlay.update(CallPhase.ringing, outgoingCallPageVisible: true);
    expect(overlay.pageVisible, isFalse,
        reason: '主叫 CallPage 已在路由栈，覆盖层不得重复挂载');
    expect(overlay.ringing, isFalse);
  });

  test('idle 不挂载；reset 清空（登出防串会话）', () {
    final overlay = IncomingCallOverlayState();
    overlay.update(CallPhase.idle, outgoingCallPageVisible: false);
    expect(overlay.pageVisible, isFalse);
    overlay.update(CallPhase.ringing, outgoingCallPageVisible: false);
    overlay.reset();
    expect(overlay.pageVisible, isFalse);
    expect(overlay.ringing, isFalse);
  });
}
