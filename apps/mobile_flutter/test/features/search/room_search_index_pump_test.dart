import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/search/room_search_index_pump.dart';

RoomMessageViewModel row(String id,
        {String? text,
        bool recalled = false,
        bool echo = false,
        bool flash = false}) =>
    RoomMessageViewModel(
      id: id,
      senderId: 'sender',
      text: text ?? 'body $id',
      isOwn: false,
      timestamp: DateTime.utc(2026),
      deliveryState: RoomDeliveryState.sent,
      isRecalled: recalled,
      isSdkLocalEcho: echo,
      isFlashPhoto: flash,
    );

void main() {
  testWidgets('off-window recall supersedes failed old write on source replay',
      (tester) async {
    var source = [row('x')];
    var fail = true;
    final saved = <String, String>{};
    final pump = RoomSearchIndexPump(
        source: () => source,
        isActive: () => true,
        upsert: (rows) {
          if (fail) throw StateError('synthetic');
          for (final row in rows) {
            saved[row.id] = row.text;
          }
        },
        remove: (ids) {
          for (final id in ids) {
            saved.remove(id);
          }
        });
    pump.request([]);
    await tester.pump(const Duration(milliseconds: 1));
    source = [row('x', recalled: true)];
    pump.request([]);
    fail = false;
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(saved, isEmpty);
    pump.dispose();
  });
  testWidgets('authoritative source recovers overflow with bounded queues',
      (tester) async {
    var fail = true;
    final source = <RoomMessageViewModel>[];
    final saved = <String, String>{'recalled': 'old'};
    final pump = RoomSearchIndexPump(
        source: () => List.of(source),
        isActive: () => true,
        maxPendingIds: 4,
        upsert: (rows) {
          if (fail) throw StateError('synthetic');
          for (final row in rows) {
            saved[row.id] = row.text;
          }
        },
        remove: (ids) {
          for (final id in ids) {
            saved.remove(id);
          }
        });
    for (var i = 0; i < 50; i++) {
      final next = row('live-$i');
      source.add(next);
      pump.request([next]);
      await tester.pump(const Duration(milliseconds: 1));
      expect(pump.pendingCount, lessThanOrEqualTo(4));
      expect(pump.overrideCount, lessThanOrEqualTo(4 + 64));
    }
    source.add(row('recalled', recalled: true));
    pump.request([source.last]);
    fail = false;
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(saved.keys, containsAll(List.generate(50, (i) => 'live-$i')));
    expect(saved.containsKey('recalled'), isFalse);
    pump.dispose();
  });

  testWidgets('source failure retries a fresh iterator without another request',
      (tester) async {
    var fail = true;
    final saved = <String>[];
    final pump = RoomSearchIndexPump(
        source: () {
          if (fail) throw StateError('synthetic source');
          return [row('restored')];
        },
        isActive: () => true,
        upsert: (rows) => saved.addAll(rows.map((r) => r.id)),
        remove: (_) {});
    pump.request([]);
    await tester.pump(const Duration(milliseconds: 1));
    fail = false;
    await tester.pump(const Duration(seconds: 1));
    expect(saved, ['restored']);
    pump.dispose();
  });
  testWidgets('bursts retain every batch and yield before scanning history',
      (tester) async {
    var reads = 0;
    final source = List.generate(300, (i) => row('history-$i'));
    Iterable<RoomMessageViewModel> history() sync* {
      for (final value in source) {
        reads++;
        yield value;
      }
    }

    final saved = <String, String>{};
    final pump = RoomSearchIndexPump(
      source: history,
      isActive: () => true,
      upsert: (rows) {
        for (final r in rows) {
          saved[r.id] = r.text;
        }
      },
      remove: (ids) {
        for (final id in ids) {
          saved.remove(id);
        }
      },
    );
    pump.request([row('a')]);
    pump.request([row('b')]);
    expect(reads, 0, reason: 'sync notification must not walk history');
    await tester.pump(const Duration(milliseconds: 1));
    expect(saved.keys, containsAll(['a', 'b']));
    expect(reads, lessThanOrEqualTo(64));
    for (var i = 0; i < 20; i++) {
      pump.request([row('live-$i')]);
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(saved.keys, containsAll(source.map((r) => r.id)),
        reason: 'continuous updates must not starve historical slices');
    expect(saved.keys, containsAll(List.generate(20, (i) => 'live-$i')));
    pump.dispose();
  });

  testWidgets(
      'priority recall wins over older snapshot; late content is updated',
      (tester) async {
    final saved = <String, String>{};
    var source = [row('a'), row('b')];
    final pump = RoomSearchIndexPump(
      source: () => source,
      isActive: () => true,
      batchSize: 1,
      upsert: (rows) {
        for (final r in rows) {
          saved[r.id] = r.text;
        }
      },
      remove: (ids) {
        for (final id in ids) {
          saved.remove(id);
        }
      },
    );
    pump.request([]);
    await tester.pump(const Duration(milliseconds: 1));
    source = [row('a'), row('b', recalled: true)];
    pump.request([source.last]);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(saved.containsKey('b'), isFalse);
    pump.request([row('a', text: 'decrypted correction')]);
    await tester.pump(const Duration(milliseconds: 8));
    expect(saved['a'], 'decrypted correction');
    pump.dispose();
  });

  testWidgets('failure retries unacknowledged work and inactive accounts stop',
      (tester) async {
    var active = true;
    var fail = true;
    final saved = <String>[];
    final pump = RoomSearchIndexPump(
      source: () => [],
      isActive: () => active,
      upsert: (rows) {
        if (fail) throw StateError('synthetic');
        saved.addAll(rows.map((r) => r.id));
      },
      remove: (_) {},
    );
    pump.request([row('a')]);
    await tester.pump(const Duration(milliseconds: 1));
    expect(saved, isEmpty);
    fail = false;
    await tester.pump(const Duration(seconds: 1));
    expect(saved, ['a']);
    pump.request([row('b')]);
    active = false;
    await tester.pump(const Duration(seconds: 1));
    expect(saved, ['a']);
    pump.dispose();
  });

  testWidgets('echo and flash are excluded; duplicate refresh does not reindex',
      (tester) async {
    var writes = 0;
    final saved = <String>{};
    final source = [
      row('a'),
      row('echo', echo: true),
      row('flash', flash: true)
    ];
    final pump = RoomSearchIndexPump(
      source: () => source,
      isActive: () => true,
      upsert: (rows) {
        writes++;
        saved.addAll(rows.map((r) => r.id));
      },
      remove: (ids) => saved.removeAll(ids),
    );
    pump.request(source);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(saved, {'a'});
    final before = writes;
    pump.request(source);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(writes, before);
    pump.dispose();
    pump.request([row('late')]);
    await tester.pump(const Duration(seconds: 1));
    expect(saved, {'a'});
  });
}
