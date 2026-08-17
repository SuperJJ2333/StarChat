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
    expect(actions, isNot(contains(MessageAction.addToEmoji)));
    expect(actions, isNot(contains(MessageAction.recall)));
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
}
