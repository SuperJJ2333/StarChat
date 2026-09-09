import 'dart:convert';
import 'business_api_client.dart';

final class ChatPaymentCancelled implements Exception {
  const ChatPaymentCancelled();
}

typedef ChatPaymentAuthorize = Future<String?> Function(
    String action, Map<String, dynamic> payload, String idempotencyKey);

final class _PendingPayment {
  _PendingPayment(this.key);
  final String key;
  String? proof;
}

/// One form's payment intent. An uncertain create result keeps its original
/// key and proof; retrying never creates a second debit. Nothing is persisted.
final class ChatPaymentIntent {
  ChatPaymentIntent(
      {required this.api,
      required this.scope,
      required this.authorize,
      this.sessionScope});
  final BusinessApiClient api;
  final String scope;
  final String? sessionScope;
  final ChatPaymentAuthorize authorize;
  final _intents = <String, _PendingPayment>{};
  String? _selected;
  bool _busy = false;

  Future<Map<String, dynamic>> create(
      String action, Map<String, dynamic> payload) async {
    if (_busy) throw StateError('支付处理中，请稍候');
    _busy = true;
    try {
      if (await api.walletIntentScope() != scope) {
        clear();
        throw StateError('账户已切换，请重新打开支付页面');
      }
      if (sessionScope != null &&
          await api.paymentIntentScope() != sessionScope) {
        clear();
        throw const ChatPaymentCancelled();
      }
      final path = switch (action) {
        'chat_transfer.create' => '/chat-transfers',
        'red_packet.create' => '/red-packets',
        _ => throw ArgumentError('Unsupported payment action'),
      };
      final body = Map<String, dynamic>.unmodifiable(payload);
      final identity = Map<String, dynamic>.of(body);
      final amountField = action == 'chat_transfer.create' ? 'amount' : 'total';
      final rawAmount = identity[amountField]?.toString().trim();
      if (rawAmount != null &&
          RegExp(r'^[0-9]+(?:\.[0-9]{1,2})?$').hasMatch(rawAmount)) {
        final parts = rawAmount.split('.');
        identity[amountField] =
            '${BigInt.parse(parts[0])}.${parts.length == 1 ? '00' : parts[1].padRight(2, '0')}';
      }
      if (identity['note'] is String) {
        identity['note'] = (identity['note'] as String).trim();
        if (identity['note'] == '') identity.remove('note');
      }
      identity.removeWhere((key, value) => value == null);
      final keys = identity.keys.toList()..sort();
      final fingerprint = jsonEncode([
        action,
        {for (final key in keys) key: identity[key]}
      ]);
      if (_selected != fingerprint) {
        for (final entry in _intents.values) {
          entry.proof = null;
        }
        _selected = fingerprint;
      }
      final pending = _intents.putIfAbsent(
          fingerprint, () => _PendingPayment(api.newIdempotencyKey()));
      pending.proof ??= await authorize(action, body, pending.key);
      if (pending.proof == null) throw const ChatPaymentCancelled();
      try {
        final result = await api.postJson(
            path, {...body, 'payment_authorization': pending.proof},
            idempotencyKey: pending.key,
            expectedWalletScope: scope,
            expectedPaymentScope: sessionScope);
        pending.proof = null;
        return result;
      } on BusinessApiException catch (error) {
        if (error.code.startsWith('PAYMENT_PIN_') ||
            error.code.startsWith('PAYMENT_AUTHORIZATION_')) {
          pending.proof = null;
        }
        rethrow;
      }
    } finally {
      _busy = false;
    }
  }

  void clear() {
    _intents.clear();
    _selected = null;
  }
}
