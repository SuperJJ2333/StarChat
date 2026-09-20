import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/finance/finance_card_store.dart';

final class _FakeGateway implements FinanceCardGateway {
  _FakeGateway();
  int redPacketCalls = 0;
  int transferCalls = 0;
  final invalidations = StreamController<void>.broadcast();
  Map<String, dynamic> detail = {
    'status': 'PENDING',
    'total': '1.00',
    'server_time': '2026-09-20T00:00:00Z',
    'expires_at': '2099-01-01T00:00:00Z',
  };

  @override
  int get sessionEpoch => 1;
  @override
  Stream<void> get sessionInvalidations => invalidations.stream;
  @override
  Future<String?> currentUserId() async => '@viewer:test';
  @override
  Future<Map<String, dynamic>> redPacketDetail(String id) async {
    redPacketCalls++;
    return detail;
  }

  @override
  Future<Map<String, dynamic>> chatTransferDetail(String id) async {
    transferCalls++;
    return detail;
  }
}

Future<void> _pump() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('E2：同一会话内跨房间复用缓存——第二次进入不再重新拉取、无 loading 闪烁',
      () async {
    final gateway = _FakeGateway();
    // 第一个"房间页"：解析共享 store 并查看红包卡片。
    final first = sessionFinanceCardStore(() => gateway);
    final lease = first.lease(const FinanceCardKey.redPacket('rp-1'));
    lease.setVisible(true);
    await lease.ensureFresh(force: true);
    await _pump();
    expect(lease.notifier.value.hasData, isTrue);
    expect(gateway.redPacketCalls, 1);
    lease.setVisible(false);
    lease.dispose();

    // 第二个"房间页"：同样解析共享 store——必须是同一实例、命中缓存。
    final second = sessionFinanceCardStore(() => gateway);
    expect(identical(first, second), isTrue,
        reason: '每次进入房间都重建 store 会让缓存清零（闪烁根因）');
    final lease2 = second.lease(const FinanceCardKey.redPacket('rp-1'));
    lease2.setVisible(true);
    await _pump();
    expect(gateway.redPacketCalls, 1,
        reason: '缓存未过期时不得重新请求');
    expect(lease2.notifier.value.loading, isFalse,
        reason: '命中缓存立即出数据，不得闪 loading');
    expect(lease2.notifier.value.hasData, isTrue);
    lease2.setVisible(false);
    lease2.dispose();
    second.dispose();
  });

  test('E2：会话失效后按新会话重建（登出/换号是唯一缓存清零边界）', () async {
    final gateway = _FakeGateway();
    final first = sessionFinanceCardStore(() => gateway);
    gateway.invalidations.add(null); // 401/登出 → 旧 store 终结
    await _pump();
    expect(first.isEnded, isTrue);

    final second = sessionFinanceCardStore(() => gateway);
    expect(identical(first, second), isFalse, reason: '终结后必须重建，不得复用死缓存');
    expect(second.isEnded, isFalse);
    second.dispose();
  });
}
