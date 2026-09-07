enum MessageAction {
  copy,
  addToEmoji,
  forward,
  deleteLocal,
  multiSelect,
  reply,
  reminder,
  recall,
}

enum MessageContentKind {
  text,
  image,
  video,
  gif,
  file,
  voice,
  call,
  redPacket,
  transfer,
  system
}

final class MessageCapabilities {
  const MessageCapabilities({
    required this.kind,
    required this.isOwn,
    required this.sentAt,
    required this.serverNow,
    this.isSent = true,
  });

  final MessageContentKind kind;
  final bool isOwn;
  final DateTime sentAt;
  final DateTime serverNow;
  final bool isSent;

  bool get canRecall {
    if (!isOwn) return false;
    final age = serverNow.difference(sentAt);
    return !age.isNegative && age <= const Duration(minutes: 2);
  }
}

abstract final class MessageActionPolicy {
  /// 不可转发类型：红包/转账（业务卡片，转发无意义）、系统通知、
  /// 语音（媒体隐私）与通话摘要（“通话已取消/通话时长”）。
  static bool isForwardable(MessageContentKind kind) => !{
        MessageContentKind.redPacket,
        MessageContentKind.transfer,
        MessageContentKind.system,
        MessageContentKind.voice,
        MessageContentKind.call,
      }.contains(kind);

  static Set<MessageAction> actionsFor(MessageCapabilities message) {
    // A local echo has no server event to quote, forward or redact yet.
    // Failed sends remain retryable through the bubble's dedicated action.
    if (!message.isSent) {
      return {if (message.kind == MessageContentKind.text) MessageAction.copy};
    }
    if ({
      MessageContentKind.redPacket,
      MessageContentKind.transfer,
      MessageContentKind.system,
      MessageContentKind.call,
    }.contains(message.kind)) {
      // 业务卡片/系统/通话摘要：仅本地删除与多选（通话摘要不可转发）。
      return {MessageAction.deleteLocal, MessageAction.multiSelect};
    }

    final result = <MessageAction>{};
    if (message.kind == MessageContentKind.text) {
      result.add(MessageAction.copy);
    }
    if ({MessageContentKind.image, MessageContentKind.gif}
        .contains(message.kind)) {
      result.add(MessageAction.addToEmoji);
    }
    if (isForwardable(message.kind)) result.add(MessageAction.forward);
    result.addAll(const {
      MessageAction.deleteLocal,
      MessageAction.multiSelect,
      MessageAction.reply,
      MessageAction.reminder,
    });
    if (message.canRecall) result.add(MessageAction.recall);
    return result;
  }

  /// 气泡菜单的展示顺序：“复制”固定第一位，其后为转发/收藏/引用/
  /// 提醒/撤回/多选/删除（Set 无序，展示前必须归一化）。
  static const displayOrder = <MessageAction>[
    MessageAction.copy,
    MessageAction.forward,
    MessageAction.addToEmoji,
    MessageAction.reply,
    MessageAction.reminder,
    MessageAction.recall,
    MessageAction.multiSelect,
    MessageAction.deleteLocal,
  ];

  static List<MessageAction> ordered(Iterable<MessageAction> actions) => [
        for (final action in displayOrder)
          if (actions.contains(action)) action
      ];
}

final class MessageSelectionController {
  final Set<String> _selectedIds = <String>{};
  bool _active = false;

  bool get active => _active;
  Set<String> get selectedIds => Set.unmodifiable(_selectedIds);

  void startWith(String eventId) {
    _active = true;
    _selectedIds
      ..clear()
      ..add(eventId);
  }

  void toggle(String eventId) {
    if (!_selectedIds.remove(eventId)) _selectedIds.add(eventId);
  }

  bool canForward(bool Function(String eventId) isForwardable) =>
      _selectedIds.isNotEmpty && _selectedIds.every(isForwardable);

  void exit() {
    _active = false;
    _selectedIds.clear();
  }
}
