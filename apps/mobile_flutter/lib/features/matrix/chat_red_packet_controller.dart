import 'package:flutter/foundation.dart';
import '../../core/business_api_client.dart';
import '../../core/chat_payment_intent.dart';

abstract interface class ChatRedPacketBusinessGateway {
  Future<String> create(
      {required String mode,
      required String total,
      required int shareCount,
      String? roomId,
      String? recipientId});
}

abstract interface class ChatRedPacketReferenceGateway {
  Future<void> sendReference(String packetId, String greeting,
      {String? mode, String? recipientId, String? recipientMatrixId});
}

enum ChatRedPacketStatus { idle, creating, sharing, sent, failed, shareFailed }

final class ChatRedPacketState {
  const ChatRedPacketState(
      {this.status = ChatRedPacketStatus.idle,
      this.packetId,
      this.greeting,
      this.mode,
      this.recipientId,
      this.recipientMatrixId,
      this.message});
  final ChatRedPacketStatus status;
  final String? packetId, greeting, message;

  /// 红包类型与专属对象（随引用消息进入房间，仅供成员本机解析展示名）。
  final String? mode;
  final String? recipientId;
  final String? recipientMatrixId;
}

final class ChatRedPacketController extends ChangeNotifier {
  ChatRedPacketController(
      {required this.business,
      required this.references,
      this.roomId,
      this.recipientId,
      this.recipientMatrixId,
      int? joinedMemberCount,
      this.refreshJoinedMemberCount})
      : _joinedMemberCount = joinedMemberCount,
        assert((roomId == null) != (recipientId == null));
  final ChatRedPacketBusinessGateway business;
  final ChatRedPacketReferenceGateway references;
  final String? roomId, recipientId, recipientMatrixId;
  final Future<int> Function()? refreshJoinedMemberCount;
  int? _joinedMemberCount;
  bool _disposed = false;

  /// Current group total, including the sender. This is intentionally
  /// independent from the exclusive-recipient selection list.
  int? get joinedMemberCount => _joinedMemberCount;

  int? get joinedMemberShareLimit {
    final count = _joinedMemberCount;
    if (count == null) return null;
    return count < 500 ? count : 500;
  }

  ChatRedPacketState state = const ChatRedPacketState();
  Future<void> submit(
      {required String total,
      required String greeting,
      String mode = 'EQUAL',
      int shareCount = 1,
      String? exclusiveRecipientId,
      String? exclusiveRecipientMatrixId}) async {
    if (_disposed) return;
    if (state.status == ChatRedPacketStatus.creating ||
        state.status == ChatRedPacketStatus.sharing) {
      return;
    }
    final exclusive = mode == 'EXCLUSIVE';
    final target = exclusive ? exclusiveRecipientId : recipientId;
    final targetMatrixId =
        exclusive ? exclusiveRecipientMatrixId : recipientMatrixId;
    if (exclusive &&
        (roomId == null || target == null || target.isEmpty)) {
      _set(const ChatRedPacketState(
          status: ChatRedPacketStatus.failed, message: '请选择专属红包接收人'));
      return;
    }
    _set(const ChatRedPacketState(status: ChatRedPacketStatus.creating));
    try {
      if (roomId != null) {
        final count = await _refreshMemberCount();
        if (_disposed) return;
        if (count != null && shareCount > (count < 500 ? count : 500)) {
          _set(const ChatRedPacketState(
              status: ChatRedPacketStatus.failed, message: '红包个数不能超过群成员人数'));
          return;
        }
      }
      final id = await business.create(
          mode: mode,
          total: total,
          shareCount: shareCount,
          roomId: roomId,
          recipientId: target);
      _set(ChatRedPacketState(
          status: ChatRedPacketStatus.sharing,
          packetId: id,
          greeting: greeting,
          mode: mode,
          recipientId: target,
          recipientMatrixId: targetMatrixId));
      await _share(id, greeting, mode, target, targetMatrixId);
    } on _MemberCountRefreshFailure {
      if (!_disposed) {
        _set(const ChatRedPacketState(
            status: ChatRedPacketStatus.failed, message: '群成员加载失败，请稍后重试'));
      }
    } on ChatPaymentCancelled {
      _set(const ChatRedPacketState());
    } catch (error) {
      if (state.packetId == null) {
        _set(ChatRedPacketState(
            status: ChatRedPacketStatus.failed, message: _error(error)));
      }
    }
  }

  Future<void> retryShare() async {
    if (_disposed) return;
    final id = state.packetId, greeting = state.greeting;
    if (id == null || greeting == null) return;
    _set(ChatRedPacketState(
        status: ChatRedPacketStatus.sharing,
        packetId: id,
        greeting: greeting,
        mode: state.mode,
        recipientId: state.recipientId,
        recipientMatrixId: state.recipientMatrixId));
    await _share(
        id, greeting, state.mode, state.recipientId, state.recipientMatrixId);
  }

  Future<void> _share(String id, String greeting, String? mode,
      String? recipientId, String? recipientMatrixId) async {
    try {
      await references.sendReference(id, greeting,
          mode: mode,
          recipientId: recipientId,
          recipientMatrixId: recipientMatrixId);
      _set(ChatRedPacketState(
          status: ChatRedPacketStatus.sent,
          packetId: id,
          greeting: greeting,
          mode: mode,
          recipientId: recipientId,
          recipientMatrixId: recipientMatrixId));
    } catch (_) {
      _set(ChatRedPacketState(
          status: ChatRedPacketStatus.shareFailed,
          packetId: id,
          greeting: greeting,
          mode: mode,
          recipientId: recipientId,
          recipientMatrixId: recipientMatrixId,
          message: '红包已创建，但发送到会话失败；重试不会重复扣款'));
    }
  }

  String _error(Object error) {
    if (error is BusinessApiException) {
      if (error.code.startsWith('PAYMENT_PIN_')) return error.message;
      if (error.code == 'RED_PACKET_BALANCE_INSUFFICIENT') {
        return '红包创建失败，账户余额不足';
      }
      if (error.code == 'RED_PACKET_LIMIT_EXCEEDED') {
        return error.message;
      }
      if (error.code == 'RED_PACKET_SHARE_COUNT_EXCEEDS_MEMBERS') {
        return '红包个数不能超过群成员人数';
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
    if (_disposed) return;
    state = value;
    notifyListeners();
  }

  Future<int?> _refreshMemberCount() async {
    final refresh = refreshJoinedMemberCount;
    if (refresh == null) return _joinedMemberCount;
    try {
      final count = await refresh();
      if (_disposed) return null;
      _joinedMemberCount = count;
      _set(const ChatRedPacketState(status: ChatRedPacketStatus.creating));
      return count;
    } catch (_) {
      throw const _MemberCountRefreshFailure();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}

final class _MemberCountRefreshFailure implements Exception {
  const _MemberCountRefreshFailure();
}
