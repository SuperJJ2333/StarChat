import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_load_scheduler.dart';

void main() {
  test('active cancellation holds its slot and queued peers stay FIFO',
      () async {
    final scheduler = MediaLoadScheduler(maxConcurrent: 1);
    final gate = Completer<Uint8List>();
    final order = <String>[];
    final active = scheduler.request('active', () => gate.future);
    await Future<void>.delayed(Duration.zero);
    final peers = [
      for (final name in ['first', 'second'])
        scheduler.request(name, () async {
          order.add(name);
          return Uint8List(1);
        })
    ];
    final canceled =
        expectLater(active.value, throwsA(isA<MediaLoadCanceled>()));
    active.cancel();
    await canceled;
    await Future<void>.delayed(Duration.zero);
    expect(order, isEmpty);
    gate.complete(Uint8List(1));
    await Future.wait(peers.map((peer) => peer.value));
    expect(order, ['first', 'second']);
  });
  test('reentrant cancellation cannot start a stale queued snapshot', () async {
    final scheduler = MediaLoadScheduler(maxConcurrent: 2);
    late MediaLoadLease second;
    var secondStarted = false;
    final first = scheduler.request('first', () async {
      second.cancel();
      return Uint8List(1);
    });
    second = scheduler.request('second', () async {
      secondStarted = true;
      return Uint8List(1);
    });
    final canceled =
        expectLater(second.value, throwsA(isA<MediaLoadCanceled>()));
    await first.value;
    await canceled;
    expect(secondStarted, isFalse);
  });

  test('joining visible demand promotes an already queued prefetch', () async {
    final scheduler = MediaLoadScheduler(maxConcurrent: 1);
    final gate = Completer<Uint8List>();
    final order = <String>[];
    final active = scheduler.request('active', () => gate.future);
    await Future<void>.delayed(Duration.zero);
    final older = scheduler.request('older', () async {
      order.add('older');
      return Uint8List(1);
    });
    final prefetch = scheduler.request('prefetch', () async {
      order.add('prefetch');
      return Uint8List(1);
    }, priority: MediaLoadPriority.prefetch);
    scheduler.promote('prefetch', MediaLoadPriority.interactive);
    gate.complete(Uint8List(1));
    await Future.wait([active.value, older.value, prefetch.value]);
    expect(order, ['prefetch', 'older']);
  });

  test('interactive work overtakes prefetch and respects concurrency',
      () async {
    final scheduler = MediaLoadScheduler(maxConcurrent: 1);
    final gate = Completer<Uint8List>();
    final started = <String>[];
    final active = scheduler.request('active', () => gate.future);
    await Future<void>.delayed(Duration.zero);
    final prefetch = scheduler.request('prefetch', () async {
      started.add('prefetch');
      return Uint8List(1);
    }, priority: MediaLoadPriority.prefetch);
    final interactive = scheduler.request('tap', () async {
      started.add('tap');
      return Uint8List(1);
    }, priority: MediaLoadPriority.interactive);
    expect(started, isEmpty);
    gate.complete(Uint8List(1));
    await Future.wait([active.value, prefetch.value, interactive.value]);
    expect(started, ['tap', 'prefetch']);
  });

  test('joined consumers share bytes and one cancellation keeps other alive',
      () async {
    final scheduler = MediaLoadScheduler();
    final gate = Completer<Uint8List>();
    var calls = 0;
    final first = scheduler.request('same', () {
      calls++;
      return gate.future;
    });
    final second =
        scheduler.request('same', () => throw StateError('duplicate'));
    final canceled =
        expectLater(first.value, throwsA(isA<MediaLoadCanceled>()));
    first.cancel();
    gate.complete(Uint8List.fromList([1]));
    await canceled;
    expect(await second.value, [1]);
    expect(calls, 1);
  });

  test('last queued consumer cancels without starting its source', () async {
    final scheduler = MediaLoadScheduler(maxConcurrent: 1);
    final gate = Completer<Uint8List>();
    final active = scheduler.request('active', () => gate.future);
    await Future<void>.delayed(Duration.zero);
    var calls = 0;
    final queued = scheduler.request('queued', () async {
      calls++;
      return Uint8List(1);
    });
    final assertion =
        expectLater(queued.value, throwsA(isA<MediaLoadCanceled>()));
    queued.cancel();
    await assertion;
    gate.complete(Uint8List(1));
    await active.value;
    expect(calls, 0);
  });

  test('videos use one slot while a visible image can proceed', () async {
    final scheduler = MediaLoadScheduler(maxConcurrent: 3, maxVideos: 1);
    final video = Completer<Uint8List>();
    var secondStarted = false;
    final first = scheduler.request('v1', () => video.future, isVideo: true);
    final second = scheduler.request('v2', () async {
      secondStarted = true;
      return Uint8List(1);
    }, isVideo: true);
    final image = scheduler.request('image', () async => Uint8List(1));
    await image.value;
    expect(secondStarted, isFalse);
    video.complete(Uint8List(1));
    await Future.wait([first.value, second.value]);
  });

  test('failed tasks release slots and the key can retry', () async {
    final scheduler = MediaLoadScheduler(maxConcurrent: 1);
    await expectLater(
        scheduler.request('x', () => throw StateError('fail')).value,
        throwsStateError);
    expect(await scheduler.request('x', () async => Uint8List(2)).value,
        hasLength(2));
  });
}
