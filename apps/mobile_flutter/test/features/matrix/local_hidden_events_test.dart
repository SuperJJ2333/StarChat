import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/local_hidden_events.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('clear cutoff hides backfilled history and preserves newer messages',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final store = SharedPreferencesLocalHiddenEvents(
      preferences: preferences,
      accountId: 'alice-device',
    );
    final cutoff = DateTime.utc(2026, 9, 10, 12);
    await store.clearThrough('room', cutoff);
    final events = [
      (id: 'old-unloaded', at: cutoff.subtract(const Duration(days: 2))),
      (id: 'boundary', at: cutoff),
      (id: 'new', at: cutoff.add(const Duration(milliseconds: 1))),
      (id: 'explicit-hidden', at: cutoff.add(const Duration(seconds: 1))),
    ];
    await store.hide('room', 'explicit-hidden');
    final visible = store.visibleItems('room', events,
        eventId: (item) => item.id, eventTimestamp: (item) => item.at);
    expect(visible.map((item) => item.id), ['new']);
    expect(events, hasLength(4));
  });

  test('clear cutoff persists monotonically within account and room scope',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final store = SharedPreferencesLocalHiddenEvents(
      preferences: preferences,
      accountId: 'alice-device',
    );
    final cutoff = DateTime.utc(2026, 9, 10, 12);
    await store.clearThrough('room', cutoff);
    await store.clearThrough('room', cutoff.subtract(const Duration(days: 1)));
    final restored = SharedPreferencesLocalHiddenEvents(
      preferences: preferences,
      accountId: 'alice-device',
    );
    final otherAccount = SharedPreferencesLocalHiddenEvents(
      preferences: preferences,
      accountId: 'bob-device',
    );
    expect(restored.clearedThrough('room'), cutoff);
    expect(restored.clearedThrough('other-room'), isNull);
    expect(otherAccount.clearedThrough('room'), isNull);
    expect(
        restored.isEventHidden('room', 'old', eventTimestamp: cutoff), isTrue);
    expect(otherAccount.isEventHidden('room', 'old', eventTimestamp: cutoff),
        isFalse);
    expect(preferences.getKeys().single, isNot(contains('alice-device')));
    expect(preferences.get(preferences.getKeys().single),
        cutoff.millisecondsSinceEpoch);
  });

  test('delete hides an event only for the current account and device',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final alice = SharedPreferencesLocalHiddenEvents(
      preferences: preferences,
      accountId: '@alice:example.test',
    );
    final bob = SharedPreferencesLocalHiddenEvents(
      preferences: preferences,
      accountId: '@bob:example.test',
    );

    await alice.hide('!room:example.test', r'$event');

    expect(alice.isHidden('!room:example.test', r'$event'), isTrue);
    expect(bob.isHidden('!room:example.test', r'$event'), isFalse);
  });

  test('hidden ids survive reconstruction without storing message content',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final first = SharedPreferencesLocalHiddenEvents(
      preferences: preferences,
      accountId: '@alice:example.test',
    );
    await first.hide('!room:example.test', r'$event');

    final restored = SharedPreferencesLocalHiddenEvents(
      preferences: preferences,
      accountId: '@alice:example.test',
    );

    expect(restored.isHidden('!room:example.test', r'$event'), isTrue);
    expect(preferences.getKeys().single, isNot(contains('message')));
  });

  test('visibleItems removes locally hidden events without mutating input',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final hidden = SharedPreferencesLocalHiddenEvents(
      preferences: preferences,
      accountId: '@alice:example.test',
    );
    final events = [
      (id: r'$first', body: '一'),
      (id: r'$second', body: '二'),
    ];
    await hidden.hide('!room:example.test', r'$first');

    final visible = hidden.visibleItems(
      'room:example.test'.replaceFirst('room', '!room'),
      events,
      eventId: (event) => event.id,
    );

    expect(visible.map((event) => event.id), [r'$second']);
    expect(events, hasLength(2));
  });
}
