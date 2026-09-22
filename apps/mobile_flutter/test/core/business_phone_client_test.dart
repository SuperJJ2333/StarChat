import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

/// ADR-0075/0077/0076/0079：客户端契约层真实 HTTP 回归（MockClient 按路径
/// 分发到固定 JSON 响应；断言方法、载荷与幂等键，不需要真实后端）。
void main() {
  final captured = <_Captured>[];
  late BusinessApiClient api;

  String routeFor(String method, String path, String? body) {
    if (path.endsWith('/auth/register')) {
      return jsonEncode({
        'registration_session': 'rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr',
        'status': 'PENDING_PHONE',
        'resend_after_seconds': 60,
      });
    }
    if (path.endsWith('/auth/phone/registration/verify')) {
      return jsonEncode({'status': 'PENDING_MATRIX'});
    }
    if (path.endsWith('/auth/phone/login')) {
      return jsonEncode({
        'access_token': 'at',
        'refresh_token': 'rt',
        'matrix_user_id': '@new:x',
      });
    }
    if (path.endsWith('/contacts/search-phone')) {
      return jsonEncode({
        'found': true,
        'user': {'user_id': 'u9', 'username': 'found', 'nickname': '昵称'},
      });
    }
    if (path.endsWith('/recharge/directory')) {
      return jsonEncode({
        'items': [
          {
            'cs_user_id': 'cs-1',
            'display_name': '客服',
            'payment_address': 'T' * 34
          }
        ]
      });
    }
    if (path.endsWith('/recharge/requests') && method == 'POST') {
      return jsonEncode({
        'id': 'req-1',
        'status': 'SUBMITTED',
        'amount_usdt': '50.000000',
      });
    }
    if (path.endsWith('/recharge/requests/mine') ||
        (path.endsWith('/recharge/requests') && method == 'GET')) {
      return jsonEncode({
        'items': [
          {'id': 'req-1', 'status': 'SUBMITTED', 'amount_usdt': '50.000000'}
        ]
      });
    }
    if (path.endsWith('/fx/rate')) {
      return jsonEncode({
        'rate': '7.120000',
        'stale': false,
        'disclaimer': '参考估算，最终以客服结算为准',
      });
    }
    if (path.contains('/transfer-intents')) {
      return jsonEncode({
        'items': [
          {'id': 'it-1', 'stage': 'NEEDS_REVIEW', 'last_error_code': null}
        ]
      });
    }
    return jsonEncode({});
  }

  setUp(() {
    captured.clear();
    final client = MockClient((request) async {
      assertOpenApiRequest(request);
      captured.add(_Captured(request.method, request.url.toString(),
          request.headers, request.body));
      return http.Response(
          routeFor(request.method, request.url.path, request.body), 200,
          headers: {'content-type': 'application/json'});
    });
    api = BusinessApiClient(
      baseUri: Uri.parse('https://api.test'),
      sessionStore: SecureSessionStore(MemoryStore()),
      client: client,
    );
  });

  test('phone login clears the previous session refresh backoff', () async {
    var available = false;
    var refreshCalls = 0;
    final store = SecureSessionStore(MemoryStore());
    await store.saveSession(accessToken: 'old-a', refreshToken: 'old-r');
    final client = BusinessApiClient(
      baseUri: Uri.parse('https://api.test'),
      sessionStore: store,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth/refresh')) {
          refreshCalls++;
          if (!available)
            return http.Response('{"detail":{"code":"UNAVAILABLE"}}', 503);
          return http.Response(
              '{"access_token":"fresh-a","refresh_token":"fresh-r"}', 200);
        }
        return http.Response(
            '{"access_token":"phone-a","refresh_token":"phone-r"}', 200);
      }),
    );
    await expectLater(
        client.refreshSession(), throwsA(isA<BusinessApiException>()));
    final callsBeforeLogin = refreshCalls;
    available = true;
    await client.phoneLogin(
        phone: '+8613800000001',
        code: '123456',
        deviceKey: 'device-1',
        deviceName: 'test');
    await client.refreshSession();
    expect(refreshCalls, callsBeforeLogin + 1);
    expect((await store.session())!.accessToken, 'fresh-a');
    expect((await store.session())!.deviceKey, 'device-1');
  });

  test(
      'registerWithPhone posts phone channel without email and keeps idempotency',
      () async {
    final receipt = await api.registerWithPhone(
      username: 'alice',
      phone: '+8613800000001',
      password: 'correct horse battery staple',
      invitationCode: 'INV-1',
    );
    expect(receipt.registrationSession,
        'rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr');
    expect(receipt.status, 'PENDING_PHONE');
    final post = captured.first;
    expect(post.url, contains('/auth/register'));
    final payload = jsonDecode(post.body!) as Map<String, dynamic>;
    expect(payload['phone'], '+8613800000001');
    expect(payload.containsKey('email'), isFalse, reason: '手机通道不得虚构邮箱占位');
    expect(post.headers['Idempotency-Key'], isNotEmpty);
  });

  test('registration otp request/verify hit the bound-session endpoints',
      () async {
    await api
        .requestRegistrationOtp('rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr');
    expect(captured.last.url, contains('/auth/phone/registration/request'));
    await api.verifyRegistrationPhone(
        registrationSession: 'rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr',
        phone: '+8613800000001',
        code: '123456');
    final verify = captured.last;
    expect(verify.url, contains('/auth/phone/registration/verify'));
    final payload = jsonDecode(verify.body!) as Map<String, dynamic>;
    expect(payload['registration_session'],
        'rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr');
    expect(payload['code'], '123456');
  });

  test('phone login persists the session like password login', () async {
    final body = await api.phoneLogin(
      phone: '+8613800000001',
      code: '123456',
      deviceKey: 'device-key-1',
      deviceName: 'Mi 6',
    );
    expect(body['access_token'], 'at');
    expect(captured.last.url, contains('/auth/phone/login'));
    final payload = jsonDecode(captured.last.body!) as Map<String, dynamic>;
    expect(payload['device_key'], 'device-key-1');
  });

  test('rebind two-step endpoints are called in contract order with codes',
      () async {
    await api.rebindOldRequest();
    await api.rebindOldConfirm(code: '111111');
    await api.rebindNewRequest(phone: '+8613900000002');
    await api.rebindNewConfirm(phone: '+8613900000002', code: '222222');
    final paths = captured.map((c) => c.url).toList();
    expect(paths, contains(contains('/auth/phone/rebind/old-request')));
    expect(paths, contains(contains('/auth/phone/rebind/old-confirm')));
    expect(paths, contains(contains('/auth/phone/rebind/new-request')));
    expect(paths, contains(contains('/auth/phone/rebind/confirm')));
  });

  test('search response never contains the phone number', () async {
    final result = await api.searchByPhone('+8613800000001');
    expect(result['found'], isTrue);
    expect(jsonEncode(result).contains('13800000001'), isFalse,
        reason: '搜索结果不得回显手机号');
  });

  test('recharge directory/submit/history and fx rate use real routes',
      () async {
    final directory = await api.rechargeDirectory();
    expect(directory.first['cs_user_id'], 'cs-1');
    final submitted = await api.submitRecharge(
      amountUsdt: '50.000000',
      evidenceTxid: 'B' * 64,
      idempotencyKey: 'recharge-key-1',
    );
    expect(submitted['status'], 'SUBMITTED');
    final post = captured.last;
    expect(post.url, contains('/recharge/requests'));
    expect(post.headers['Idempotency-Key'], 'recharge-key-1');
    final mine = await api.myRecharges();
    expect(mine.first['status'], 'SUBMITTED');
    final fx = await api.fxRate();
    expect(fx['stale'], isFalse);
  });

  test(
      'authorized phone operations keep bearer and exact rebind/privacy fields',
      () async {
    await api.phoneLogin(
        phone: '+8613800000001',
        code: '123456',
        deviceKey: 'device-key-1',
        deviceName: 'test');
    await api.rebindOldRequest();
    await api.rebindOldConfirm(code: '111111');
    await api.rebindNewRequest(phone: '+8613900000002');
    await api.rebindNewConfirm(phone: '+8613900000002', code: '222222');
    expect(jsonDecode(captured.last.body!),
        {'new_phone': '+8613900000002', 'code': '222222'});
    await api.setPhoneFindable(false);
    expect(captured.last.method, 'PATCH');
    expect(jsonDecode(captured.last.body!), {'phone_findable': false});
    await api.cancelRecharge('req-1');
    expect(captured.last.method, 'POST');
    expect(captured.last.url, endsWith('/recharge/requests/req-1/cancel'));
    for (final request in captured.skip(1)) {
      expect(request.headers['Authorization'], 'Bearer at');
    }
  });

  test('login OTP uses public phone endpoint and a stable device key',
      () async {
    await api.requestPhoneLoginOtp('+8613800000001');
    final first = captured.last;
    await api.requestPhoneLoginOtp('+8613800000001');
    expect(first.url, endsWith('/auth/phone/login/request'));
    expect(first.method, 'POST');
    expect(jsonDecode(first.body!), {'phone': '+8613800000001'});
    expect(first.headers['X-Device-Key'], isNotEmpty);
    expect(
        captured.last.headers['X-Device-Key'], first.headers['X-Device-Key']);
  });

  test('transfer intents are listed by room id', () async {
    final intents = await api.transferIntents('!room:x');
    expect(intents.first['stage'], 'NEEDS_REVIEW');
    expect(captured.last.url, contains('/groups/!room%3Ax/transfer-intents'));
  });
}

