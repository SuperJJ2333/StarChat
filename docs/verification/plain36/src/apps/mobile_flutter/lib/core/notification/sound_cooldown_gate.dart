/// 声音冷却门（PRD §41/§42 消息风暴保护）。
///
/// 同一会话 2 秒冷却窗口：第 1 条响，后续不响；不同会话受全局冷却
/// （默认 600ms）约束，防止连续噪音。UI 与未读数不受影响。
final class SoundCooldownGate {
  SoundCooldownGate({
    this.perConversationWindow = const Duration(seconds: 2),
    this.globalWindow = const Duration(milliseconds: 600),
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  final Duration perConversationWindow;
  final Duration globalWindow;
  final DateTime Function() now;

  final Map<String, DateTime> _lastByConversation = {};
  DateTime? _lastGlobal;

  /// 是否允许本次播放；允许时记录时间戳。
  bool shouldPlaySound(String conversationId) {
    final at = now();
    final lastGlobal = _lastGlobal;
    if (lastGlobal != null && at.difference(lastGlobal) < globalWindow) {
      return false;
    }
    final lastForConversation = _lastByConversation[conversationId];
    if (lastForConversation != null &&
        at.difference(lastForConversation) < perConversationWindow) {
      return false;
    }
    _lastGlobal = at;
    _lastByConversation[conversationId] = at;
    return true;
  }

  /// 通话等即时场景需要绕过冷却时手动重置。
  void reset() {
    _lastGlobal = null;
    _lastByConversation.clear();
  }
}
