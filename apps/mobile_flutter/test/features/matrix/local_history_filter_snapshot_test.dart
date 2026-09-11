import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/local_hidden_events.dart';

void main() {
  test('one filter snapshots deletion and cutoff without crossing accounts',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final alice = SharedPreferencesLocalHiddenEvents(
        preferences: prefs, accountId: 'alice');
    final bob = SharedPreferencesLocalHiddenEvents(
        preferences: prefs, accountId: 'bob');
    final now = DateTime.utc(2026, 9, 11);
    final before = alice.readFilter('room');
    await alice.hide('room', 'event');
    await alice.clearThrough('room', now);
    final after = alice.readFilter('room');
    expect(before('event', now), isFalse);
    expect(after('event', now.add(const Duration(seconds: 1))), isTrue);
    expect(after('old', now), isTrue);
    expect(after('new', now.add(const Duration(seconds: 1))), isFalse);
    expect(after('new', now.add(const Duration(microseconds: 1))), isFalse);
    expect(bob.readFilter('room')('event', now), isFalse);
    expect(alice.readFilter('other')('event', now), isFalse);
  });
}
