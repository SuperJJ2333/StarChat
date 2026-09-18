import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/room_navigation_coordinator.dart';
import 'package:liuhetong_mobile/features/matrix/room_open_failure_feedback.dart';
import 'package:liuhetong_mobile/features/matrix/room_opening_policy.dart';
import 'package:liuhetong_mobile/features/matrix/room_visibility_policy.dart';
import 'package:liuhetong_mobile/features/search/global_search_models.dart';
import 'package:liuhetong_mobile/features/search/global_search_page.dart';
import 'package:liuhetong_mobile/features/search/global_search_index.dart';

/// Room Opening Policy Engine 的架构守卫与行为测试。
///
/// 覆盖任务书 §12 的 7 条：
/// 1. RoomPage 创建点仍只有 1 处；
/// 2. 所有入口必须经过 RoomOpeningPolicy；
/// 3. 离线：消息列表打开成功（零网络等待）；
/// 4. 离线：通知打开已有房间成功；失败有可见提示；
/// 5. 离线：搜索历史消息打开成功（anchor 保留）；
/// 6. 网络失败：显示错误，不能 silent；
/// 7. 控制房间：搜索不可见。

/// 可控本地事实探针。
final class _Probe implements RoomOpenLocalProbe {
  _Probe({
    this.joined = const {},
    this.known = const {},
  });

  Set<String> joined;
  Set<String> known;

  @override
  Set<String> controlRoomIds = const {};

  @override
  bool knowsRoom(String roomId) => known.contains(roomId);

  @override
  bool isJoined(String roomId) => joined.contains(roomId);
}

final class _Recorder {
  final navigated = <RoomOpenRequest>[];
  final awaited = <String>[];
  bool awaitResult = true;

  Future<void> navigate(RoomOpenRequest request) async {
    navigated.add(request);
  }

  Future<bool> awaitLocalRoom(String roomId) async {
    awaited.add(roomId);
    return awaitResult;
  }
}

RoomOpenRequest _request(
  String roomId, {
  RoomOpenSource source = RoomOpenSource.conversationList,
  String? anchorEventId,
}) =>
    RoomOpenRequest(
      roomId: roomId,
      roomName: '房间',
      source: source,
      anchorEventId: anchorEventId,
    );

