import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

final class _Memory implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

String _token() =>
    'x.${base64Url.encode(utf8.encode(jsonEncode({'sub': 'alice'})))}.x';

Future<BusinessApiClient> _api(List<http.Request> requests) async {
  final store = SecureSessionStore(_Memory());
  await store.saveSession(accessToken: _token(), refreshToken: 'refresh');
  return BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: store,
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
            '{"items":[{"id":"bill","amount":"12.34"}],"next_cursor":null}',
            200);
      }));
}

void main() {
  test('ledger list encodes filters in UTC without coercing amount strings',
      () async {
    final requests = <http.Request>[];
    final api = await _api(requests);
    final result = await api.ledgerTransactions(
        kind: 'transfer',
        q: '红包%&+',
        startAt: DateTime.parse('2026-09-11T08:00:00+08:00'),
        endAt: DateTime.parse('2026-09-12T08:00:00+08:00'),
        cursor: 'next+/=',
        limit: 17);
    final uri = requests.single.url;
    expect(requests.single.method, 'GET');
    expect(uri.path, '/api/v1/ledger/transactions/me');
    expect(uri.queryParameters, {
      'kind': 'transfer',
      'q': '红包%&+',
      'start_at': '2026-09-11T00:00:00.000Z',
      'end_at': '2026-09-12T00:00:00.000Z',
      'cursor': 'next+/=',
      'limit': '17'
    });
    expect(result['items'][0]['amount'], isA<String>());
    expect(result['items'][0]['amount'], '12.34');
  });

  test('ledger list uses only default limit and detail encodes opaque id',
      () async {
    final requests = <http.Request>[];
    final api = await _api(requests);
    await api.ledgerTransactions();
    await api.ledgerTransactionDetail('bill id/%?next=1');
    expect(requests[0].url.queryParameters, {'limit': '50'});
    expect(requests[1].url.path,
        '/api/v1/ledger/transactions/me/bill%20id%2F%25%3Fnext%3D1');
    expect(requests[1].url.query, isEmpty);
  });
}
