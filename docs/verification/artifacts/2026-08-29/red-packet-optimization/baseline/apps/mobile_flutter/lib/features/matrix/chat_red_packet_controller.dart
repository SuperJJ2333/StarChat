import 'package:flutter/foundation.dart';

abstract interface class ChatRedPacketBusinessGateway {
  Future<String> create({
    required String mode,
    required String total,
    required int shareCount,
    String? roomId,
    String? recipientId,
  });
}

abstract interface class ChatRedPacketReferenceGateway {
  Future<void> sendReference(String packetId, String greeting);
}

enum ChatRedPacketStatus { idle, creating, sharing, sent, failed, shareFailed }

final class ChatRedPacketState {
  const ChatRedPacketState({
    this.status = ChatRedPacketStatus.idle,
    this.packetId,
    this.greeting,
    this.message,
  });

  final ChatRedPacketStatus status;
  final String? packetId;
  final String? greeting;
  final String? message;
}

final class ChatRedPacketController extends ChangeNotifier {
  ChatRedPacketController({
    required this.business,
    required this.references,
    this.roomId,
    this.recipientId,
  }) : assert((roomId == null) != (recipientId == null));

  final ChatRedPacketBusinessGateway business;
  final ChatRedPacketReferenceGateway references;
  final String? roomId;
  final String? recipientId;
  ChatRedPacketState state = const ChatRedPacketState();

  Future<void> submit({
    required String total,
    required String greeting,
    String mode = 'EQUAL',
    int shareCount = 1,
  }) async {
    if (state.status == ChatRedPacketStatus.creating ||
        state.status == ChatRedPacketStatus.sharing) {
      return;
    }
    _set(const ChatRedPacketState(status: ChatRedPacketStatus.creating));
    try {
      final packetId = await business.create(
        mode: mode,
        total: total,
        shareCount: shareCount,
        roomId: roomId,
        recipientId: recipientId,
      );
      _set(ChatRedPacketState(
        status: ChatRedPacketStatus.sharing,
        packetId: packetId,
        greeting: greeting,
      ));
      await _share(packetId, greeting);
    } catch (_) {
      if (state.packetId == null) {
        _set(const ChatRedPacketState(
          status: ChatRedPacketStatus.failed,
          message: '红包创建失败，请检查余额或网络后重试',
        ));
      }
    }
  }

  Future<void> retryShare() async {
    final packetId = state.packetId;
    final greeting = state.greeting;
    if (packetId == null || greeting == null) return;
    _set(ChatRedPacketState(
      status: ChatRedPacketStatus.sharing,
      packetId: packetId,
      greeting: greeting,
    ));
    await _share(packetId, greeting);
  }

  Future<void> _share(String packetId, String greeting) async {
    try {
      await references.sendReference(packetId, greeting);
      _set(ChatRedPacketState(
        status: ChatRedPacketStatus.sent,
        packetId: packetId,
        greeting: greeting,
      ));
    } catch (_) {
      _set(ChatRedPacketState(
        status: ChatRedPacketStatus.shareFailed,
        packetId: packetId,
        greeting: greeting,
        message: '红包已创建，但发送到会话失败；重试不会重复扣款',
      ));
    }
  }

  void _set(ChatRedPacketState next) {
    state = next;
    notifyListeners();
  }
}
