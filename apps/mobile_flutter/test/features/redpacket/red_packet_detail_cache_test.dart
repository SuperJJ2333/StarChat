import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_auth_contracts.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/redpacket/red_packet_claim_detail_page.dart';
import 'package:liuhetong_mobile/features/redpacket/red_packet_controller.dart';
import 'package:liuhetong_mobile/features/redpacket/red_packet_detail_store.dart';

/// 可控成败 + 可控在途（Completer）的明细网关：用于观察"网络还没回来时
/// 屏幕上有什么"。
final class _Gateway implements RedPacketViewGateway {
  _Gateway({this.detail, this.failure});

  Map<String, dynamic>? detail;
  Object? failure;

  /// 非空时 `redPacketDetail` 挂起，直到测试手动 complete。
  Completer<void>? gate;
  final requestedIds = <String>[];

  @override
  Future<Map<String, dynamic>> redPacketDetail(String id) async {
    requestedIds.add(id);
    final pending = gate;
    if (pending != null) await pending.future;
    final error = failure;
    if (error != null) throw error;
    return detail ?? const {};
  }

  @override
  Future<Map<String, dynamic>> claimRedPacket(String id) async => const {};

  @override
  Future<List<ContactSummary>> listContacts() async => const [];
}

/// 带会话 epoch 的网关：epoch 变化代表登录态切换。
final class _SessionGateway implements RedPacketViewGateway, BusinessSessionMonitor {
  _SessionGateway({required this.sessionEpoch, this.detail, this.failure});

  @override
  final int sessionEpoch;
  Map<String, dynamic>? detail;
  Object? failure;

  @override
  Stream<BusinessSessionInvalidation> get sessionInvalidations =>
      const Stream<BusinessSessionInvalidation>.empty();

  @override
  Future<void> checkSessionValidity() async {}

  @override
  Future<Map<String, dynamic>> redPacketDetail(String id) async {
    final error = failure;
    if (error != null) throw error;
    return detail ?? const {};
  }

  @override
  Future<Map<String, dynamic>> claimRedPacket(String id) async => const {};

  @override
  Future<List<ContactSummary>> listContacts() async => const [];
}

Map<String, dynamic> _detail({String id = 'p1', String status = 'COMPLETED'}) =>
    {
      'id': id,
      'status': status,
      'mode': 'RANDOM',
      'share_count': 3,
      'claimed_count': 3,
      'sender_nickname': '小明',
      'claims': [
        {
          'user_id': 'u1',
          'nickname': '小明',
          'username': 'ming',
          'amount': '1.20',
          'claimed_at': '2026-09-19T02:00:00Z',
        },
      ],
    };

