import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../payment_pin/payment_pin_dialog.dart';

/// Ephemeral proof only; PIN and authorization are never written to preferences.
final class WalletPaymentProof {
  const WalletPaymentProof(
      this.authorization, this.walletScope, this.sessionScope);
  final String authorization;
  final String walletScope;
  final String sessionScope;
}

/// Uses the same setup, six-digit keypad, errors and cancellation as chat payments.
/// Only identity authorization is performed here; no conversion or hold is made.
Future<WalletPaymentProof?> authorizeWalletPayment(
  BuildContext context, {
  required BusinessApiClient api,
  required String action,
  required Map<String, dynamic> payload,
  required String idempotencyKey,
  required String amount,
  required String recipient,
  required String expectedWalletScope,
}) async {
  final sessionScope = await api.paymentIntentScope();
  Future<bool> current() async {
    try {
      return context.mounted &&
          await api.walletIntentScope() == expectedWalletScope &&
          await api.paymentIntentScope() == sessionScope;
    } catch (_) {
      return false;
    }
  }

  if (!await current()) return null;
  final status = await api.paymentPinStatus(
      expectedWalletScope: expectedWalletScope,
      expectedPaymentScope: sessionScope);
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
            expectedWalletScope: expectedWalletScope,
            expectedPaymentScope: sessionScope);
      } on BusinessApiException catch (error) {
        throw PaymentPinException(error.message);
      }
    });
    if (!ready || !await current()) return null;
  }
  if (!context.mounted) return null;
  final proof = await showPaymentPinAuthorization(context,
      title: '提现',
      recipient: recipient,
      amount: amount,
      fee: '手续费 0 USDT · 1 点钻 = 1 USDT',
      isScopeCurrent: current, onAuthorize: (pin) async {
    try {
      final result = await api.authorizePaymentPin(
          pin: pin,
          action: action,
          payload: payload,
          idempotencyKey: idempotencyKey,
          expectedWalletScope: expectedWalletScope,
          expectedPaymentScope: sessionScope);
      final authorization = result['authorization'];
      if (authorization is! String || authorization.isEmpty) {
        throw const PaymentPinException('支付验证失败，请重试');
      }
      return authorization;
    } on BusinessApiException catch (error) {
      throw PaymentPinException(error.message);
    }
  });
  if (proof == null || !await current()) return null;
  return WalletPaymentProof(proof, expectedWalletScope, sessionScope);
}