void main() {
  group('Test 1: RoomPage 创建点', () {
    test('生产代码中 RoomPage 构造点仍然只有 1 处（AppHome 协调器流程）', () {
      final lib = Directory('lib');
      final creators = <String>[];
      for (final entity in lib.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync();
        // 只看"构造"（builder: (_) => RoomPage(），不看声明与 re-export。
        if (RegExp(r'=>\s*RoomPage\(').hasMatch(source) ||
            RegExp(r'RoomPage\(\s*\n?\s*api:').hasMatch(source)) {
          creators.add(entity.path.replaceAll(r'\', '/'));
        }
      }
      expect(creators, ['lib/app_home.dart'],
          reason: '唯一 RoomPage 创建点必须在 AppHome（协调器打开流程）');
    });
  });

  group('Test 2: 所有入口经过 RoomOpeningPolicy', () {
    test('组合根只通过策略层打开房间，且不存在第二条打开路径', () {
      final appHome = File('lib/app_home.dart').readAsStringSync();
      expect(appHome, contains('RoomOpeningPolicy('));
      expect(appHome, contains('_roomOpening.open('));
      expect(appHome, contains('probe: _MatrixRoomOpenProbe('));
      // 打开失败只有一个反馈点。
      expect(appHome, contains('showRoomOpenFailureDialog('));
      // 通知/推送/横幅路径不得再有静默吞错。
      final notification = appHome.substring(
        appHome.indexOf('Future<void> _openConversationFromNotification('),
        appHome.indexOf('Widget _contactsBadge('),
      );
      expect(notification, isNot(contains('catch (_) {}')),
          reason: '通知打开失败不允许静默');
      expect(notification, contains('_openManagedRoomRequest('));
    });

    test('所有 RoomOpenRequest 都显式声明来源（source）', () {
      for (final path in const [
        'lib/app_home.dart',
        'lib/features/matrix/matrix_home_page.dart',
      ]) {
        final source = _stripComments(File(path).readAsStringSync());
        final requests =
            RegExp(r'RoomOpenRequest\(([\s\S]*?)\);').allMatches(source);
        expect(requests, isNotEmpty, reason: '$path 应有 RoomOpenRequest');
        for (final match in requests) {
          expect(match.group(1), contains('source:'),
              reason: '$path 的 RoomOpenRequest 必须声明 source');
        }
      }
    });

    test('消息列表与搜索入口不再各自等待同步', () {
      // 只看代码：注释里允许说明"旧实现曾先 waitForJoinedRoom"。
      final home = _stripComments(
          File('lib/features/matrix/matrix_home_page.dart').readAsStringSync());
      final openById = home.substring(
        home.indexOf('Future<void> _openRoomById('),
        home.indexOf('Future<void> _warmChatIdentity('),
      );
      expect(openById, isNot(contains('waitForJoinedRoom')),
          reason: '本地已知的会话必须离线直接打开，不得先等同步');
      expect(openById, contains('RoomOpenSource.search'));
      expect(openById, contains('_rooms.where'),
          reason: '本地会话列表命中即直接打开（离线优先）');
      expect(home, contains('source: RoomOpenSource.scan'),
          reason: '扫码入群入口必须声明来源（策略据此判定 requireNetwork）');
    });

    test('三个 Tab 的搜索都必须注入 onOpenRoom（非 optional）', () {
      final search = File('lib/features/search/global_search_page.dart')
          .readAsStringSync();
      expect(search, contains('required this.onOpenRoom'),
          reason: 'onOpenRoom 必须必填，不允许 optional');
      final contacts = File('lib/features/contacts/contacts_page.dart')
          .readAsStringSync();
      expect(contacts, contains('onOpenRoom: widget.onOpenRoom'));
      final discovery =
          File('lib/features/discovery/discovery_page.dart').readAsStringSync();
      expect(discovery, contains('onOpenRoom: onOpenRoom'));
      final appHome = File('lib/app_home.dart').readAsStringSync();
      expect('onOpenRoom: _openSearchRoom'.allMatches(appHome).length, 2,
          reason: '通讯录与发现两个 Tab 都必须注入统一搜索打开回调');
    });
  });

  group('Test 3: 离线打开消息列表中的已有会话', () {
    test('本地已 joined → 立即打开，零网络等待', () async {
      final probe = _Probe(joined: {'!room:test'}, known: {'!room:test'});
      final policy = RoomOpeningPolicy(probe: probe);
      final recorder = _Recorder();

      await policy.open(
        _request('!room:test', source: RoomOpenSource.conversationList),
        navigate: recorder.navigate,
        awaitLocalRoom: recorder.awaitLocalRoom,
      );

      expect(recorder.navigated.single.roomId, '!room:test');
      expect(recorder.awaited, isEmpty,
          reason: '离线优先：本地已加入的房间绝不调用网络等待');
      expect(policy.evaluate(_request('!room:test')).reason, 'local_joined');
    });
  });

  group('Test 4: 离线打开通知里的已有房间', () {
    test('notification = localThenNetwork，但本地命中仍然零等待', () async {
      final probe = _Probe(joined: {'!dm:test'}, known: {'!dm:test'});
      final policy = RoomOpeningPolicy(probe: probe);
      final recorder = _Recorder();

      await policy.open(
        _request('!dm:test', source: RoomOpenSource.notification),
        navigate: recorder.navigate,
        awaitLocalRoom: recorder.awaitLocalRoom,
      );

      expect(recorder.navigated, hasLength(1));
      expect(recorder.awaited, isEmpty, reason: '本地已有房间不得先等 10 秒同步');
    });

    test('本地未知 → 有界等待一次，等到后打开', () async {
      final probe = _Probe();
      final policy = RoomOpeningPolicy(probe: probe);
      final recorder = _Recorder();

      await policy.open(
        _request('!dm:test', source: RoomOpenSource.notification),
        navigate: recorder.navigate,
        awaitLocalRoom: recorder.awaitLocalRoom,
      );

      expect(recorder.awaited, ['!dm:test']);
      expect(recorder.navigated, hasLength(1));
    });

    test('等待超时 → 抛出可重试失败（绝不静默）', () async {
      final probe = _Probe();
      final policy = RoomOpeningPolicy(probe: probe);
      final recorder = _Recorder()..awaitResult = false;

      await expectLater(
        policy.open(
          _request('!dm:test', source: RoomOpenSource.notification),
          navigate: recorder.navigate,
          awaitLocalRoom: recorder.awaitLocalRoom,
        ),
        throwsA(isA<RoomOpenFailure>()
            .having((f) => f.kind, 'kind',
                RoomOpenFailureKind.temporaryFailure)
            .having((f) => f.userMessage, 'message', '无法打开会话，请检查网络')),
      );
      expect(recorder.navigated, isEmpty);
    });
  });

  group('Test 5: 离线打开搜索命中的历史消息', () {
    test('search = offlineFirst：本地命中直接打开并保留 anchor', () async {
      final probe = _Probe(joined: {'!group:test'}, known: {'!group:test'});
      final policy = RoomOpeningPolicy(probe: probe);
      final recorder = _Recorder();

      await policy.open(
        _request('!group:test',
            source: RoomOpenSource.search, anchorEventId: r'$event:test'),
        navigate: recorder.navigate,
        awaitLocalRoom: recorder.awaitLocalRoom,
      );

      expect(recorder.awaited, isEmpty);
      expect(recorder.navigated.single.anchorEventId, r'$event:test');
      expect(recorder.navigated.single.source, RoomOpenSource.search);
    });

    test('本地未加入（仅已知）→ 立即打开，不再等一次网络同步', () async {
      final probe = _Probe(known: {'!group:test'});
      final policy = RoomOpeningPolicy(probe: probe);
      final recorder = _Recorder();

      await policy.open(
        _request('!group:test', source: RoomOpenSource.search),
        navigate: recorder.navigate,
        awaitLocalRoom: recorder.awaitLocalRoom,
      );

      // Offline First（2026-09-18）：房间已在本地库 → 零网络等待立即进入；
      // 成员/加密状态由页面在后台刷新。有界等待只保留给本地完全未知的房间。
      expect(recorder.awaited, isEmpty,
          reason: '本地已知的房间绝不等待网络同步');
      expect(recorder.navigated, hasLength(1));
    });
  });

  group('Test 6: 失败必须可见，不能 silent', () {
    test('每个失败分类都有非空且不含敏感信息的用户文案', () {
      for (final kind in RoomOpenFailureKind.values) {
        final failure = RoomOpenFailure(kind,
            roomId: '!room:test', source: RoomOpenSource.notification);
        expect(failure.userMessage.trim(), isNotEmpty);
        expect(failure.userMessage, isNot(contains('!room:test')));
      }
      expect(
        const RoomOpenFailure(RoomOpenFailureKind.offline,
                roomId: '!r:t', source: RoomOpenSource.search)
            .userMessage,
        '网络不可用，请稍后重试',
      );
    });

    testWidgets('失败通过统一对话框对用户可见', (tester) async {
      var shown = false;
      await tester.pumpWidget(CupertinoApp(
        home: Builder(
          builder: (context) => CupertinoButton(
            onPressed: () async {
              shown = true;
              await showRoomOpenFailureDialog(
                context,
                const RoomOpenFailure(RoomOpenFailureKind.networkUnavailable,
                    roomId: '!room:test', source: RoomOpenSource.notification),
              );
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(shown, isTrue);
      expect(find.byKey(const Key('room-open-failure')), findsOneWidget);
      expect(find.text('网络不可用，请稍后重试'), findsOneWidget);
    });

    test('本地打开失败（房间不可用）也被分类为可见失败', () async {
      final policy = RoomOpeningPolicy(
          probe: _Probe(joined: {'!room:test'}, known: {'!room:test'}));
      await expectLater(
        policy.open(
          _request('!room:test'),
          navigate: (_) async =>
              throw StateError('Matrix room is unavailable'),
          awaitLocalRoom: (_) async => true,
        ),
        throwsA(isA<RoomOpenFailure>().having((f) => f.kind, 'kind',
            RoomOpenFailureKind.roomNotFound)),
      );
    });

    test('可重试分类覆盖"刚入群/刚同步"的场景，不留死胡同', () {
      const notJoined = RoomOpenFailure(RoomOpenFailureKind.notJoined,
          roomId: '!r:test', source: RoomOpenSource.scan);
      expect(notJoined.isRetryable, isTrue,
          reason: '刚入群时房间可能还没同步到本地，必须允许重试');
      const missing = RoomOpenFailure(RoomOpenFailureKind.roomNotFound,
          roomId: '!r:test', source: RoomOpenSource.search);
      expect(missing.isRetryable, isFalse, reason: '会话不存在时不应引导重复尝试');
      const denied = RoomOpenFailure(RoomOpenFailureKind.permissionDenied,
          roomId: '!r:test', source: RoomOpenSource.search);
      expect(denied.isRetryable, isFalse);
    });

    testWidgets('可重试失败给出「重试」按钮并回传 true（组合根据此重跑同一请求）',
        (tester) async {
      bool? retried;
      await tester.pumpWidget(CupertinoApp(
        home: Builder(
          builder: (context) => CupertinoButton(
            onPressed: () async {
              retried = await showRoomOpenFailureDialog(
                context,
                const RoomOpenFailure(RoomOpenFailureKind.notJoined,
                    roomId: '!room:test', source: RoomOpenSource.scan),
              );
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('尚未加入该会话，请稍后重试'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(retried, isTrue);
    });

    testWidgets('不可重试失败只给「知道了」', (tester) async {
      bool? retried;
      await tester.pumpWidget(CupertinoApp(
        home: Builder(
          builder: (context) => CupertinoButton(
            onPressed: () async {
              retried = await showRoomOpenFailureDialog(
                context,
                const RoomOpenFailure(RoomOpenFailureKind.roomNotFound,
                    roomId: '!room:test', source: RoomOpenSource.search),
              );
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('重试'), findsNothing);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(retried, isFalse);
    });
  });

  group('Test 7: 控制房间在搜索中不可见', () {    testWidgets('控制房间不进搜索结果，普通群聊仍可打开', (tester) async {
      final store = SecureSessionStore(_MemoryStore());
      await store.saveSession(accessToken: 'a', refreshToken: 'r');
      final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.test'),
        sessionStore: store,
        client: MockClient((_) async => http.Response('{"items":[]}', 200,
            headers: {'content-type': 'application/json'})),
      );
      final opened = <String>[];
      await tester.pumpWidget(CupertinoApp(
        home: GlobalSearchPage(
          api: api,
          index: GlobalSearchIndex(),
          debounce: Duration.zero,
          contactsLoader: () async => const [],
          roomsLoader: () async => const [
            GlobalSearchRoomResult(
                roomId: '!vault:test', displayName: '项目仓库', isDirect: false),
            GlobalSearchRoomResult(
                roomId: '!group:test', displayName: '项目群', isDirect: false),
          ],
          visibility: RoomVisibilityPolicy.forRoomIds(const ['!vault:test']),
          onOpenRoom: (room, {anchorEventId}) async {
            opened.add(room.roomId);
          },
        ),
      ));
      await tester.enterText(find.byType(CupertinoSearchTextField), '项目');
      await tester.pumpAndSettle();

      expect(find.text('项目群'), findsOneWidget);
      expect(find.text('项目仓库'), findsNothing, reason: '控制房间必须在搜索中不可见');

      await tester.tap(find.text('项目群'));
      await tester.pumpAndSettle();
      expect(opened, ['!group:test']);
    });
  });

  group('Test 8: 架构债守卫（审计 B 组）', () {
    test('控制房间身份只来自 roomId/accountData/会话登记，且创建即登记', () {
      final registry =
          File('lib/features/matrix/control_room_registry.dart').readAsStringSync();
      expect(registry, contains('class ControlRoomRegistry'));
      expect(registry, contains('static void register('));
      // 会话登记必须真正参与可见性判定（否则窗口期补不上）。
      final resolver =
          File('lib/features/matrix/matrix_control_rooms.dart').readAsStringSync();
      expect(resolver, contains('ControlRoomRegistry.sessionRoomIds'));
      // 两个控制房间的创建方都必须登记。
      final vault = File('lib/features/matrix/matrix_e2ee_client.dart')
          .readAsStringSync();
      expect(vault, contains('ControlRoomRegistry.register(roomId)'));
      final reminders = File(
              'lib/features/matrix/matrix_message_reminder_backend.dart')
          .readAsStringSync();
      expect(reminders, contains('ControlRoomRegistry.register'));
      // 登出/清库必须清理账号级登记。
      expect(vault, contains('ControlRoomRegistry.clear()'));
    });

    test('休眠的 legacy 私聊创建面不得被生产代码调用', () {
      final lib = Directory('lib');
      // 只把**真正绕过仲裁的入口**当 legacy：
      // - 构造旧服务/旧网关；
      // - 客户端上那个无 canonical 仲裁的便捷方法（带点调用）。
      // 注意 `openOrCreateDirectChat` 本身是 DirectChatGateway 的接口方法名，
      // 三个网关都实现它，因此不作为 legacy 标记。
      const legacyMarkers = <String>[
        'DirectChatService(',
        'CanonicalDirectChatGateway(',
        '.openOrCreateDirectChat(',
        'openOrCreateViaGateway(',
      ];
      const definitionSites = <String>[
        'direct_chat_controller.dart',
        'direct_chat_service.dart',
        'matrix_e2ee_client.dart',
      ];
      final offenders = <String>[];
      for (final entity in lib.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final path = entity.path.replaceAll(r'\', '/');
        if (definitionSites.any(path.endsWith)) continue;
        final code = _stripComments(entity.readAsStringSync());
        for (final marker in legacyMarkers) {
          if (code.contains(marker)) offenders.add('$path → $marker');
        }
      }
      expect(offenders, isEmpty,
          reason: 'legacy 私聊创建面只能存在于定义处，生产入口一律走 '
              'DirectChatController + CoordinatedDirectChatGateway：$offenders');
      // 生产组合根必须使用带跨设备仲裁的网关。
      final appHome = _stripComments(File('lib/app_home.dart').readAsStringSync());
      expect(appHome, contains('CoordinatedDirectChatGateway('));
      expect(appHome, isNot(contains('DirectChatService(')));
      expect(appHome, isNot(contains('CanonicalDirectChatGateway(')));
    });

    test('好友通过的生产接线必须走带请求上下文的编排（回退仅测试用）', () {
      final appHome = _stripComments(File('lib/app_home.dart').readAsStringSync());
      expect(appHome, contains('onEstablishDirectChatWithRequest:'));
      expect(appHome, contains('_establishDirectChatAndGreet'));
      final contacts = File('lib/features/contacts/contacts_page.dart')
          .readAsStringSync();
      // 旧回退必须标注为测试专用，避免被生产复用为"第二套建私聊实现"。
      expect(contacts, contains('@visibleForTesting'));
      expect(contacts, contains('onEstablishDirectChat ??'));
    });

    test('会话状态只有一个真相源：作用域栈由打开流程驱动，不由页面维护', () {
      final roomPage =
          _stripComments(File('lib/features/matrix/room_page.dart').readAsStringSync());
      expect(roomPage, isNot(contains('StatisticsRoomScope.enter')),
          reason: 'RoomPage 不得再自行维护会话作用域栈');
      expect(roomPage, isNot(contains('StatisticsRoomScope.leave')));
      final appHome =
          _stripComments(File('lib/app_home.dart').readAsStringSync());
      final route = appHome.substring(
        appHome.indexOf('Future<void> _openManagedRoomRoute('),
        appHome.indexOf('void _scanFromTab()'),
      );
      expect(route, contains('StatisticsRoomScope.enter(roomId)'));
      expect(route, contains('StatisticsRoomScope.leave(roomId)'));
    });

    test('打开失败反馈是 single-flight、可重试、且等待有上限与可见进度', () {
      final appHome =
          _stripComments(File('lib/app_home.dart').readAsStringSync());
      expect(appHome, contains('_roomOpenFailureVisible'));
      expect(appHome, contains('if (_roomOpenFailureVisible) return;'));
      expect(appHome, contains('if (retry && mounted)'));
      // 等待上限从 12 秒收紧，并且等待期间有可见进度。
      expect(appHome, contains('_roomOpenWaitTimeout = Duration(seconds: 5)'));
      expect(appHome, contains('room-open-waiting'));
      final feedback = File('lib/features/matrix/room_open_failure_feedback.dart')
          .readAsStringSync();
      expect(feedback, contains('failure.isRetryable'));
      expect(feedback, contains("'重试'"));
    });
  });
}

final class _MemoryStore implements SecureKeyValueStore {
  @override
  Future<void> delete(String key) async {}
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
}

/// 去掉行注释与块注释：守卫测试必须区分"注释里的历史说明"与"代码里的行为"。
String _stripComments(String source) {
  final withoutBlock = source.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  return withoutBlock
      .split('\n')
      .map((line) {
        final index = line.indexOf('//');
        return index == -1 ? line : line.substring(0, index);
      })
      .join('\n');
}
