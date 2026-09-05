import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/message_action.dart';

void main() {
  final now = DateTime.utc(2026, 8, 17, 12);

  test('text message never exposes add-to-emoji', () {
    final actions = MessageActionPolicy.actionsFor(
      MessageCapabilities(
        kind: MessageContentKind.text,
        isOwn: false,
        sentAt: now.subtract(const Duration(minutes: 1)),
        serverNow: now,
      ),
    );

    expect(actions, contains(MessageAction.forward));
    expect(actions, contains(MessageAction.deleteLocal));
    expect(actions, contains(MessageAction.copy), reason: '文本消息提供复制');
    expect(actions, isNot(contains(MessageAction.addToEmoji)));
    expect(actions, isNot(contains(MessageAction.recall)));
  });

  test('copy is ordered FIRST in the bubble menu display order', () {
    // 需求：复制固定第一位，转发/撤回等依次排列。
    final ordered = MessageActionPolicy.ordered([
      MessageAction.deleteLocal,
      MessageAction.recall,
      MessageAction.copy,
      MessageAction.forward,
    ]);
    expect(ordered.first, MessageAction.copy);
    expect(ordered, [
      MessageAction.copy,
      MessageAction.forward,
      MessageAction.recall,
      MessageAction.deleteLocal,
    ]);
  });

  test('only image and GIF messages expose add-to-emoji', () {
    for (final kind in [MessageContentKind.image, MessageContentKind.gif]) {
      final actions = MessageActionPolicy.actionsFor(
        MessageCapabilities(
          kind: kind,
          isOwn: false,
          sentAt: now,
          serverNow: now,
        ),
      );
      expect(actions, contains(MessageAction.addToEmoji));
    }
    for (final kind in [
      MessageContentKind.text,
      MessageContentKind.file,
      MessageContentKind.voice,
      MessageContentKind.redPacket,
      MessageContentKind.transfer,
      MessageContentKind.system,
    ]) {
      final actions = MessageActionPolicy.actionsFor(
        MessageCapabilities(
          kind: kind,
          isOwn: false,
          sentAt: now,
          serverNow: now,
        ),
      );
      expect(actions, isNot(contains(MessageAction.addToEmoji)));
    }
  });

  test('recall uses the authoritative two-minute server-time boundary', () {
    Set<MessageAction> actions(Duration age) => MessageActionPolicy.actionsFor(
          MessageCapabilities(
            kind: MessageContentKind.text,
            isOwn: true,
            sentAt: now.subtract(age),
            serverNow: now,
          ),
        );

    expect(actions(const Duration(minutes: 2)), contains(MessageAction.recall));
    expect(
      actions(const Duration(minutes: 2, milliseconds: 1)),
      isNot(contains(MessageAction.recall)),
    );
  });

  test('financial and system events expose only safe local operations', () {
    for (final kind in [
      MessageContentKind.redPacket,
      MessageContentKind.transfer,
      MessageContentKind.system,
    ]) {
      expect(
        MessageActionPolicy.actionsFor(
          MessageCapabilities(
            kind: kind,
            isOwn: true,
            sentAt: now,
            serverNow: now,
          ),
        ),
        {MessageAction.deleteLocal, MessageAction.multiSelect},
      );
      expect(MessageActionPolicy.isForwardable(kind), isFalse);
    }
    expect(MessageActionPolicy.isForwardable(MessageContentKind.text), isTrue);
  });

  test('voice and call-summary messages never expose forward', () {
    // 需求 4b：语音、“通话已取消/通话时长”气泡不允许转发。
    for (final kind in [MessageContentKind.voice, MessageContentKind.call]) {
      expect(MessageActionPolicy.isForwardable(kind), isFalse,
          reason: '$kind 不可转发');
      final actions = MessageActionPolicy.actionsFor(
        MessageCapabilities(
          kind: kind,
          isOwn: true,
          sentAt: now.subtract(const Duration(minutes: 1)),
          serverNow: now,
        ),
      );
      expect(actions, isNot(contains(MessageAction.forward)),
          reason: '$kind 长按菜单不出现转发');
      expect(actions, contains(MessageAction.deleteLocal),
          reason: '$kind 仍可本地删除');
    }
    // 通话摘要走最小集合：仅本地删除与多选。
    final callActions = MessageActionPolicy.actionsFor(
      MessageCapabilities(
        kind: MessageContentKind.call,
        isOwn: false,
        sentAt: now,
        serverNow: now,
      ),
    );
    expect(callActions, unorderedEquals({
      MessageAction.deleteLocal,
      MessageAction.multiSelect,
    }));
  });
}
