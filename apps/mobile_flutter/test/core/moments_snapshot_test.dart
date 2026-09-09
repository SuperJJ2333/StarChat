import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/cache/cache_repository.dart';

void main() {
  test('late feed and cover responses cannot repopulate a cleared account', () async {
    SharedPreferences.setMockInitialValues({});
    await CacheRepository.resetForTest();
    final repository = await CacheRepository.instance();
    final generation = CacheRepository.momentsGeneration('alice');
    await repository.momentsFor('alice').clear();
    await repository.momentsFor('alice').save({'items': ['late']}, expectedGeneration: generation);
    await repository.saveMomentCover('alice', 'https://example.com/late', expectedGeneration: generation);
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
