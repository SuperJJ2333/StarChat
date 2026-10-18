import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/optional_projection_refresh.dart';

void main() {
  test('capture failure still repairs display unless owner was revoked',
      () async {
    var repairs = 0;
    var current = true;
    Future<void> capture() async => throw StateError('fixture capture');
    await captureThenRepairProjection(
        capture: capture,
        repair: () async {
          repairs++;
        },
        isCurrent: () => current);
    expect(repairs, 1);
    current = false;
    await captureThenRepairProjection(
        capture: capture,
        repair: () async {
          repairs++;
        },
        isCurrent: () => current);
    expect(repairs, 1);
  });
  test(
      'changed room beyond top forty cannot displace pinned or recent coverage',
      () {
    final ranked = ['pinned', 'draft', ...List.generate(48, (i) => 'recent$i')];
    final baseline = selectProjectionRefreshRooms(ranked, current: 'recent47');
    final changed = selectProjectionRefreshRooms(ranked,
        current: 'recent47', changed: {'recent46', 'recent37'});
    expect(changed.toSet(), baseline.toSet());
    expect(changed, hasLength(40));
    expect(changed.first, 'recent47');
    expect(changed, containsAll(['pinned', 'draft']));
    expect(changed, isNot(contains('recent46')));
  });
  test('burst merges room IDs and full request supersedes scoped requests',
      () async {
    final scopes = <Set<String>?>[];
    final worker = OptionalProjectionRefresh((rooms) async {
      scopes.add(rooms);
    }, delay: Duration.zero);
    final a = worker.request(rooms: {'one'});
    final b = worker.request(rooms: {'two'});
    await Future.wait([a, b]);
    expect(scopes, [
      <String>{'one', 'two'}
    ]);
    await Future.wait([
      worker.request(rooms: {'three'}),
      worker.request()
    ]);
    expect(scopes.last, isNull);
    expect(scopes, hasLength(2));
    worker.close();
  });
  test('requests during capture run once afterward without concurrent writers',
      () async {
    final barrier = Completer<void>();
    final entered = Completer<void>();
    final scopes = <Set<String>?>[];
    var active = 0;
    final worker = OptionalProjectionRefresh((rooms) async {
      expect(++active, 1);
      scopes.add(rooms);
      if (scopes.length == 1) {
        entered.complete();
        await barrier.future;
      }
      active--;
    }, delay: Duration.zero);
    final a = worker.request(rooms: {'one'});
    await entered.future;
    final b = worker.request(rooms: {'two'});
    final c = worker.request(rooms: {'three'});
    barrier.complete();
    await Future.wait([a, b, c]);
    expect(scopes, [
      <String>{'one'},
      <String>{'two', 'three'}
    ]);
    worker.close();
  });
  test('retired optional work never executes and pending callers settle',
      () async {
    var calls = 0;
    final worker = OptionalProjectionRefresh((_) async {
      calls++;
    }, delay: Duration.zero);
    final pending = worker.request(rooms: {'one'});
    worker.close();
    await pending;
    await worker.request();
    expect(calls, 0);
  });
}
