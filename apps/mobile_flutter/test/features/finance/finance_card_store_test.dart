import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_error.dart';
import 'package:liuhetong_mobile/features/finance/finance_card_store.dart';

void main() {
  test('leases share a notifier but retain independent visibility', () {
    fakeAsync((async) {
      final gateway = _Gateway.immediate();
      final store =
          FinanceCardStore(gateway, refreshPeriod: const Duration(seconds: 1));
      final first = store.lease(FinanceCardKey.redPacket('shared'));
      final second = store.lease(FinanceCardKey.redPacket('shared'));
      expect(identical(first.notifier, second.notifier), isTrue);
      first.setVisible(true);
      second.setVisible(true);
      async.flushMicrotasks();
      first.setVisible(false);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(gateway.redCalls, 2);
      first.dispose();
      second.dispose();
      store.dispose();
    });
  });

  test('a second visible lease joins an inflight detail without discarding it',
      () async {
    final gateway = _Gateway();
    final store = FinanceCardStore(gateway);
    final first = store.lease(FinanceCardKey.redPacket('join'));
    final second = store.lease(FinanceCardKey.redPacket('join'));
    first.setVisible(true);
    await _settle();
    second.setVisible(true);
    gateway.complete('join', value: 'first-response');
    await _settle();
    await _settle();
    expect(gateway.redCalls, 1);
    expect(first.notifier.value.detail?['value'], 'first-response');
    first.dispose();
    second.dispose();
    store.dispose();
  });

  test('only four detail loads run while a fifth remains queued', () async {
    final gateway = _Gateway();
    final store = FinanceCardStore(gateway);
    final leases = List.generate(
        5, (index) => store.lease(FinanceCardKey.redPacket('$index')));
    for (final lease in leases) {
      lease.setVisible(true);
    }
    await _settle();
    expect(gateway.redCalls, 4);
    gateway.complete('0');
    await _settle();
    await _settle();
    expect(gateway.redCalls, 5);
    for (final lease in leases) {
      lease.dispose();
    }
    store.dispose();
  });

  test('leaving view removes a queued load and clears loading', () async {
    final gateway = _Gateway();
    final store = FinanceCardStore(gateway);
    final leases = List.generate(
        5, (index) => store.lease(FinanceCardKey.redPacket('$index')));
    for (final lease in leases) {
      lease.setVisible(true);
    }
    await _settle();
    expect(leases.last.notifier.value.loading, isTrue);
    leases.last.setVisible(false);
    expect(leases.last.notifier.value.loading, isFalse);
    gateway.complete('0');
    await _settle();
    expect(gateway.redCalls, 4);
    for (final lease in leases) {
      lease.dispose();
    }
    store.dispose();
  });

  test('fake time refreshes visible nonterminal cards and stops offscreen', () {
    fakeAsync((async) {
      final gateway = _Gateway.immediate();
      final store = FinanceCardStore(gateway);
      final lease = store.lease(FinanceCardKey.redPacket('timer'));
      lease.setVisible(true);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 15));
      async.flushMicrotasks();
      expect(gateway.redCalls, 2);
      lease.setVisible(false);
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      expect(gateway.redCalls, 2);
      lease.dispose();
      store.dispose();
    });
  });

  test(
      'ensureFresh completes with the actual fetched state without changing visibility',
      () async {
    final gateway = _Gateway();
    final store = FinanceCardStore(gateway);
    final lease = store.lease(FinanceCardKey.redPacket('fresh'));
    final future = lease.ensureFresh();
    await _settle();
    expect(gateway.redCalls, 1);
    gateway.complete('fresh', value: 'authoritative');
    final state = await future;
    expect(state.detail?['value'], 'authoritative');
    await _settle();
    expect(gateway.redCalls, 1);
    lease.dispose();
    store.dispose();
  });

  test(
      'invalidation rejects an inflight response and merges one replacement read',
      () async {
    final gateway = _Gateway();
    final store = FinanceCardStore(gateway);
    final lease = store.lease(FinanceCardKey.redPacket('stale'));
    lease.setVisible(true);
    await _settle();
    store.invalidate(lease.key);
    store.invalidate(lease.key);
    gateway.complete('stale', value: 'old');
    await _settle();
    await _settle();
    expect(gateway.redCalls, 2);
    gateway.complete('stale', value: 'new');
    await _settle();
    expect(lease.notifier.value.detail?['value'], 'new');
    lease.dispose();
    store.dispose();
  });

  test('LRU trims inactive entries after touch and completion', () async {
    final gateway = _Gateway.immediate();
    final store = FinanceCardStore(gateway, maxEntries: 2);
    final a = store.lease(FinanceCardKey.redPacket('a'));
    await a.ensureFresh();
    a.dispose();
    final b = store.lease(FinanceCardKey.redPacket('b'));
    await b.ensureFresh();
    b.dispose();
    final touchA = store.lease(FinanceCardKey.redPacket('a'));
    touchA.dispose();
    final c = store.lease(FinanceCardKey.redPacket('c'));
    await c.ensureFresh();
    c.dispose();
    final againB = store.lease(FinanceCardKey.redPacket('b'));
    await againB.ensureFresh();
    expect(gateway.callsFor('b'), 2);
    againB.dispose();
    store.dispose();
  });

  test('epoch change and session invalidation end old and new leases',
      () async {
    final gateway = _Gateway();
    final store = FinanceCardStore(gateway);
    final old = store.lease(FinanceCardKey.redPacket('old'));
    old.setVisible(true);
    await _settle();
    gateway.sessionEpoch++;
    gateway.complete('old');
    await _settle();
    final fresh = store.lease(FinanceCardKey.redPacket('new'));
    expect(old.notifier.value.ended, isTrue);
    expect(fresh.notifier.value.ended, isTrue);
    old.dispose();
    fresh.dispose();
    store.dispose();
  });

  test('held current user followed by epoch change never requests detail',
      () async {
    final gateway = _LifecycleGateway(holdUser: true);
    final store = FinanceCardStore(gateway);
    final lease = store.lease(FinanceCardKey.redPacket('held'));
    lease.setVisible(true);
    await _settle();
    gateway.sessionEpoch++;
    gateway.user.complete('me');
    await _settle();
    expect(gateway.redCalls, 0);
    expect(lease.notifier.value.ended, isTrue);
    lease.dispose();
    store.dispose();
  });

  test('same epoch invalidation rejects an old response', () async {
    final gateway = _LifecycleGateway();
    final store = FinanceCardStore(gateway);
    final lease = store.lease(FinanceCardKey.redPacket('old'));
    lease.setVisible(true);
    await _settle();
    gateway.invalidations.add(null);
    gateway.red.complete({'id': 'old'});
    await _settle();
    expect(lease.notifier.value.ended, isTrue);
    expect(lease.notifier.value.detail, isNull);
    lease.dispose();
    store.dispose();
  });

  test('detail error with an epoch change ends without scheduling a timer',
      () async {
    var timers = 0;
    await runZoned(() async {
      final gateway = _LifecycleGateway();
      final store = FinanceCardStore(gateway);
      final lease = store.lease(FinanceCardKey.redPacket('error'));
      lease.setVisible(true);
      await _settle();
      final before = timers;
      gateway.sessionEpoch++;
      gateway.red.completeError(StateError('failed'));
      await _settle();
      expect(lease.notifier.value.ended, isTrue);
      expect(timers, before);
      lease.dispose();
      store.dispose();
    }, zoneSpecification: ZoneSpecification(createTimer: (s, p, z, d, c) {
      timers++;
      return p.createTimer(z, d, c);
    }));
  });

  test('disposed lease ignores a pending completion without notification',
      () async {
    final gateway = _LifecycleGateway();
    final store = FinanceCardStore(gateway);
    final lease = store.lease(FinanceCardKey.redPacket('dispose'));
    var notices = 0;
    lease.notifier.addListener(() => notices++);
    lease.setVisible(true);
    await _settle();
    final before = notices;
    store.dispose();
    gateway.red.complete({'id': 'late'});
    await _settle();
    expect(notices, before);
    lease.dispose();
  });

  test('ended lease retry visibility and ensureFresh issue no requests',
      () async {
    final gateway = _LifecycleGateway();
    final store = FinanceCardStore(gateway);
    final lease = store.lease(FinanceCardKey.redPacket('ended'));
    gateway.invalidations.add(null);
    lease.retry();
    lease.setVisible(true);
    await lease.ensureFresh();
    expect(gateway.redCalls, 0);
    expect(lease.notifier.value.ended, isTrue);
    lease.dispose();
    store.dispose();
  });

  test('epoch drift clears cached state and new lease is ended without event',
      () async {
    final gateway = _LifecycleGateway();
    final store = FinanceCardStore(gateway);
    final old = store.lease(FinanceCardKey.redPacket('cached'));
    old.setVisible(true);
    await _settle();
    gateway.red.complete({'id': 'cached'});
    await _settle();
    await _settle();
    gateway.sessionEpoch++;
    final fresh = store.lease(FinanceCardKey.redPacket('new'));
    expect(old.notifier.value.detail, isNull);
    expect(old.notifier.value.ended, isTrue);
    expect(fresh.notifier.value.ended, isTrue);
    old.dispose();
    fresh.dispose();
    store.dispose();
  });

  test('slow detail remains valid until completion then refreshes', () {
    fakeAsync((async) {
      final gateway = _Gateway();
      final store = FinanceCardStore(gateway);
      final lease = store.lease(FinanceCardKey.redPacket('slow'));
      lease.setVisible(true);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      expect(gateway.redCalls, 1);
      gateway.complete('slow');
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 15));
      async.flushMicrotasks();
      expect(gateway.redCalls, 2);
      lease.dispose();
      store.dispose();
    });
  });

  test('typed 403 clears cached detail', () async {
    final gateway = _Gateway();
    final store = FinanceCardStore(gateway);
    final lease = store.lease(FinanceCardKey.redPacket('forbidden'));
    lease.setVisible(true);
    await _settle();
    gateway.complete('forbidden');
    await _settle();
    await _settle();
    store.invalidate(lease.key);
    await _settle();
    await _settle();
    gateway.redError(
        'forbidden',
        const BusinessApiException(
            statusCode: 403, code: 'DENIED', message: 'denied'));
    await _settle();
    await _settle();
    expect(lease.notifier.value.detail, isNull);
    expect(lease.notifier.value.error, '无权查看该状态');
    lease.dispose();
    store.dispose();
  });

  test('an offscreen queued lease can become visible and load again', () async {
    final gateway = _Gateway();
    final store = FinanceCardStore(gateway);
    final leases = List.generate(
        5, (i) => store.lease(FinanceCardKey.redPacket('return-$i')));
    for (final lease in leases) {
      lease.setVisible(true);
    }
    await _settle();
    leases.last.setVisible(false);
    gateway.complete('return-0');
    await _settle();
    await _settle();
    expect(gateway.redCalls, 4);
    leases.last.setVisible(true);
    await _settle();
    expect(gateway.redCalls, 5);
    for (final lease in leases) {
      lease.dispose();
    }
    store.dispose();
  });

  test('concurrent ensureFresh shares one detail and result', () async {
    final gateway = _Gateway();
    final store = FinanceCardStore(gateway);
    final lease = store.lease(FinanceCardKey.redPacket('ensure'));
    final first = lease.ensureFresh();
    final second = lease.ensureFresh();
    await _settle();
    expect(gateway.redCalls, 1);
    gateway.complete('ensure', value: 'same');
    expect((await first).detail?['value'], 'same');
    expect((await second).detail?['value'], 'same');
    lease.dispose();
    store.dispose();
  });

  test('LRU retains touched a but evicts inactive b', () async {
    final gateway = _Gateway.immediate();
    final store = FinanceCardStore(gateway, maxEntries: 2);
    final a = store.lease(FinanceCardKey.redPacket('a'));
    await a.ensureFresh();
    a.dispose();
    final b = store.lease(FinanceCardKey.redPacket('b'));
    await b.ensureFresh();
    b.dispose();
    final touchA = store.lease(FinanceCardKey.redPacket('a'));
    await touchA.ensureFresh(force: false);
    touchA.dispose();
    final c = store.lease(FinanceCardKey.redPacket('c'));
    await c.ensureFresh();
    c.dispose();
    final againA = store.lease(FinanceCardKey.redPacket('a'));
    await againA.ensureFresh(force: false);
    final againB = store.lease(FinanceCardKey.redPacket('b'));
    await againB.ensureFresh(force: false);
    expect(gateway.callsFor('a'), 1);
    expect(gateway.callsFor('b'), 2);
    againA.dispose();
    againB.dispose();
    store.dispose();
  });

  test('terminal cached read does not make offscreen invalidation fetch',
      () async {
    final gateway = _Gateway();
    final store = FinanceCardStore(gateway);
    final lease = store.lease(FinanceCardKey.redPacket('terminal'));
    lease.setVisible(true);
    await _settle();
    gateway.complete('terminal', status: 'COMPLETED');
    await _settle();
    await _settle();
    expect(lease.notifier.value.terminal, isTrue);
    lease.setVisible(false);
    await lease.ensureFresh(force: false);
    store.invalidate(lease.key);
    await _settle();
    expect(gateway.redCalls, 1);
    lease.dispose();
    store.dispose();
  });

  test('completed unowned ensure flights trim immediately after readers finish',
      () async {
    final gateway = _Gateway();
    final store = FinanceCardStore(gateway, maxEntries: 1);
    final a = store.lease(FinanceCardKey.redPacket('trim-a'));
    final first = a.ensureFresh();
    a.dispose();
    final b = store.lease(FinanceCardKey.redPacket('trim-b'));
    final second = b.ensureFresh();
    b.dispose();
    await _settle();
    await _settle();
    expect(store.cacheEntryCount, 2);
    gateway.complete('trim-a');
    await _settle();
    gateway.complete('trim-b');
    await first;
    await second;
    expect(store.cacheEntryCount, 1);
    store.dispose();
  });

  test(
      'offscreen invalidation keeps dirty state for an immediate visible reread',
      () async {
    final gateway = _Gateway();
    final store = FinanceCardStore(gateway);
    final lease = store.lease(FinanceCardKey.redPacket('dirty'));
    lease.setVisible(true);
    await _settle();
    gateway.complete('dirty', value: 'cached');
    await _settle();
    await _settle();
    lease.setVisible(true, force: true);
    await _settle();
    expect(gateway.redCalls, 2);
    store.invalidate(lease.key);
    lease.setVisible(false);
    gateway.complete('dirty', value: 'stale');
    await _settle();
    await _settle();
    expect(lease.notifier.value.detail?['value'], 'cached');
    expect(gateway.redCalls, 2);
    lease.setVisible(true);
    await _settle();
    expect(gateway.redCalls, 3);
    gateway.complete('dirty', status: 'COMPLETED', value: 'fresh');
    await _settle();
    await _settle();
    expect(lease.notifier.value.detail?['value'], 'fresh');
    expect(lease.notifier.value.terminal, isTrue);
    lease.dispose();
    store.dispose();
  });
}

