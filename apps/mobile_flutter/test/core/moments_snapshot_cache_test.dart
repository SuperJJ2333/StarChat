import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/cache/cache_repository.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CacheRepository.resetForTest();
  });

  test('concurrent repository lookups share account cache and request ordering',
      () async {
    final repositories = await Future.wait(
        [CacheRepository.instance(), CacheRepository.instance()]);
    expect(repositories[0], same(repositories[1]));
    final a = repositories[0].momentsFor('matrix:@a:test');
    expect(a, same(repositories[1].momentsFor('matrix:@a:test')));
    final older = a.beginRefresh();
    final newer = a.beginRefresh();
    expect(a.isCurrent(older), isFalse);
    expect(a.isCurrent(newer), isTrue);
    await a.save({
      'items': [
        {'id': 'confirmed'}
      ]
    });
    expect(a.isCurrent(newer), isFalse,
        reason: 'Confirmed writes supersede pending reads');
    expect(repositories[0].momentsFor('matrix:@b:test').snapshot, isNull);
  });

  test(
      'feed and cover hydrate synchronously, stay isolated, and clear together',
      () async {
    final repository = await CacheRepository.instance();
    final a = repository.momentsFor('matrix:@a:test');
    final b = repository.momentsFor('matrix:@b:test');
    await a.save({
      'items': [
        {'id': 'a'}
      ]
    });
    await a.savePreferences({'cover_url': 'cover-a'});
    await b.save({
      'items': [
        {'id': 'b'}
      ]
    });
    final snapshot = a.snapshot!;
    (snapshot['items'] as List).clear();
    expect(a.snapshot!['items'], hasLength(1),
        reason: 'Readers cannot mutate shared state');
    await CacheRepository.resetForTest();
    final restarted = await CacheRepository.instance();
    final restored = restarted.momentsFor('matrix:@a:test');
    expect(restored.snapshot!['items'], hasLength(1));
    expect(restored.preferencesSnapshot!['cover_url'], 'cover-a');
    final request = restored.beginRefresh();
    final coverRequest = restored.beginPreferencesRefresh();
    await restored.clear();
    expect(restored.isCurrent(request), isFalse);
    expect(restored.preferencesAreCurrent(coverRequest), isFalse);
    expect(restored.snapshot, isNull);
    expect(restored.preferencesSnapshot, isNull);
    expect(restarted.momentsFor('matrix:@b:test').snapshot!['items'],
        hasLength(1));
  });

  test('profile exposes only its existing immutable account namespace', () {
    final profile = ProfileRepository.forTesting(
        accountKey: 'matrix:@a:test', store: _Store());
    expect(profile.accountKey, 'matrix:@a:test');
    profile.dispose();
  });
}

final class _Store implements ProfileStore {
  @override
  Future<ProfileSnapshot?> read(String accountKey) async => null;
  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) async {}
}
