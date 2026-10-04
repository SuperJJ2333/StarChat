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
}
