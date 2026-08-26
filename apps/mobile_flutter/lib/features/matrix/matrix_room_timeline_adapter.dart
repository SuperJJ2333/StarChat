import 'dart:typed_data';

import 'room_timeline_controller.dart';

/// Lifecycle-managed room operations required by the timeline. Implementations
/// stay behind the Matrix session boundary; no SDK room/timeline is retained by
/// this adapter or its UI consumers.
abstract interface class RoomTimelineCapability {
  List<RoomMessageViewModel> snapshot();
  Future<String> sendText(String text);
  Future<String> sendRedPacketReference(String packetId, String greeting);
  Future<Uint8List> loadAttachment(String eventId);
  Future<void> retry(String transactionId);
  Future<void> loadHistory();
  Future<void> markRead();
  void dispose();
}

final class MatrixRoomTimelineAdapter implements RoomTimelineAdapter {
  MatrixRoomTimelineAdapter(this._capability);

  final RoomTimelineCapability _capability;

  @override
  List<RoomMessageViewModel> snapshot() => _capability.snapshot();

  @override
  Future<String> sendText(String text) async => _capability.sendText(text);

  @override
  Future<String> sendRedPacketReference(
    String packetId,
    String greeting,
  ) async =>
      _capability.sendRedPacketReference(packetId, greeting);

  @override
  Future<Uint8List> loadAttachment(String eventId) async {
    return _capability.loadAttachment(eventId);
  }

  @override
  Future<void> retry(String transactionId) async {
    await _capability.retry(transactionId);
  }

  @override
  Future<void> loadHistory() => _capability.loadHistory();

  @override
  Future<void> markRead() => _capability.markRead();

  @override
  void dispose() => _capability.dispose();
}
