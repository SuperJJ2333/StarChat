import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import '../../core/chat_payment_intent.dart';
import '../payment_pin/payment_pin_dialog.dart';

/// A fresh status query on each entry prevents device-local flags from deciding
/// whether an account has a payment credential.
Future<ChatPaymentIntent?> prepareChatPayment(
  BuildContext context, {
  required BusinessApiClient api,
  required String Function(Map<String, dynamic>) recipient,
}) async {
  final scope = await api.walletIntentScope();
  final sessionScope = await api.paymentIntentScope();
  Future<bool> current() async {
    try {
      return context.mounted &&
          await api.walletIntentScope() == scope &&
          await api.paymentIntentScope() == sessionScope;
    } catch (_) {
      return false;
    }
  }

  final status = await api.paymentPinStatus(
      expectedWalletScope: scope, expectedPaymentScope: sessionScope);
  if (!await current() || !context.mounted) return null;
  if (status['configured'] != true) {
    final setupKey = api.newIdempotencyKey();
    final ready = await showPaymentPinSetup(context, isScopeCurrent: current,
        onSetup: (pin, password) async {
      try {
        await api.setupPaymentPin(
            pin: pin,
            loginPassword: password,
            idempotencyKey: setupKey,
            expectedWalletScope: scope,
            expectedPaymentScope: sessionScope);
      } on BusinessApiException catch (error) {
        throw PaymentPinException(error.message);
      }
    });
    if (!ready || !await current()) return null;
  }
  return ChatPaymentIntent(
      api: api,
      scope: scope,
      sessionScope: sessionScope,
      authorize: (action, payload, key) async {
        if (!await current() || !context.mounted) return null;
        final transfer = action == 'chat_transfer.create';
        final amount = payload[transfer ? 'amount' : 'total'].toString();
        return showPaymentPinAuthorization(context,
            title: transfer ? '转账' : '发红包',
            recipient: recipient(payload),
            amount: '$amount 点钻',
            fee: transfer ? '手续费 ${chatPaymentFee(amount)} 点钻' : null,
            isScopeCurrent: current, onAuthorize: (pin) async {
          try {
            final result = await api.authorizePaymentPin(
                pin: pin,
                action: action,
                payload: payload,
                idempotencyKey: key,
                expectedWalletScope: scope,
                expectedPaymentScope: sessionScope);
            final proof = result['authorization'];
            if (proof is! String || proof.isEmpty) {
              throw const PaymentPinException('支付验证失败，请重试');
            }
            return proof;
          } on BusinessApiException catch (error) {
            throw PaymentPinException(error.message);
          }
        });
      });
}

/// Mirrors the existing 0.5% fee, half-up to cents, without binary floats.
String chatPaymentFee(String amount) {
  final parts = amount.split('.');
  final cents = BigInt.parse(parts[0]) * BigInt.from(100) +
      BigInt.parse(parts.length > 1 ? parts[1].padRight(2, '0') : '0');
  final rounded = (cents + BigInt.from(100)) ~/ BigInt.from(200);
  final fee = rounded < BigInt.one ? BigInt.one : rounded;
  return '${fee ~/ BigInt.from(100)}.${(fee % BigInt.from(100)).toString().padLeft(2, '0')}';
}
