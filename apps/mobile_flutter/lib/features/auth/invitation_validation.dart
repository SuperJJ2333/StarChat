import 'dart:async';
import 'dart:io';

import '../../core/business_api_client.dart';

/// 邀请码校验状态机（BUG 1）：
/// INITIAL → LOADING → READY / INVALID / EXPIRED / EXHAUSTED
///                     ↘ NETWORK_ERROR / SERVER_ERROR（可"重新加载"）
enum InvitationValidationState {
  initial,
  loading,
  ready,
  invalid,
  expired,
  exhausted,
  networkError,
  serverError,
}

/// 一次校验的完整结果：状态 + 面向用户的提示文案。
final class InvitationValidationResult {
  const InvitationValidationResult(this.state, this.message);

  final InvitationValidationState state;
  final String message;
}

/// 把底层异常映射为状态机的错误分支：
/// - 超时/断网/DNS → NETWORK_ERROR（可重试）；
/// - 5xx/限流 → SERVER_ERROR（可重试）；
/// - 4xx → INVALID（服务端已细分的 EXPIRED/EXHAUSTED 由 reason 给出）。
InvitationValidationResult mapInvitationFailure(Object error) {
  if (error is TimeoutException) {
    return const InvitationValidationResult(
        InvitationValidationState.networkError, '校验超时，请检查网络后重试');
  }
  if (error is SocketException || error is HttpException) {
    return const InvitationValidationResult(
        InvitationValidationState.networkError, '网络不可用，请检查网络后重试');
  }
  if (error is BusinessApiException) {
    if (error.statusCode >= 500 || error.code == 'RATE_LIMITED') {
      return const InvitationValidationResult(
          InvitationValidationState.serverError, '服务暂时不可用，请稍后重试');
    }
    return const InvitationValidationResult(
        InvitationValidationState.invalid, '邀请码无效');
  }
  return const InvitationValidationResult(
      InvitationValidationState.networkError, '校验失败，请重试');
}

/// 服务端 200 响应 → 校验结果（reason ∈ OK/INVALID/EXPIRED/EXHAUSTED）。
InvitationValidationResult mapInvitationCheck({
  required bool valid,
  required String? reason,
}) {
  if (valid) {
    return const InvitationValidationResult(
        InvitationValidationState.ready, '邀请码可用');
  }
  switch (reason) {
    case 'EXPIRED':
      return const InvitationValidationResult(
          InvitationValidationState.expired, '邀请码已过期');
    case 'EXHAUSTED':
      return const InvitationValidationResult(
          InvitationValidationState.exhausted, '邀请码使用次数已耗尽');
    default:
      return const InvitationValidationResult(
          InvitationValidationState.invalid, '邀请码无效');
  }
}
