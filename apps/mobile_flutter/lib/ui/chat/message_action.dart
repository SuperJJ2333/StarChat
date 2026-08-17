enum MessageAction {
  addToEmoji,
  forward,
  deleteLocal,
  multiSelect,
  reply,
  reminder,
  recall,
}

enum MessageContentKind { text, image, gif, file, voice, redPacket, system }

final class MessageCapabilities {
  const MessageCapabilities({
    required this.kind,
    required this.isOwn,
    required this.sentAt,
    required this.serverNow,
  });

  final MessageContentKind kind;
  final bool isOwn;
  final DateTime sentAt;
  final DateTime serverNow;

  bool get canRecall {
    if (!isOwn) return false;
    final age = serverNow.difference(sentAt);
    return !age.isNegative && age <= const Duration(minutes: 2);
  }
}

abstract final class MessageActionPolicy {
  static bool isForwardable(MessageContentKind kind) =>
      !{MessageContentKind.redPacket, MessageContentKind.system}.contains(kind);

  static Set<MessageAction> actionsFor(MessageCapabilities message) {
    if ({MessageContentKind.redPacket, MessageContentKind.system}
        .contains(message.kind)) {
      return {MessageAction.deleteLocal, MessageAction.multiSelect};
    }

    final result = <MessageAction>{};
    if ({MessageContentKind.image, MessageContentKind.gif}
        .contains(message.kind)) {
      result.add(MessageAction.addToEmoji);
    }
    result.addAll(const {
      MessageAction.forward,
      MessageAction.deleteLocal,
      MessageAction.multiSelect,
      MessageAction.reply,
      MessageAction.reminder,
    });
    if (message.canRecall) result.add(MessageAction.recall);
    return result;
  }
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
