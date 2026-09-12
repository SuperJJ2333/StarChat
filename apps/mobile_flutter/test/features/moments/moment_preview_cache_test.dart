import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/moments/moment_preview_cache.dart';

final class _Store implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

Future<BusinessApiClient> _api(
    Future<http.Response> Function(http.Request) handler) async {
  final store = SecureSessionStore(_Store());
  await store.saveSession(
      accessToken: 'e30.eyJzdWIiOiJ1MSJ9.test', refreshToken: 'synthetic');
  return BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: store,
      client: MockClient(handler));
}

http.Response _response(Object value) => http.Response(jsonEncode(value), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('same scope deduplicates in-flight preview reads', () async {
    final pending = Completer<http.Response>();
    var reads = 0;
    final api = await _api((_) async {
      reads++;
      return pending.future;
    });
    final cache = MomentPreviewCache.forApi(api);

    cache.ensureFresh('friend');
    cache.ensureFresh('friend');
    await Future<void>.delayed(Duration.zero);
    expect(reads, 1);

    pending.complete(_response({'entry_visible': true, 'items': []}));
    await Future<void>.delayed(Duration.zero);
    expect(cache.peek('friend')?['entry_visible'], true);
  });

  test('late old-epoch preview cannot publish after local session replacement',
      () async {
    final pending = Completer<http.Response>();
    final api = await _api((_) async => pending.future);
    final oldScope = MomentPreviewCache.forApi(api);
    oldScope.ensureFresh('friend');
    await Future<void>.delayed(Duration.zero);

    await api.clearLocalSession();
    final newScope = MomentPreviewCache.forApi(api);
    expect(identical(oldScope, newScope), isFalse);
    pending.complete(_response({'entry_visible': true, 'items': []}));
    await Future<void>.delayed(Duration.zero);

    expect(oldScope.peek('friend'), isNull);
    expect(newScope.peek('friend'), isNull);
  });

  test('known authorization denial evicts a same-scope cached grant',
      () async {
    var reads = 0;
    final api = await _api((_) async => http.Response(
        ++reads == 1
            ? jsonEncode({'entry_visible': true, 'items': []})
            : jsonEncode({'message': 'forbidden'}),
        reads == 1 ? 200 : 403,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    final cache = MomentPreviewCache.forApi(api, ttl: Duration.zero);

    cache.ensureFresh('friend');
    await Future<void>.delayed(Duration.zero);
    expect(cache.peek('friend')?['entry_visible'], true);
    cache.ensureFresh('friend');
    await Future<void>.delayed(Duration.zero);

    expect(cache.peek('friend'), isNull);
  });
}
