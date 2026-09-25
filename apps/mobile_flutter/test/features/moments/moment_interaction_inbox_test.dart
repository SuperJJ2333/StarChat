import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/moments/moment_interaction_inbox_page.dart';
import 'package:liuhetong_mobile/features/moments/moment_models.dart';

class _Store implements SecureKeyValueStore {
  final values = <String, String>{};
  bool failReads = false;
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async {
    if (failReads) throw StateError('secure store unavailable');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

Future<BusinessApiClient> _api(
    Future<http.Response> Function(http.Request) handler,
    {_Store? store}) async {
  final session = SecureSessionStore(store ?? _Store());
  await session.saveSession(
      accessToken: 'e30.eyJzdWIiOiJ1MSJ9.test', refreshToken: 'synthetic');
  return BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: session,
      client: MockClient(handler));
}

http.Response _json(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> _row({String id = 'n1', String? commentId = 'c1'}) => {
      'id': id,
      'moment_id': 'm1',
      'comment_id': commentId,
      'kind': 'REPLY',
      'actor': {
        'user_id': 'u2',
        'username': 'bob',
        'display_name': 'Bob',
      },
      'content_excerpt': '你好',
      'source_excerpt': '我的动态',
      'target_available': true,
      'created_at': '2026-09-24T00:00:00Z',
      'read_at': null,
    };

Map<String, dynamic> _moment() => {
      'id': 'm1',
      'author': {'user_id': 'u1', 'username': 'alice'},
      'text': '我的动态',
      'image_urls': <String>[],
      'created_at': '2026-09-24T00:00:00Z',
      'comments': [
        {
          'id': 'c1',
          'text': '你好',
          'author': {'user_id': 'u2', 'username': 'bob'},
        }
      ],
    };

void main() {
  test('notification DTO keeps generic historical row private', () {
    final visible = MomentNotificationItem.fromJson(_row());
    expect(visible.commentId, 'c1');
    expect(visible.contentExcerpt, '你好');
    final hidden = MomentNotificationItem.fromJson({
      ..._row(),
      'actor': null,
      'content_excerpt': null,
      'source_excerpt': null,
      'target_available': false,
    });
    expect(hidden.actor, isNull);
    expect(hidden.targetAvailable, isFalse);
  });

  test('gateway sends cursor and read IDs with the server contract', () async {
    final requests = <http.Request>[];
    final api = await _api((request) async {
      requests.add(request);
      if (request.method == 'GET') {
        return _json({
          'items': [_row()],
          'next_cursor': null
        });
      }
      return http.Response('', 204);
    });
    final page = await api.momentNotifications(limit: 2, cursor: 'next');
    expect(page['items'], hasLength(1));
    expect(
        requests.first.url.queryParameters, {'limit': '2', 'cursor': 'next'});
    await api.markMomentNotificationsRead(['n1']);
    expect(jsonDecode(requests.last.body), ['n1']);
  });

  testWidgets('inbox paginates, uses distinct wording, and marks loaded rows',
      (tester) async {
    final paths = <String>[];
    var changed = 0;
    final api = await _api((request) async {
      paths.add('${request.method} ${request.url}');
      if (request.method == 'POST') return http.Response('', 204);
      if (request.url.queryParameters.containsKey('cursor')) {
        return _json({
          'items': [_row(id: 'n2')],
          'next_cursor': null
        });
      }
      return _json({
        'items': [_row()],
        'next_cursor': 'second'
      });
    });
    await tester.pumpWidget(CupertinoApp(
        home: MomentInteractionInboxPage(
            api: api, onNotificationsChanged: () => changed++)));
    await tester.pumpAndSettle();
    expect(find.text('全部互动消息'), findsOneWidget);
    expect(find.textContaining('回复'), findsWidgets);
    expect(find.text('你好'), findsOneWidget);
    expect(find.text('我的动态'), findsOneWidget);
    expect(changed, 1);
    await tester.tap(find.byKey(const Key('moment-notifications-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('moment-notification-n2')), findsOneWidget);
    expect(changed, 2);
    expect(paths.where((path) => path.contains('cursor=second')), hasLength(1));
  });

  testWidgets('retained inaccessible rows keep type without private excerpts',
      (tester) async {
    final api = await _api((request) async {
      if (request.method == 'POST') return http.Response('', 204);
      return _json({
        'items': [
          for (final kind in ['COMMENT', 'REPLY', 'LIKE'])
            {
              ..._row(id: kind),
              'kind': kind,
              'actor': null,
              'content_excerpt': null,
              'source_excerpt': null,
              'target_available': false,
            }
        ],
        'next_cursor': null,
      });
    });
    await tester
        .pumpWidget(CupertinoApp(home: MomentInteractionInboxPage(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('朋友圈评论提醒'), findsOneWidget);
    expect(find.text('朋友圈回复提醒'), findsOneWidget);
    expect(find.text('朋友圈点赞提醒'), findsOneWidget);
    expect(find.text('该内容不可查看'), findsNWidgets(3));
    expect(find.text('你好'), findsNothing);
    expect(find.text('我的动态'), findsNothing);
  });

  testWidgets('inbox shows empty and retry states', (tester) async {
    var failing = true;
    final api = await _api((request) async => failing
        ? _json({
            'error': {'code': 'UNAVAILABLE'}
          }, 503)
        : _json({'items': <Object>[], 'next_cursor': null}));
    await tester
        .pumpWidget(CupertinoApp(home: MomentInteractionInboxPage(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('互动消息加载失败，请重试'), findsOneWidget);
    failing = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('暂无互动消息'), findsOneWidget);
  });

  testWidgets('unavailable target is checked before detail route is pushed',
      (tester) async {
    final api = await _api((request) async {
      if (request.method == 'POST') return http.Response('', 204);
      if (request.url.path.endsWith('/moments/m1')) {
        return _json({
          'error': {'code': 'MOMENT_NOT_FOUND'}
        }, 404);
      }
      return _json({
        'items': [_row()],
        'next_cursor': null
      });
    });
    await tester
        .pumpWidget(CupertinoApp(home: MomentInteractionInboxPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-notification-n1')));
    await tester.pumpAndSettle();
    expect(find.text('该内容不可查看'), findsOneWidget);
    expect(find.byKey(const Key('moment-detail-page')), findsNothing);
  });

  testWidgets('a secure-store read failure during open stays on the inbox',
      (tester) async {
    final store = _Store();
    final api = await _api((request) async {
      if (request.method == 'POST') return http.Response('', 204);
      return _json({
        'items': [_row()],
        'next_cursor': null
      });
    }, store: store);
    await tester
        .pumpWidget(CupertinoApp(home: MomentInteractionInboxPage(api: api)));
    await tester.pumpAndSettle();
    store.failReads = true;
    await tester.tap(find.byKey(const Key('moment-notification-n1')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('moment-detail-page')), findsNothing);
  });

  testWidgets('authorized target opens and highlights the triggering comment',
      (tester) async {
    final api = await _api((request) async {
      if (request.method == 'POST') return http.Response('', 204);
      if (request.url.path.endsWith('/moments/m1')) return _json(_moment());
      return _json({
        'items': [_row()],
        'next_cursor': null
      });
    });
    await tester
        .pumpWidget(CupertinoApp(home: MomentInteractionInboxPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-notification-n1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('moment-detail-page')), findsOneWidget);
    expect(find.byKey(const Key('moment-comment-surface-c1')), findsOneWidget);
  });

  testWidgets('deep reply is scrolled into view after authorized detail opens',
      (tester) async {
    final detail = _moment();
    detail['comments'] = List.generate(
        30,
        (index) => {
              'id': 'c$index',
              'text': 'comment $index',
              'author': {'user_id': 'u2', 'username': 'bob'},
            });
    final api = await _api((request) async {
      if (request.method == 'POST') return http.Response('', 204);
      if (request.url.path.endsWith('/moments/m1')) return _json(detail);
      return _json({
        'items': [_row(commentId: 'c29')],
        'next_cursor': null,
      });
    });
    await tester
        .pumpWidget(CupertinoApp(home: MomentInteractionInboxPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moment-notification-n1')));
    await tester.pumpAndSettle();
    final highlighted = find.byKey(const Key('moment-comment-surface-c29'));
    expect(highlighted, findsOneWidget);
    expect(tester.getTopLeft(highlighted).dy, lessThan(600));
  });

  testWidgets('account loss discards a late notification page', (tester) async {
    final delayed = Completer<http.Response>();
    final api = await _api((request) async => delayed.future);
    await tester
        .pumpWidget(CupertinoApp(home: MomentInteractionInboxPage(api: api)));
    await tester.pump();
    await api.clearLocalSession();
    delayed.complete(_json({
      'items': [_row()],
      'next_cursor': null
    }));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.byKey(const Key('moment-notification-n1')), findsNothing);
    expect(find.text('请重新登录后查看互动消息'), findsOneWidget);
  });
}
