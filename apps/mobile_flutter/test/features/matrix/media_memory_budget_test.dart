import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/media_memory_budget.dart';

void main() {
  test('global clear invalidates pending room loads and isolates accounts',
      () async {
    final budget = MediaMemoryBudget();
    final a = MediaMemoryCache(budget: budget, accountNamespace: 'a');
    final b = MediaMemoryCache(budget: budget, accountNamespace: 'b');
    final bytes = a.put('a', Uint8List.fromList([1]));
    expect(b.put('b', Uint8List.fromList([1])), isNot(same(bytes)));
    final pending = Completer<Uint8List>();
    final loading = a.putIfAbsent('pending', () => pending.future);
    budget.clear();
    pending.complete(Uint8List.fromList([2]));
    await loading;
    expect(a.get('pending'), isNull);
    expect(budget.totalBytes, 0);
  });
  test('rooms and media kinds share one byte entity and global eviction budget',
      () {
    final budget = MediaMemoryBudget(maxBytes: 6, maxEntries: 8);
    final a = MediaMemoryCache(budget: budget, accountNamespace: 'account');
    final b = MediaMemoryCache(budget: budget, accountNamespace: 'account');
    final first = a.put('room-a-image', Uint8List.fromList([1, 2, 3]));
    final repeated = b.put('room-b-video', Uint8List.fromList([1, 2, 3]));
    expect(repeated, same(first));
    expect(budget.totalBytes, 3);
    b.put('other', Uint8List.fromList([4, 5, 6]));
    a.get('room-a-image');
    b.put('new', Uint8List.fromList([7, 8, 9]));
    expect(budget.totalBytes, 6);
    expect(b.get('other'), isNull);
    expect(a.get('room-a-image'), same(first));
    a.clear();
    b.clear();
    expect(budget.totalBytes, 0);
    expect(budget.entryCount, 0);
  });

  test('shared entry limits bound aliases even for identical tiny media', () {
    final budget = MediaMemoryBudget(maxBytes: 100, maxEntries: 2);
    final cache = MediaMemoryCache(budget: budget);
    for (var i = 0; i < 100; i++) {
      cache.put('$i', Uint8List.fromList([1]));
    }
    expect(budget.totalBytes, 1);
    expect(budget.entryCount, 2);
    expect(cache.get('0'), isNull);
    expect(cache.get('99'), isNotNull);
  });
}
