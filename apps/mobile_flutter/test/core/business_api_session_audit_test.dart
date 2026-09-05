import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

/// 审计 A03：鉴权/登出与会话代数。
///
/// 关键不变量：登出后，在途刷新的**迟到结果不得恢复已清除的会话**
/// （取消后不能用迟到结果恢复已退出会话）。
final class MemoryStore implements SecureKeyValueStore {
  final _data = <String, String>{};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

http.Response _json(Object body, {int status = 200}) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  test('A03：登出后迟到的刷新响应不恢复会话（AUTH_SESSION_ENDED）',
      () async {
    final store = SecureSessionStore(MemoryStore());
    await store.saveSession(accessToken: 'access', refreshToken: 'refresh-r1');
    var logoutHappened = false;
    final client = BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: store,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth/refresh')) {
          // 刷新响应到达前，用户已登出（代数已失效）。
          while (!logoutHappened) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          return _json({'access_token': 'late-access', 'refresh_token': 'late-refresh'});
        }
        if (request.url.path.endsWith('/auth/logout')) {
          logoutHappened = true;
          return _json({});
        }
        return _json({});
      }),
    );

    final restoring = client.restoreSession();
    // 等刷新请求已在途（确定性时序）。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // 触发登出（使会话代数失效）。
    await client.logout();
    expect(await store.session(), isNull, reason: '登出必清本地会话');
    // 迟到的刷新结果：不得把 late-* 写回会话存储。
    final outcome = await restoring.catchError((_) => 'error');
    expect(outcome, anyOf(isA<BusinessSessionRestore>(), 'error'));
    expect(await store.session(), isNull,
        reason: '迟到刷新不得恢复已注销会话（A03 取消语义）');
  });

  test('A03：登出请求超时不阻塞本地清理（确定完成时限）', () async {
    final store = SecureSessionStore(MemoryStore());
    await store.saveSession(accessToken: 'access', refreshToken: 'refresh-r1');
    final client = BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: store,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth/logout')) {
          // 服务器悬挂（超过 8s 超时界）。
          await Completer<void>().future;
        }
        return _json({});
      }),
    );
    final started = DateTime.now();
    await client.logout();
    expect(DateTime.now().difference(started).inSeconds, lessThan(30),
        reason: '登出必须在超时边界内完成本地清理');
    expect(await store.session(), isNull, reason: '退出请求失败也必须清除会话');
  });
}
