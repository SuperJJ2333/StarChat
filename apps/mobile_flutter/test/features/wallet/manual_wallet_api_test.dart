import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_api.dart';

class MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

const at = '2026-09-07T10:00:00+00:00';
const token = 'e30.eyJzdWIiOiJhbGljZSJ9.test';
const refreshedToken = 'e30.eyJzdWIiOiJhbGljZSJ9.refreshed';
final binding = <String, dynamic>{
  'status': 'ACTIVE',
  'id': 'binding',
  'version': 1,
  'masked_address': 'T***123',
  'pending_id': null,
  'next_rebind_at': null,
  'binding_enabled': true,
  'unavailable_dependencies': <String>[],
  'rebind_interval_days': 30
};
final challenge = <String, dynamic>{
  'id': 'challenge',
  'message': 'private-challenge',
  'expires_at': at,
  'protocol': 'signMessageV2'
};
final confirmed = <String, dynamic>{
  'id': 'binding',
  'status': 'PENDING',
  'version': 2,
  'blocked_reason': 'FINALITY_PENDING'
};
final rules = <String, dynamic>{
  'version': 'DEPOSIT_INTENT_V1',
  'minimum_amount': '10.000000',
  'asset': 'USDT',
  'precision': 6,
  'finality_policy': 'TRONGRID_SINGLE_SOURCE_V1',
  'expiry_microseconds': 1200000000
};
final intent = <String, dynamic>{
  'id': 'intent',
  'binding_id': 'binding',
  'binding_version': 1,
  'binding_effective_from_block': 101,
  'source_address': 'source',
  'official_address': 'official',
  'official_config_version': 'v1',
  'network': 'tron-mainnet',
  'rules_snapshot': rules,
  'status': 'OPEN',
  'expected_amount': '999999999999999999999999.999999',
  'created_at': at,
  'expires_at': at,
  'closed_at': null
};
final quote = <String, dynamic>{
  'id': 'quote',
  'digest': 'a' * 64,
  'binding_id': 'binding',
  'binding_version': 1,
  'target_address': 'target',
  'official_address': 'official',
  'official_config_version': 'v1',
  'owner_admin_id': 'owner',
  'policy_version': 'v1',
  'approval_policy': 'OWNER_MANUAL_V1',
  'finality_policy': 'TRONGRID_SINGLE_SOURCE_V1',
  'network': 'tron-mainnet',
  'contract': 'contract',
  'amount': '10.000000',
  'fee': '0.000000',
  'hold': '10.000000',
  'receive': '10.000000',
  'minimum': '10.000000',
  'max_per': '100.000000',
  'user_24h': '200.000000',
  'global_24h': '500.000000',
  'safety_epoch': 0,
  'created_at': at,
  'expires_at': at
};
final payout = <String, dynamic>{
  'id': 'order',
  'user_id': 'alice',
  'quote_id': 'quote',
  'amount': '10.000000',
  'status': 'REQUESTED',
  'digest': 'b' * 64,
  'candidate_txid': null,
  'settlement_txid': null,
  'review_reason': null
};
final mfa = <String, dynamic>{
  'configured': true,
  'enabled': false,
  'enrolled_at': null
};
final enrollment = <String, dynamic>{
  'credential_id': 'credential',
  'secret': 'PRIVATESECRET',
  'provisioning_uri': 'otpauth://totp/test?secret=PRIVATESECRET'
};