class _Captured {
  const _Captured(this.method, this.url, this.headers, this.body);
  final String method;
  final String url;
  final Map<String, String> headers;
  final String? body;
}

/// 内存键值存储（与既有测试一致；SecureSessionStore 依赖注入用）。
final class MemoryStore implements SecureKeyValueStore {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
  @override
  Future<void> delete(String key) async => _values.remove(key);
}

// Validate emitted requests against the generated server contract, not a permissive fixture.
void assertOpenApiRequest(http.Request request) {
  final contract = jsonDecode(
      File('../../packages/api-contracts/openapi/liuhetong-v1.yaml')
          .readAsStringSync()) as Map<String, dynamic>;
  final paths = contract['paths'] as Map<String, dynamic>;
  final matching = paths.entries
      .where((entry) =>
          RegExp("^${entry.key.replaceAll(RegExp(r'\{[^}]+\}'), r'[^/]+')}\$")
              .hasMatch(request.url.path))
      .toList();
  expect(matching, isNotEmpty,
      reason: 'Unknown server path ${request.url.path}');
  final operation = matching.first.value[request.method.toLowerCase()];
  expect(operation, isNotNull, reason: 'Unknown HTTP method ${request.method}');
  final raw =
      operation['requestBody']?['content']?['application/json']?['schema'];
  if (raw == null) return;
  final schema = raw[r'$ref'] != null
      ? contract['components']['schemas']
          [raw[r'$ref'].toString().split('/').last]
      : raw;
  final body = jsonDecode(request.body) as Map<String, dynamic>;
  for (final key in (schema['required'] as List? ?? [])) {
    expect(body.containsKey(key), isTrue, reason: 'Missing server field $key');
  }
  final properties = schema['properties'] as Map<String, dynamic>;
  if (schema['additionalProperties'] == false) {
    expect(body.keys.every(properties.containsKey), isTrue,
        reason: 'Unexpected request field');
  }
  for (final entry in body.entries) {
    final rules = properties[entry.key] as Map<String, dynamic>?;
    if (rules == null) continue;
    if (entry.value is String && rules['minLength'] != null) {
      expect((entry.value as String).length,
          greaterThanOrEqualTo(rules['minLength'] as int));
    }
    if (entry.value is String && rules['pattern'] != null) {
      expect(RegExp(rules['pattern'] as String).hasMatch(entry.value as String),
          isTrue);
    }
  }
}
