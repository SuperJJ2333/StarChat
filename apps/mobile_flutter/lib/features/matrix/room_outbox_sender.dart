import 'dart:async';

import '../../core/outbox/outbox_message.dart';
import '../../core/outbox/outbox_room_sender_registry.dart';
import 'room_timeline_controller.dart';

/// Open-page adapter which retains its original transport owner after the page
/// stops providing a controller. The UI send future remains independently timed.
final class RoomOutboxSender
    implements OutboxSender, OutboxTransportSettlement {
  RoomOutboxSender({
    required this.roomId,
    required RoomTimelineController? Function() controller,
    required bool Function() canSend,
  })  : _controller = controller,
        _canSend = canSend;

  @override
  final String roomId;
  final RoomTimelineController? Function() _controller;
  final bool Function() _canSend;
  final _settlements = <String, Future<void>>{};

  @override
  bool get canSend => _canSend();

  @override
  Future<void>? pendingTransportSettlement(String transactionId) =>
      _settlements[transactionId];

  @override
  Future<void>? get pendingRoomTransportSettlement {
    final foreground = _controller()?.pendingRoomTransportSettlement;
    final pending = [
      ..._settlements.values,
      if (foreground != null) foreground,
    ];
    return pending.isEmpty ? null : Future.wait(pending).then<void>((_) {});
  }

  @override
  Future<String> send(OutboxMessage message) async {
    final controller = _controller();
    if (controller == null) {
      throw StateError('Room timeline is not ready');
    }
    final sending = controller.sendText(message.content, outboxRow: message);
    final settled = controller.pendingTransportSettlement(message.txid);
    if (settled != null) {
      _settlements[message.txid] = settled;
      unawaited(settled.whenComplete(() {
        if (identical(_settlements[message.txid], settled)) {
          _settlements.remove(message.txid);
        }
      }));
    }
    final eventId = await sending;
    if (eventId == null || eventId.isEmpty) {
      throw StateError('Matrix event was not accepted');
    }
    return eventId;
  }
}
