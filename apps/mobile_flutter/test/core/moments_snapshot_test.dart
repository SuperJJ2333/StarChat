import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/cache/cache_repository.dart';

void main() {
  test(
      'Android cover hydrates revision cache and confirmed writes stay coherent',
      () async {
    final key = CacheRepository.momentsFeedKeyFor('alice');
    SharedPreferences.setMockInitialValues({
      '$key.cover': 'android-cover',
      '$key.cover-key': 'android-digest',
    });
    await CacheRepository.resetForTest();
    final repository = await CacheRepository.instance();
    final cache = repository.momentsFor('alice');
    expect(cache.preferencesSnapshot?['cover_url'], 'android-cover');
    expect(cache.preferencesSnapshot?['cover_cache_key'], 'android-digest');
    await cache.savePreferences(
        {'cover_url': 'ios-cover', 'cover_cache_key': 'ios-digest'});
    expect(CacheRepository.peekMomentCover('alice'), 'ios-cover');
    expect(CacheRepository.peekMomentCoverKey('alice'), 'ios-digest');
    final ticket = cache.beginPreferencesRefresh();
    await repository.saveMomentCover('alice', 'confirmed',
        cacheKey: 'confirmed-digest');
    expect(cache.preferencesAreCurrent(ticket), isFalse);
    expect(cache.preferencesSnapshot?['cover_url'], 'confirmed');
    final generation = CacheRepository.momentsGeneration('alice');
    final writing = repository.saveMomentCover('alice', 'queued',
        expectedGeneration: generation);
    final clearing = cache.clear();
    await Future.wait([writing, clearing]);
    expect(cache.preferencesSnapshot, isNull);
    expect(CacheRepository.peekMomentCover('alice'), isNull);
    expect(CacheRepository.peekMomentCoverKey('alice'), isNull);
  });

  test('late feed and cover responses cannot repopulate a cleared account',
      () async {
    SharedPreferences.setMockInitialValues({});
    await CacheRepository.resetForTest();
    final repository = await CacheRepository.instance();
    final generation = CacheRepository.momentsGeneration('alice');
    await repository.momentsFor('alice').clear();
    await repository.momentsFor('alice').save({
      'items': ['late']
    }, expectedGeneration: generation);
    await repository.saveMomentCover('alice', 'https://example.com/late',
        expectedGeneration: generation);
    expect(CacheRepository.peekMoments('alice'), isNull);
    expect(CacheRepository.peekMomentCover('alice'), isNull);
  });
  test('feed snapshot is synchronous on reentry and isolated by account',
      () async {
    SharedPreferences.setMockInitialValues({});
    await CacheRepository.resetForTest();
    final repository = await CacheRepository.instance();
    final cache = repository.momentsFor('matrix:a');
    await cache.save({
      'items': [
        {'id': 'one'}
      ]
    });
    expect(CacheRepository.peekMoments('matrix:a')?['items'], isNotEmpty);
    expect(CacheRepository.peekMoments('matrix:b'), isNull);
    await cache.clear();
    expect(CacheRepository.peekMoments('matrix:a'), isNull);
  });
}