void main() {
  setUp(RedPacketDetailStores.reset);
  tearDown(RedPacketDetailStores.reset);

  test('同一会话再次进入：网络还没回来就先渲染上次明细（L1/L2/L3）', () async {
    final store = RedPacketDetailStore();
    final first = _Gateway(detail: _detail());
    final seed = RedPacketController(first, details: store);
    await seed.load('p1');
    expect(store.read('0', 'p1'), isNotNull, reason: '成功加载必须写入会话缓存');
    seed.dispose();

    final slow = _Gateway(detail: _detail(status: 'OPEN'))
      ..gate = Completer<void>();
    final second = RedPacketController(slow, details: store);
    final pending = second.load('p1');

    expect(second.detail?['id'], 'p1', reason: '首帧就有本地明细，不等网络');
    expect(second.loading, isFalse, reason: '有本地数据时不得进整页 loading');
    expect(second.error, isNull);

    slow.gate!.complete();
    await pending;
    expect(second.detail?['status'], 'OPEN', reason: '后台刷新成功后替换为新数据');
    second.dispose();
  });

  test('再次进入但刷新失败：旧明细保留，不落到错误态（L4）', () async {
    final store = RedPacketDetailStore();
    final seed = RedPacketController(_Gateway(detail: _detail()), details: store);
    await seed.load('p1');
    seed.dispose();

    final failing = _Gateway(failure: StateError('offline'));
    final controller = RedPacketController(failing, details: store);
    await controller.load('p1');

    expect(controller.detail?['id'], 'p1', reason: '失败不覆盖已展示的明细');
    expect(controller.error, isNotNull, reason: '失败仍要记录，便于诊断');
    controller.dispose();
  });

  test('不同红包不串用：缓存只按 packetId 命中', () async {
    final store = RedPacketDetailStore();
    final seed = RedPacketController(_Gateway(detail: _detail()), details: store);
    await seed.load('p1');
    seed.dispose();

    final slow = _Gateway(detail: _detail(id: 'p2'))
      ..gate = Completer<void>();
    final controller = RedPacketController(slow, details: store);
    final pending = controller.load('p2');

    expect(controller.detail, isNull, reason: 'p1 的明细绝不能当作 p2 展示');
    expect(controller.loading, isTrue, reason: '没有本地数据时可以显示加载态');

    slow.gate!.complete();
    await pending;
    expect(controller.detail?['id'], 'p2');
    controller.dispose();
  });

  test('会话切换（epoch 变化）：不复用上一个账号的明细', () async {
    final store = RedPacketDetailStore();
    final previous = RedPacketController(
        _SessionGateway(sessionEpoch: 7, detail: _detail()),
        details: store);
    await previous.load('p1');
    expect(store.read('7', 'p1'), isNotNull);
    previous.dispose();

    final current = RedPacketController(
        _SessionGateway(sessionEpoch: 8, failure: StateError('offline')),
        details: store);
    await current.load('p1');

    expect(current.detail, isNull, reason: '换账号后不得展示旧账号的明细');
    expect(store.read('8', 'p1'), isNull);
    current.dispose();
  });

  test('未注入缓存的拆红包弹窗行为不变：仍以服务端为准', () async {
    final store = RedPacketDetailStore();
    final seed = RedPacketController(_Gateway(detail: _detail()), details: store);
    await seed.load('p1');
    seed.dispose();

    final slow = _Gateway(detail: _detail())..gate = Completer<void>();
    final controller = RedPacketController(slow); // 无 details
    final pending = controller.load('p1');

    expect(controller.detail, isNull, reason: '不注入缓存时不得读会话缓存');
    expect(controller.loading, isTrue);

    slow.gate!.complete();
    await pending;
    controller.dispose();
  });

  testWidgets('断网再次进入明细页：直接渲染内容，无加载圈、无重试占位 (L2)',
      (tester) async {
    final seeded = RedPacketController(_Gateway(detail: _detail()),
        details: RedPacketDetailStores.shared);
    await seeded.load('p1');
    seeded.dispose();

    await tester.pumpWidget(CupertinoApp(
      home: RedPacketClaimDetailPage(
        api: _Gateway(failure: StateError('offline')),
        packetId: 'p1',
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('red-packet-claim-detail-page')), findsOneWidget,
        reason: '有会话缓存时首帧就要渲染明细');
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(find.byKey(const Key('red-packet-claim-detail-retry')), findsNothing,
        reason: '失败不得把已展示的明细换成重试占位');
    expect(find.text('红包详情加载失败，请稍后重试'), findsNothing);
  });

  testWidgets('无缓存首次进入且失败：仍是错误页 + 可重试（模型允许的例外）',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: RedPacketClaimDetailPage(
        api: _Gateway(failure: StateError('offline')),
        packetId: 'p9',
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('红包详情加载失败，请稍后重试'), findsOneWidget);
    expect(find.byKey(const Key('red-packet-claim-detail-retry')), findsOneWidget);
  });

  test('会话缓存有上限：超过 maxEntries 淘汰最早写入的明细', () {
    final store = RedPacketDetailStore(maxEntries: 3);
    for (var i = 1; i <= 5; i++) {
      store.write('0', 'p$i', _detail(id: 'p$i'));
    }
    expect(store.entryCount, 3);
    expect(store.read('0', 'p1'), isNull);
    expect(store.read('0', 'p2'), isNull);
    expect(store.read('0', 'p5'), isNotNull);
  });
}
