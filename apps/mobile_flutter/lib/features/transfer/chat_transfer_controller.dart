import 'package:flutter/foundation.dart';
import '../../core/business_api_client.dart';

abstract interface class ChatTransferBusinessGateway {
  Future<Map<String, dynamic>> create(
      {required String receiverId, required String amount, String? note});
}

abstract interface class ChatTransferReferenceGateway {
  Future<void> sendReference(String transferId, String amount, String? note);
}

enum ChatTransferStatus { idle, creating, sharing, sent, failed, shareFailed }

final class ChatTransferState {
  const ChatTransferState(
      {this.status = ChatTransferStatus.idle,
      this.transferId,
      this.amount,
      this.note,
      this.message});
  final ChatTransferStatus status;
  final String? transferId;
  final String? amount;
  final String? note;
  final String? message;
}

final class ChatTransferController extends ChangeNotifier {
  ChatTransferController({required this.business, required this.references});
  final ChatTransferBusinessGateway business;
  final ChatTransferReferenceGateway references;
  ChatTransferState state = const ChatTransferState();

  Future<void> submit(
      {required String receiverId,
      required String amount,
      String? note}) async {
    if (state.status == ChatTransferStatus.creating ||
        state.status == ChatTransferStatus.sharing) {
      return;
    }
    _set(const ChatTransferState(status: ChatTransferStatus.creating));
    try {
      final created = await business.create(
          receiverId: receiverId, amount: amount, note: note);
      final transferId = created['id']?.toString();
      if (transferId == null || transferId.isEmpty) {
        throw StateError('transfer id missing');
      }
      _set(ChatTransferState(
          status: ChatTransferStatus.sharing,
          transferId: transferId,
          amount: amount,
          note: note));
      await _share(transferId, amount, note);
    } catch (error) {
      if (state.transferId == null) {
        _set(ChatTransferState(
            status: ChatTransferStatus.failed, message: _error(error)));
      }
    }
  }

  Future<void> retryShare() async {
    final id = state.transferId;
    final amount = state.amount;
    if (id == null || amount == null) return;
    _set(ChatTransferState(
        status: ChatTransferStatus.sharing,
        transferId: id,
        amount: amount,
        note: state.note));
    await _share(id, amount, state.note);
  }

  Future<void> _share(String id, String amount, String? note) async {
    try {
      await references.sendReference(id, amount, note);
      _set(ChatTransferState(
          status: ChatTransferStatus.sent,
          transferId: id,
          amount: amount,
          note: note));
    } catch (_) {
      _set(ChatTransferState(
          status: ChatTransferStatus.shareFailed,
          transferId: id,
          amount: amount,
          note: note,
          message: '转账已创建，但发送到会话失败；重试不会重复扣款'));
    }
  }

  String _error(Object error) {
    if (error is BusinessApiException &&
        error.code == 'CHAT_TRANSFER_BALANCE_INSUFFICIENT') {
      return '转账失败，账户余额不足';
    }
    final text = error.toString();
    if (text.contains('CHAT_TRANSFER_BALANCE_INSUFFICIENT') ||
        text.contains('insufficient balance')) {
      return '转账失败，账户余额不足';
    }
    return '转账创建失败，请检查余额或网络后重试';
  }

  void _set(ChatTransferState value) {
    state = value;
    notifyListeners();
  }
}
