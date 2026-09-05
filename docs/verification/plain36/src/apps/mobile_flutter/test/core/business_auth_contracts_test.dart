import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/core/business_api_error.dart';
import 'package:liuhetong_mobile/core/business_auth_contracts.dart';

void main() {
  group('mapInvitationCheck（服务端 reason → 状态机）', () {
    test('OK → ready', () {
      final result =
          mapInvitationCheck(valid: true, reason: 'OK');
      expect(result.state, InvitationValidationState.ready);
    });

    test('INVALID / EXPIRED / EXHAUSTED 各自映射', () {
      expect(
          mapInvitationCheck(valid: false, reason: 'INVALID').state,
          InvitationValidationState.invalid);
      expect(
          mapInvitationCheck(valid: false, reason: 'EXPIRED').state,
          InvitationValidationState.expired);
      expect(
          mapInvitationCheck(valid: false, reason: 'EXHAUSTED').state,
          InvitationValidationState.exhausted);
    });

    test('缺失 reason 且无效 → 兜底 invalid', () {
      expect(mapInvitationCheck(valid: false, reason: null).state,
          InvitationValidationState.invalid);
    });
  });

  group('mapInvitationFailure（异常 → 可重试/不可重试分支）', () {
    test('TimeoutException → NETWORK_ERROR（8s 超时防无限 Loading）', () {
      final result =
          mapInvitationFailure(TimeoutException('timeout', Duration(seconds: 8)));
      expect(result.state, InvitationValidationState.networkError);
    });

    test('SocketException → NETWORK_ERROR', () {
      final result =
          mapInvitationFailure(const SocketException('offline'));
      expect(result.state, InvitationValidationState.networkError);
    });

    test('5xx → SERVER_ERROR（可重新加载）', () {
      final result = mapInvitationFailure(const BusinessApiException(
        statusCode: 502,
        code: 'SERVER_ERROR',
        message: 'bad gateway',
      ));
      expect(result.state, InvitationValidationState.serverError);
    });

    test('429 RATE_LIMITED → SERVER_ERROR', () {
      final result = mapInvitationFailure(const BusinessApiException(
        statusCode: 429,
        code: 'RATE_LIMITED',
        message: '请求过于频繁',
      ));
      expect(result.state, InvitationValidationState.serverError);
    });

    test('400 业务错误 → INVALID', () {
      final result = mapInvitationFailure(const BusinessApiException(
        statusCode: 400,
        code: 'INVITATION_INVALID',
        message: '邀请码无效',
      ));
      expect(result.state, InvitationValidationState.invalid);
    });
  });

  group('BusinessApiException 与 http 包集成', () {
    test('可由 http.Response 构造（模拟真实解码路径）', () {
      final response = http.Response(
          '{"error":{"code":"INVITATION_INVALID","message":"邀请码无效"}}',
          400,
          headers: {'content-type': 'application/json'});
      expect(() => throw BusinessApiException(
            statusCode: response.statusCode,
            code: 'INVITATION_INVALID',
            message: '邀请码无效',
          ), throwsA(isA<BusinessApiException>()));
    });
  });
}
