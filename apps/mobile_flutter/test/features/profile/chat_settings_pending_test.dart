import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/profile/account_settings_pages.dart';
import '../../core/account_credentials_client_test.dart' show MemoryStore;

void main() {
  late BusinessApiClient api;
  late Completer<http.Response> oldWrite;
  var writes = 0, reads = 0;
  var oldValue = false;
  var expiredToken = false;
  var refreshes = 0;
  setUp(() async {
    oldWrite = Completer<http.Response>();
    writes = 0;
    reads = 0;
    oldValue = false;
    expiredToken = false;
    refreshes = 0;
    final store = SecureSessionStore(MemoryStore());
    await store.saveSession(
        accessToken: 'old', refreshToken: 'r', matrixUserId: '@old:test');
    api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: store,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/login')) {
            return http.Response(
                '{"access_token":"new","refresh_token":"new-r","matrix_user_id":"@new:test"}',
                200);
          }
          if (request.url.path.endsWith('/auth/refresh')) {
            refreshes++;
            return http.Response(
                '{"access_token":"refreshed","refresh_token":"refreshed-r"}',
                200);
          }
          final newer = request.headers['authorization'] == 'Bearer new';
          if (request.method == 'PUT') {
            writes++;
            if (expiredToken &&
                request.headers['authorization'] == 'Bearer old') {
              return http.Response(
                  '{"error":{"code":"ACCESS_TOKEN_EXPIRED","message":"登录已过期"}}',
                  401,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }
            if (!newer) {
              return oldWrite.future;
            }
            return http.Response('{"auto_allow_group_join":false}', 200);
          }
          reads++;
          return http.Response(
              jsonEncode({'auto_allow_group_join': newer ? false : oldValue}),
              200);
        }));
  });
  Future<void> flush(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pumpAndSettle();
  }

  Future<void> startPending(WidgetTester tester) async {
    await tester.pumpWidget(CupertinoApp(home: ChatSettingsPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CupertinoSwitch));
    await flush(tester);
    await tester.pump(const Duration(seconds: 9));
  }

  testWidgets(
      'timeout keeps the switch disabled and rejects a second write until authoritative reconciliation',
      (tester) async {
    await startPending(tester);
    expect(find.text('保存结果待确认'), findsOneWidget);
    expect(
        tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).onChanged,
        isNull);
    expect(api.hasPendingAutoAllowGroupJoinWrite, isTrue);
    await expectLater(
        api.setAutoAllowGroupJoin(false), throwsA(isA<BusinessApiException>()));
    expect(writes, 1);
    oldValue = true;
    oldWrite.complete(http.Response('{"auto_allow_group_join":true}', 200));
    await flush(tester);
    expect(tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).value,
        isTrue);
    expect(
        tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).onChanged,
        isNotNull);
    expect(reads, greaterThan(1));
  });
  testWidgets(
      'returning to chat settings waits for the same API write rather than submitting another',
      (tester) async {
    await startPending(tester);
    await tester.pumpWidget(CupertinoApp(
        home: ChatSettingsPage(key: const Key('reopened'), api: api)));
    await tester.pump(const Duration(seconds: 9));
    expect(find.text('保存结果待确认'), findsOneWidget);
    expect(writes, 1);
    oldValue = true;
    oldWrite.complete(http.Response('{"auto_allow_group_join":true}', 200));
    await flush(tester);
    expect(tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).value,
        isTrue);
    expect(
        tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).onChanged,
        isNotNull);
  });
  testWidgets(
      'an explicit 401 refreshes once and holds the write lock through the actual retried PUT',
      (tester) async {
    expiredToken = true;
    await startPending(tester);
    expect(refreshes, 1);
    expect(writes, 2);
    expect(api.hasPendingAutoAllowGroupJoinWrite, isTrue);
    await expectLater(
        api.setAutoAllowGroupJoin(false), throwsA(isA<BusinessApiException>()));
    oldValue = true;
    oldWrite.complete(http.Response('{"auto_allow_group_join":true}', 200));
    await flush(tester);
    expect((await api.sessionStore.session())!.accessToken, 'refreshed');
    expect(tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).value,
        isTrue);
    expect(api.hasPendingAutoAllowGroupJoinWrite, isFalse);
  });
  testWidgets(
      'late old-session preference settlement cannot overwrite new-session settings',
      (tester) async {
    await startPending(tester);
    await tester.runAsync(() async {
      await api.login(
          username: 'new',
          password: 'new-password-123',
          deviceKey: 'new',
          deviceName: 'test');
    });
    await tester.pumpWidget(CupertinoApp(
        home: ChatSettingsPage(key: const Key('new-account'), api: api)));
    await tester.pumpAndSettle();
    expect(api.hasPendingAutoAllowGroupJoinWrite, isFalse);
    expect(await api.setAutoAllowGroupJoin(false), isFalse);
    oldValue = true;
    oldWrite.complete(http.Response('{"auto_allow_group_join":true}', 200));
    await flush(tester);
    expect((await api.sessionStore.session())!.accessToken, 'new');
    expect(tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).value,
        isFalse);
    expect(writes, 2);
  });
}