void main() {
  test('authentication refresh preserves financial body and idempotency key',
      () async {
    final session = SecureSessionStore(MemoryStore());
    await session.saveSession(accessToken: token, refreshToken: 'refresh');
    final writes = <http.Request>[];
    final api = ManualWalletApi(BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: session,
        client: MockClient((request) async {
          if (request.url.path == '/api/v1/auth/refresh') {
            return http.Response(
                jsonEncode(
                    {'access_token': refreshedToken, 'refresh_token': 'next'}),
                200);
          }
          writes.add(request);
          return writes.length == 1
              ? http.Response('{}', 401)
              : http.Response(jsonEncode(payout), 201);
        })));
    await api.createPayout(
        quoteId: 'quote', mfaProof: '123456', idempotencyKey: 'stable-key');
    expect(writes, hasLength(2));
    expect(writes[0].body, writes[1].body);
    expect(writes.map((r) => r.headers['idempotency-key']),
        ['stable-key', 'stable-key']);
    expect(writes[1].headers['authorization'], 'Bearer $refreshedToken');
  });

  test('server readiness errors propagate without fabricated wallet state',
      () async {
    final session = SecureSessionStore(MemoryStore());
    await session.saveSession(accessToken: token, refreshToken: 'refresh');
    final api = ManualWalletApi(BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: session,
        client: MockClient((request) async => http.Response(
            jsonEncode({
              'error': {
                'code': 'WALLET_MANUAL_NOT_READY',
                'message': 'Unavailable'
              }
            }),
            503))));
    await expectLater(
        api.depositIntent('intent'),
        throwsA(isA<BusinessApiException>()
            .having((error) => error.code, 'code', 'WALLET_MANUAL_NOT_READY')));
  });

  late ManualWalletApi api;
  late MemoryStore memory;
  late List<http.Request> requests;
  late Map<String, dynamic> response;
  setUp(() async {
    memory = MemoryStore();
    final session = SecureSessionStore(memory);
    await session.saveSession(
        accessToken: token, refreshToken: 'refresh', deviceKey: 'device');
    requests = [];
    response = binding;
    api = ManualWalletApi(BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: session,
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(jsonEncode(response), 200);
        })));
  });

  void contract(String method, String path, [Map<String, dynamic>? body]) {
    final request = requests.last;
    expect(request.method, method);
    expect(request.url.toString(), 'https://business.example/api/v1$path');
    expect(request.headers['authorization'], 'Bearer $token');
    if (body != null) {
      expect(jsonDecode(request.body), body);
      expect(request.headers['idempotency-key'], 'stable-key');
      expect(request.headers['content-type'], 'application/json');
    }
  }

  test('binding status challenge confirm HTTP contracts', () async {
    expect((await api.bindingStatus()).version, 1);
    contract('GET', '/wallet/binding');
    response = challenge;
    expect(
        (await api.createBindingChallenge(
                address: 'target',
                expectedVersion: 0,
                idempotencyKey: 'stable-key'))
            .message,
        'private-challenge');
    contract('POST', '/wallet/binding/challenges',
        {'address': 'target', 'expected_version': 0});
    response = confirmed;
    expect(
        (await api.confirmBinding(
                challengeId: 'challenge',
                signature: 'a' * 130,
                oldSignature: 'b' * 130,
                mfaProof: '123456',
                idempotencyKey: 'stable-key'))
            .version,
        2);
    contract('POST', '/wallet/binding/confirm', {
      'challenge_id': 'challenge',
      'signature': 'a' * 130,
      'old_signature': 'b' * 130,
      'mfa_proof': '123456'
    });
  });

  test('deposit create read preserve exact decimal and caller retry key',
      () async {
    response = intent;
    for (var i = 0; i < 2; i++) {
      final value = await api.createDepositIntent(
          amount: intent['expected_amount'] as String,
          expectedBindingVersion: 1,
          idempotencyKey: 'stable-key');
      expect(value.expectedAmount, intent['expected_amount']);
      expect(value.rules.precision, 6);
      contract('POST', '/wallet/manual/deposit-intents',
          {'amount': intent['expected_amount'], 'expected_binding_version': 1});
    }
    expect(requests[0].body, requests[1].body);
    await api.depositIntent('intent');
    contract('GET', '/wallet/manual/deposit-intents/intent');
  });

  test('payout quote create read cancel HTTP contracts', () async {
    response = quote;
    expect(
        (await api.createPayoutQuote(
                amount: '10.000000',
                expectedBindingVersion: 1,
                idempotencyKey: 'stable-key'))
            .fee,
        '0.000000');
    contract('POST', '/wallet/manual/payout-quotes',
        {'amount': '10.000000', 'expected_binding_version': 1});
    response = payout;
    expect(
        (await api.createPayout(
                quoteId: 'quote',
                mfaProof: '123456',
                idempotencyKey: 'stable-key'))
            .amount,
        '10.000000');
    contract('POST', '/wallet/manual/payouts',
        {'quote_id': 'quote', 'mfa_proof': '123456'});
    await api.payout('order');
    contract('GET', '/wallet/manual/payouts/order');
    await api.cancelPayout('order', idempotencyKey: 'stable-key');
    contract('POST', '/wallet/manual/payouts/order/cancel', {});
  });

  test(
      'MFA contracts and sensitive responses never written to store or toString',
      () async {
    final before = Map<String, String>.from(memory.values);
    response = mfa;
    expect((await api.mfaStatus()).enabled, false);
    contract('GET', '/security/mfa');
    response = enrollment;
    final value = await api.enrollMfa(
        password: 'private-password', idempotencyKey: 'stable-key');
    expect(value.secret, 'PRIVATESECRET');
    expect(value.toString(), isNot(contains('PRIVATESECRET')));
    contract('POST', '/security/mfa/enroll', {'password': 'private-password'});
    response = {'enabled': true};
    expect(
        (await api.enableMfa(
                credentialId: 'credential',
                code: '123456',
                idempotencyKey: 'stable-key'))
            .enabled,
        true);
    contract('POST', '/security/mfa/enable',
        {'credential_id': 'credential', 'code': '123456'});
    response = {'enabled': false};
    await api.abortMfaEnrollment(
        credentialId: 'credential',
        password: 'private-password',
        idempotencyKey: 'stable-key');
    contract('POST', '/security/mfa/abort-pending',
        {'credential_id': 'credential', 'password': 'private-password'});
    expect(memory.values, before);
  });

  test('every required response field including nullable fields fails closed',
      () {
    final parsers =
        <Map<String, dynamic>, Object Function(Map<String, dynamic>)>{
      binding: ManualBindingStatus.fromJson,
      challenge: ManualBindingChallenge.fromJson,
      confirmed: ManualBindingConfirmation.fromJson,
      rules: ManualDepositRules.fromJson,
      intent: ManualDepositIntent.fromJson,
      quote: ManualPayoutQuote.fromJson,
      payout: ManualPayout.fromJson,
      mfa: ManualMfaStatus.fromJson,
      enrollment: ManualMfaEnrollment.fromJson,
      {'enabled': true}: ManualMfaEnabled.fromJson
    };
    for (final entry in parsers.entries) {
      for (final key in entry.key.keys) {
        final broken = Map<String, dynamic>.from(entry.key)..remove(key);
        expect(() => entry.value(broken), throwsFormatException, reason: key);
      }
    }
  });

  test('wrong response types unknown states and numeric money rejected', () {
    expect(() => ManualPayout.fromJson({...payout, 'amount': 10.0}),
        throwsFormatException);
    expect(
        () => ManualPayout.fromJson({...payout, 'status': 'UNKNOWN_NEW_STATE'}),
        throwsFormatException);
    expect(() => ManualBindingStatus.fromJson({...binding, 'version': 1.0}),
        throwsFormatException);
    expect(() => ManualMfaStatus.fromJson({...mfa, 'enabled': 'true'}),
        throwsFormatException);
    expect(
        () => ManualBindingChallenge.fromJson(
            {...challenge, 'expires_at': 'tomorrow'}),
        throwsFormatException);
    expect(() => ManualDepositRules.fromJson({...rules, 'precision': 7}),
        throwsFormatException);
    expect(
        () => ManualBindingStatus.fromJson(
            {...binding, 'rebind_interval_days': 31}),
        throwsFormatException);
    expect(
        () => ManualPayoutQuote.fromJson(
            {...quote, 'finality_policy': 'OTHER_POLICY'}),
        throwsFormatException);
    expect(() => ManualPayout.fromJson({...payout, 'digest': 'not-a-digest'}),
        throwsFormatException);
  });

  test('invalid amounts versions keys and path identifiers never dispatched',
      () async {
    for (final amount in [
      '10',
      '10.0',
      '1e1',
      'NaN',
      '-10.000000',
      '01.000000',
      '10.0000001'
    ]) {
      await expectLater(
          api.createDepositIntent(
              amount: amount,
              expectedBindingVersion: 1,
              idempotencyKey: 'stable-key'),
          throwsArgumentError);
    }
    await expectLater(
        api.createPayoutQuote(
            amount: '10.000000',
            expectedBindingVersion: 0,
            idempotencyKey: 'stable-key'),
        throwsArgumentError);
    await expectLater(
        api.cancelPayout('order', idempotencyKey: ''), throwsArgumentError);
    await expectLater(api.payout('../binding'), throwsArgumentError);
    expect(requests, isEmpty);
  });
}
