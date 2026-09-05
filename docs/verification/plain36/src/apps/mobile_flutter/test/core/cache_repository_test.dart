import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/cache/cache_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    CacheRepository.resetForTest();
  });

  test('moments cache: save → load roundtrip（首绘无需等待网络）', () async {
    final cache = (await CacheRepository.instance()).momentsFor("matrix:@u:test");
    await cache.save({
      'items': [
        {'id': 'm1', 'text': '第一条'},
        {'id': 'm2', 'text': '第二条'},
      ],
      'next_cursor': null,
    });
    final loaded = await cache.load();
    expect(loaded, isNotNull);
    expect((loaded!['items'] as List).length, 2);
    expect(loaded['items'][0]['id'], 'm1');
  });

  test('moments cache: no snapshot returns null（首次进入等待网络）', () async {
    final cache = (await CacheRepository.instance()).momentsFor("matrix:@u:test");
    expect(await cache.load(), isNull);
  });

  test('moments cache: corrupted snapshot treated as no cache', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(CacheRepository.momentsFeedKeyFor("matrix:@u:test"), "{broken-json");
    final cache = (await CacheRepository.instance()).momentsFor("matrix:@u:test");
    expect(await cache.load(), isNull);
  });

  test('moments cache: clear removes snapshot', () async {
    final cache = (await CacheRepository.instance()).momentsFor("matrix:@u:test");
    await cache.save({'items': []});
    await cache.clear();
    expect(await cache.load(), isNull);
  });

  test('avatar cache key follows avatar:{userId}:{avatarVersion}', () {
    const cache = AvatarCache();
    expect(cache.cacheKey('user-1', 'v7'), 'avatar:user-1:v7');
  });
}
