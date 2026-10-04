import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/matrix/search_media_resolver.dart';

RoomMessageViewModel media(String id,
        {bool flash = false,
        bool recalled = false,
        RoomMessageKind kind = RoomMessageKind.image}) =>
    RoomMessageViewModel(
        id: id,
        senderId: '@synthetic:test',
        text: '',
        isOwn: false,
        deliveryState: RoomDeliveryState.sent,
        timestamp: DateTime(2026),
        kind: kind,
        isFlashPhoto: flash,
        isRecalled: recalled);

void main() {
  test(
      'visible requests are bounded, shared with taps, and source-hinted before lookup',
      () async {
    final gates = <String, Completer<RoomMessageViewModel?>>{};
    final hints = <String>[];
    final resolver = SearchMediaResolver(
        sourceOf: (_) => '!retained:test',
        isVisible: (_) => true,
        isActive: () => true,
        hintSource: (id, source) async {
          expect(source, '!retained:test');
          hints.add(id);
        },
        lookup: (id) {
          expect(hints, contains(id));
          return (gates[id] = Completer()).future;
        });
    final first = resolver.resolve('0');
    expect(identical(first, resolver.resolve('0')), isTrue);
    final pending = [first, for (var i = 1; i < 8; i++) resolver.resolve('$i')];
    await Future<void>.delayed(Duration.zero);
    expect(gates.length, 4);
    for (var i = 0; i < 8; i++) {
      gates['$i']!.complete(media('$i'));
      await Future<void>.delayed(Duration.zero);
    }
    expect((await Future.wait(pending)).every((m) => m != null), isTrue);
  });
  for (final reason in ['hidden', 'revoked', 'new search', 'source changed']) {
    test('rejects late $reason result', () async {
      var visible = true, active = true;
      var source = '!retained:test';
      final gate = Completer<RoomMessageViewModel?>();
      final resolver = SearchMediaResolver(
          sourceOf: (_) => source,
          isVisible: (_) => visible,
          isActive: () => active,
          hintSource: (_, __) async {},
          lookup: (_) => gate.future);
      final pending = resolver.resolve('event');
      await Future<void>.delayed(Duration.zero);
      switch (reason) {
        case 'hidden':
          visible = false;
        case 'revoked':
          active = false;
        case 'new search':
          resolver.invalidate();
        case 'source changed':
          source = '!other:test';
      }
      gate.complete(media('event'));
      expect(await pending, isNull);
    });
  }
  for (final invalid in [
    media('other'),
    media('event', flash: true),
    media('event', recalled: true),
    media('event', kind: RoomMessageKind.text)
  ]) {
    test(
        'rejects invalid SDK media ${invalid.id}/${invalid.kind}/${invalid.isFlashPhoto}/${invalid.isRecalled}',
        () async {
      final resolver = SearchMediaResolver(
          sourceOf: (_) => '!retained:test',
          isVisible: (_) => true,
          isActive: () => true,
          hintSource: (_, __) async {},
          lookup: (_) async => invalid);
      expect(await resolver.resolve('event'), isNull);
    });
  }
  test(
      'missing key or failed lookup can retry without retaining a failed flight',
      () async {
    var calls = 0;
    final resolver = SearchMediaResolver(
        sourceOf: (_) => '!retained:test',
        isVisible: (_) => true,
        isActive: () => true,
        hintSource: (_, __) async {},
        lookup: (id) async {
          calls++;
          if (calls == 1) throw StateError('temporary unavailable');
          if (calls == 2) return null;
          return media(id);
        });
    await expectLater(resolver.resolve('event'), throwsStateError);
    expect(await resolver.resolve('event'), isNull);
    expect((await resolver.resolve('event'))?.id, 'event');
    expect(calls, 3);
  });
  test('missing or rejected source never reaches SDK lookup', () async {
    var source = null as String?;
    var calls = 0;
    final resolver = SearchMediaResolver(
        sourceOf: (_) => source,
        isVisible: (_) => true,
        isActive: () => true,
        hintSource: (_, __) async => throw StateError('unassociated source'),
        lookup: (_) async {
          calls++;
          return null;
        });
    expect(await resolver.resolve('event'), isNull);
    source = '!foreign:test';
    await expectLater(resolver.resolve('event'), throwsStateError);
    expect(calls, 0);
  });
  test('invalidation releases queued consumers before active reads settle',
      () async {
    final gates = <Completer<RoomMessageViewModel?>>[];
    final resolver = SearchMediaResolver(
        sourceOf: (_) => '!retained:test',
        isVisible: (_) => true,
        isActive: () => true,
        hintSource: (_, __) async {},
        lookup: (_) {
          final gate = Completer<RoomMessageViewModel?>();
          gates.add(gate);
          return gate.future;
        });
    final running = [for (var i = 0; i < 4; i++) resolver.resolve('$i')];
    final queued = resolver.resolve('queued');
    await Future<void>.delayed(Duration.zero);
    resolver.invalidate();
    expect(await queued, isNull);
    expect(gates.length, 4);
    for (final gate in gates) {
      gate.complete(media('event'));
    }
    expect(await Future.wait(running), everyElement(isNull));
  });
  test(
      'disposed queued tile releases promptly while shared tap and visible demand progress',
      () async {
    final gates = <String, Completer<RoomMessageViewModel?>>{};
    var running = 0, maximum = 0;
    final resolver = SearchMediaResolver(
        sourceOf: (_) => '!retained:test',
        isVisible: (_) => true,
        isActive: () => true,
        hintSource: (_, __) async {},
        lookup: (id) async {
          running++;
          if (running > maximum) maximum = running;
          try {
            return await (gates[id] = Completer()).future;
          } finally {
            running--;
          }
        });
    final held = [for (var i = 0; i < 4; i++) resolver.resolve('held-$i')];
    await Future<void>.delayed(Duration.zero);
    final abandonedDemand = SearchMediaDemand();
    final tappedDemand = SearchMediaDemand();
    final currentDemand = SearchMediaDemand();
    final abandoned = resolver.resolve('abandoned', demand: abandonedDemand);
    final tapped = resolver.resolve('tapped', demand: tappedDemand);
    expect(identical(tapped, resolver.resolve('tapped')), isTrue);
    final current = resolver.resolve('current', demand: currentDemand);
    abandonedDemand.release();
    tappedDemand.release();
    expect(await abandoned, isNull);
    expect(gates.keys, isNot(contains('abandoned')));
    expect(gates.length, 4);
    for (var i = 0; i < 4; i++) {
      gates['held-$i']!.complete(media('held-$i'));
    }
    await Future.wait(held);
    await Future<void>.delayed(Duration.zero);
    expect(gates.keys, containsAll(['tapped', 'current']));
    expect(gates.keys, isNot(contains('abandoned')));
    gates['tapped']!.complete(media('tapped'));
    gates['current']!.complete(media('current'));
    expect((await tapped)?.id, 'tapped');
    expect((await current)?.id, 'current');
    expect(maximum, 4);
    currentDemand.release();
  });
  test('scroll churn settles discarded queues without waiting for held reads',
      () async {
    final gates = <Completer<RoomMessageViewModel?>>[];
    final resolver = SearchMediaResolver(
        sourceOf: (_) => '!retained:test',
        isVisible: (_) => true,
        isActive: () => true,
        hintSource: (_, __) async {},
        lookup: (_) {
          final gate = Completer<RoomMessageViewModel?>();
          gates.add(gate);
          return gate.future;
        });
    final running = [for (var i = 0; i < 4; i++) resolver.resolve('held-$i')];
    await Future<void>.delayed(Duration.zero);
    for (var i = 0; i < 500; i++) {
      final demand = SearchMediaDemand();
      final discarded = resolver.resolve('scrolled-$i', demand: demand);
      demand.release();
      expect(await discarded, isNull);
    }
    expect(gates.length, 4);
    final oldDemand = SearchMediaDemand();
    final old = resolver.resolve('reentered', demand: oldDemand);
    oldDemand.release();
    final fresh = resolver.resolve('reentered');
    expect(identical(old, fresh), isFalse);
    expect(await old, isNull);
    for (final gate in gates.toList()) {
      gate.complete(null);
    }
    await Future.wait(running);
    await Future<void>.delayed(Duration.zero);
    expect(gates.length, 5);
    gates.last.complete(media('reentered'));
    expect((await fresh)?.id, 'reentered');
  });
  test(
      'releasing an admitted consumer keeps the real read unsettled and shareable',
      () async {
    final gate = Completer<RoomMessageViewModel?>();
    var calls = 0, settled = false;
    final resolver = SearchMediaResolver(
        sourceOf: (_) => '!retained:test',
        isVisible: (_) => true,
        isActive: () => true,
        hintSource: (_, __) async {},
        lookup: (_) {
          calls++;
          return gate.future;
        });
    final demand = SearchMediaDemand();
    final pending = resolver.resolve('event', demand: demand);
    unawaited(pending.then((_) {
      settled = true;
    }));
    await Future<void>.delayed(Duration.zero);
    demand.release();
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    expect(identical(pending, resolver.resolve('event')), isTrue);
    gate.complete(media('event'));
    expect((await pending)?.id, 'event');
    expect(calls, 1);
  });
}
