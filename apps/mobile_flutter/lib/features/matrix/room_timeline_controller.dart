import 'package:flutter/foundation.dart';

enum RoomDeliveryState { sent, sending, failed }

final class RoomMessageViewModel {
  const RoomMessageViewModel({required this.id, required this.senderId, required this.text, required this.isOwn, required this.deliveryState});
  final String id;
  final String senderId;
  final String text;
  final bool isOwn;
  final RoomDeliveryState deliveryState;
}

abstract interface class RoomTimelineAdapter {
  List<RoomMessageViewModel> snapshot();
  Future<String> sendText(String text);
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

  Future<void> sendText(String text) async {
    final transactionId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    messages = [...messages, RoomMessageViewModel(id: transactionId, senderId: '', text: text, isOwn: true, deliveryState: RoomDeliveryState.sending)];
    notifyListeners();
    try {
      final eventId = await adapter.sendText(text);
      messages = [for (final message in messages) message.id == transactionId ? RoomMessageViewModel(id: eventId, senderId: message.senderId, text: message.text, isOwn: true, deliveryState: RoomDeliveryState.sent) : message];
    } catch (_) {
      messages = [for (final message in messages) message.id == transactionId ? RoomMessageViewModel(id: message.id, senderId: message.senderId, text: message.text, isOwn: true, deliveryState: RoomDeliveryState.failed) : message];
    }
    notifyListeners();
  }

  @override
  void dispose() {
    adapter.dispose();
    super.dispose();
  }
}
