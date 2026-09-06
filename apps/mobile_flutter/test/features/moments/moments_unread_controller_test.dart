import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/moments/moments_unread_controller.dart';

void main() {
  test('failed scan preserves badge and in-flight displayed IDs stay consumed',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var phase = 0;
    final gate = Completer<Map<String, dynamic>>();
    final tracker = MomentsUnreadController(
        accountKey: 'A',
        preferences: prefs,
        load: ({String? since, String? cursor}) async {
          if (phase == 2) throw StateError('offline');
          if (phase == 3) return gate.future;
          return {
            'server_time': '2026-09-06T12:00:00Z',
            'items': phase == 0
                ? []
                : [
                    {'id': 'a'}
                  ]
          };
        });
    await tracker.initialize();
    phase = 1;
    await tracker.refresh();
    phase = 2;
    await tracker.refresh();
    expect(tracker.count, 1);
    phase = 3;
    final refresh = tracker.refresh();
    await tracker.markDisplayed(['a']);
    gate.complete({
      'server_time': '2026-09-06T12:00:01Z',
      'items': [
        {'id': 'a'},
        {'id': 'b'}
      ]
    });
    await refresh;
    expect(tracker.count, 1);
    tracker.dispose();
  });
  test('baseline, pages, display and account isolation preserve newer posts',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var phase = 0;
    Future<Map<String, dynamic>> load({String? since, String? cursor}) async =>
        {
          'server_time': '2026-09-06T12:00:00Z',
          'items': phase == 0
              ? []
              : [
                  {'id': cursor == null ? 'a' : 'b'}
                ],
          'next_cursor': phase > 0 && cursor == null ? 'second' : null,
        };
    final tracker = MomentsUnreadController(
        accountKey: 'A', load: load, preferences: prefs);
    await tracker.initialize();
    expect(tracker.count, 0);
    phase = 1;
    await tracker.refresh();
    expect(tracker.count, 2);
    await tracker.markDisplayed(['a']);
    expect(tracker.count, 1);
    await tracker.refresh();
    expect(tracker.count, 1);
    final restored = MomentsUnreadController(
        accountKey: 'A', load: load, preferences: prefs);
    await restored.initialize();
    expect(restored.count, 1);
    phase = 0;
    final other = MomentsUnreadController(
        accountKey: 'B', load: load, preferences: prefs);
    await other.initialize();
    expect(other.count, 0);
    tracker.dispose();
    restored.dispose();
    other.dispose();
  });
}
