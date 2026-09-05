import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/local_hidden_events.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
