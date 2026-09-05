import 'package:flutter/foundation.dart';
import '../../core/business_api_client.dart';

abstract interface class ChatRedPacketBusinessGateway {
  Future<String> create(
      {required String mode,
      required String total,
      required int shareCount,
      String? roomId,
      String? recipientId});
}

abstract interface class ChatRedPacketReferenceGateway {
  Future<void> sendReference(String packetId, String greeting);
}

enum ChatRedPacketStatus { idle, creating, sharing, sent, failed, shareFailed }

final class ChatRedPacketState {
  const ChatRedPacketState(
      {this.status = ChatRedPacketStatus.idle,
      this.packetId,
      this.greeting,
      this.message});
  final ChatRedPacketStatus status;
  final String? packetId, greeting, message;
}

final class ChatRedPacketController extends ChangeNotifier {
  ChatRedPacketController(
      {required this.business,
      required this.references,
      this.roomId,
      this.recipientId})
      : assert((roomId == null) != (recipientId == null));
  final ChatRedPacketBusinessGateway business;
  final ChatRedPacketReferenceGateway references;
  final String? roomId, recipientId;
  ChatRedPacketState state = const ChatRedPacketState();
  Future<void> submit(
      {required String total,
      required String greeting,
      String mode = 'EQUAL',
      int shareCount = 1,
      String? exclusiveRecipientId}) async {
    if (state.status == ChatRedPacketStatus.creating ||
        state.status == ChatRedPacketStatus.sharing) {
      return;
    }
    final target = mode == 'EXCLUSIVE' ? exclusiveRecipientId : recipientId;
    if (mode == 'EXCLUSIVE' &&
        (roomId == null || target == null || target.isEmpty)) {
      _set(const ChatRedPacketState(
          status: ChatRedPacketStatus.failed, message: '请选择专属红包接收人'));
      return;
    }
    _set(const ChatRedPacketState(status: ChatRedPacketStatus.creating));
    try {
      final id = await business.create(
          mode: mode,
          total: total,
          shareCount: shareCount,
          roomId: roomId,
          recipientId: target);
      _set(ChatRedPacketState(
          status: ChatRedPacketStatus.sharing,
          packetId: id,
          greeting: greeting));
      await _share(id, greeting);
    } catch (error) {
      if (state.packetId == null) {
        _set(ChatRedPacketState(
            status: ChatRedPacketStatus.failed, message: _error(error)));
      }
    }
  }

  Future<void> retryShare() async {
    final id = state.packetId, greeting = state.greeting;
    if (id == null || greeting == null) return;
    _set(ChatRedPacketState(
        status: ChatRedPacketStatus.sharing, packetId: id, greeting: greeting));
    await _share(id, greeting);
  }

  Future<void> _share(String id, String greeting) async {
    try {
      await references.sendReference(id, greeting);
      _set(ChatRedPacketState(
          status: ChatRedPacketStatus.sent, packetId: id, greeting: greeting));
    } catch (_) {
      _set(ChatRedPacketState(
          status: ChatRedPacketStatus.shareFailed,
          packetId: id,
          greeting: greeting,
          message: '红包已创建，但发送到会话失败；重试不会重复扣款'));
    }
  }

  String _error(Object error) {
    if (error is BusinessApiException) {
      if (error.code == 'RED_PACKET_BALANCE_INSUFFICIENT') {
        return '红包创建失败，账户余额不足';
      }
      if (error.code == 'RED_PACKET_LIMIT_EXCEEDED') {
        return error.message;
      }
    }
    final text = error.toString();
    if (text.contains('RED_PACKET_BALANCE_INSUFFICIENT') ||
        text.contains('insufficient balance')) {
      return '红包创建失败，账户余额不足';
    }
    return '红包创建失败，请检查余额或网络后重试';
  }

  void _set(ChatRedPacketState value) {
    state = value;
    notifyListeners();
  }
}
