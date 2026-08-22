import 'package:flutter/foundation.dart';

enum RoomDeliveryState { sent, sending, failed }

enum RoomMessageKind { text, image, file, voice, redPacket, system }

final class RoomMessageViewModel {
  const RoomMessageViewModel({
    required this.id,
    required this.senderId,
    required this.text,
    required this.isOwn,
    required this.deliveryState,
    required this.timestamp,
    this.kind = RoomMessageKind.text,
    this.mimeType,
    this.packetId,
    this.greeting,
    this.voiceDuration = const Duration(seconds: 1),
    this.isRecalled = false,
    this.replyToEventId,
  });

  final String id;
  final String senderId;
  final String text;
  final bool isOwn;
  final RoomDeliveryState deliveryState;
  final DateTime timestamp;
  final RoomMessageKind kind;
  final String? mimeType;
  final String? packetId;
  final String? greeting;
  final Duration voiceDuration;
  final bool isRecalled;
  final String? replyToEventId;

  RoomMessageViewModel copyWith({
    String? id,
    RoomDeliveryState? deliveryState,
  }) =>
      RoomMessageViewModel(
        id: id ?? this.id,
        senderId: senderId,
        text: text,
        isOwn: isOwn,
        deliveryState: deliveryState ?? this.deliveryState,
        timestamp: timestamp,
        kind: kind,
        mimeType: mimeType,
        packetId: packetId,
        greeting: greeting,
        voiceDuration: voiceDuration,
        isRecalled: isRecalled,
        replyToEventId: replyToEventId,
      );
}

bool shouldShowMessageTimeSeparator(
  DateTime? previous,
  DateTime current,
) =>
    previous == null ||
    current.difference(previous).abs() >= const Duration(minutes: 5);

abstract interface class RoomTimelineAdapter {
  List<RoomMessageViewModel> snapshot();
  Future<String> sendText(String text);
  Future<String> sendRedPacketReference(String packetId, String greeting);
  Future<Uint8List> loadAttachment(String eventId);
  Future<void> retry(String transactionId);
  Future<void> loadHistory();
  Future<void> markRead();
  void dispose();
}

final class RoomTimelineController extends ChangeNotifier {
  RoomTimelineController(this.adapter) : messages = adapter.snapshot();

  final RoomTimelineAdapter adapter;
  List<RoomMessageViewModel> messages;

  Future<void> refresh() async {
    messages = adapter.snapshot();
    notifyListeners();
  }

  Future<void> loadHistory() async {
    await adapter.loadHistory();
    await refresh();
  }

  Future<void> markRead() => adapter.markRead();

  Future<Uint8List> loadAttachment(String eventId) =>
      adapter.loadAttachment(eventId);

  Future<String> sendRedPacketReference(
    String packetId,
    String greeting,
  ) =>
      adapter.sendRedPacketReference(packetId, greeting);

  Future<void> sendText(String text) async {
    final transactionId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    messages = [
      ...messages,
      RoomMessageViewModel(
        id: transactionId,
        senderId: '',
        text: text,
        isOwn: true,
        deliveryState: RoomDeliveryState.sending,
        timestamp: DateTime.now(),
      ),
    ];
    notifyListeners();
    try {
      final eventId = await adapter.sendText(text);
      messages = [
        for (final message in messages)
          message.id == transactionId
              ? message.copyWith(
                  id: eventId,
                  deliveryState: RoomDeliveryState.sent,
                )
              : message,
      ];
    } catch (_) {
      messages = [
        for (final message in messages)
          message.id == transactionId
              ? message.copyWith(deliveryState: RoomDeliveryState.failed)
              : message,
      ];
    }
    notifyListeners();
  }

  @override
  void dispose() {
    adapter.dispose();
    super.dispose();
  }
}