Future<void> _settle() => Future<void>.microtask(() {});

final class _Gateway implements FinanceCardGateway {
  _Gateway() : _immediate = false;
  _Gateway.immediate() : _immediate = true;
  final bool _immediate;
  final invalidations = StreamController<void>.broadcast(sync: true);
  final _pending = <String, List<Completer<Map<String, dynamic>>>>{};
  final _calls = <String, int>{};
  int redCalls = 0;
  @override
  int sessionEpoch = 1;
  @override
  Stream<void> get sessionInvalidations => invalidations.stream;
  @override
  Future<String?> currentUserId() async => 'business-me';
  @override
  Future<Map<String, dynamic>> redPacketDetail(String id) {
    redCalls++;
    _calls[id] = (_calls[id] ?? 0) + 1;
    if (_immediate) return Future.value({'id': id, 'status': 'PENDING'});
    final completer = Completer<Map<String, dynamic>>();
    (_pending[id] ??= []).add(completer);
    return completer.future;
  }

  @override
  Future<Map<String, dynamic>> chatTransferDetail(String id) async =>
      {'id': id, 'status': 'PENDING'};
  void complete(String id,
          {String value = 'value', String status = 'PENDING'}) =>
      _pending[id]!
          .removeAt(0)
          .complete({'id': id, 'status': status, 'value': value});
  void redError(String id, Object error) =>
      _pending[id]!.removeAt(0).completeError(error);
  int callsFor(String id) => _calls[id] ?? 0;
}

final class _LifecycleGateway implements FinanceCardGateway {
  _LifecycleGateway({bool holdUser = false})
      : user = Completer<String?>(),
        red = Completer<Map<String, dynamic>>() {
    if (!holdUser) user.complete('me');
  }
  final invalidations = StreamController<void>.broadcast(sync: true);
  final Completer<String?> user;
  final Completer<Map<String, dynamic>> red;
  int redCalls = 0;
  @override
  int sessionEpoch = 1;
  @override
  Stream<void> get sessionInvalidations => invalidations.stream;
  @override
  Future<String?> currentUserId() => user.future;
  @override
  Future<Map<String, dynamic>> redPacketDetail(String id) {
    redCalls++;
    return red.future;
  }

  @override
  Future<Map<String, dynamic>> chatTransferDetail(String id) async =>
      {'id': id};
}
