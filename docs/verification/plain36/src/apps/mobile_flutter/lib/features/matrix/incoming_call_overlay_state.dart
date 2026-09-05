import 'call_controller.dart';

/// AppHome 来电覆盖层挂载状态机（BUG 修复：被叫接听后通话页消失）。
///
/// 语义分离：
/// - [ringing]：来电响铃中——控制全屏来电通知收起、铃声抑制等通知语义；
/// - [pageVisible]：来电接听页是否挂载——ringing→connecting→connected
///   全程保持 true，只有终态（ended/failed/permissionDenied）才卸载。
///
/// 旧实现把两个语义合在 `incomingCallActive` 一个布尔上：connected 时置
/// false，导致被叫一接通覆盖层 CallPage 立即卸载（通话还在进行，UI 没了）。
final class IncomingCallOverlayState {
  bool _ringing = false;
  bool _pageVisible = false;

  /// 来电响铃中（通知语义：全屏通知/铃声抑制）。
  bool get ringing => _ringing;

  /// 来电接听页挂载中（挂载语义：接通后仍为 true，终态才 false）。
  bool get pageVisible => _pageVisible;

  /// 每次通话状态变化调用。[outgoingCallPageVisible] 为主叫 CallPage
  /// 是否已在路由栈（此时 ringing 属于回铃，不得再挂来电覆盖层）。
  void update(CallPhase phase, {required bool outgoingCallPageVisible}) {
    switch (phase) {
      case CallPhase.ringing:
        if (!outgoingCallPageVisible) {
          _ringing = true;
          _pageVisible = true;
        }
      case CallPhase.connecting:
      case CallPhase.connected:
        // 接通：停止响铃语义，但页面保持挂载。
        _ringing = false;
      case CallPhase.ended:
      case CallPhase.failed:
      case CallPhase.permissionDenied:
      case CallPhase.idle:
      case CallPhase.requestingPermission:
        _ringing = false;
        _pageVisible = false;
    }
  }

  /// 登出/账号切换：清空（不留旧账号通话 UI）。
  void reset() {
    _ringing = false;
    _pageVisible = false;
  }
}
