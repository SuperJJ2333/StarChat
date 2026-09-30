import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/foundation/avatar_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('last successful avatar providers have a recency limit', () {
    const provider = AssetImage('placeholder');
    for (var i = 0; i < AvatarCache.maximumMemoryEntries; i++) {
      AvatarCache.rememberSuccessful('identity:memory:$i', provider);
    }
    expect(AvatarCache.lastSuccessful('identity:memory:0'), same(provider));
    AvatarCache.rememberSuccessful('identity:memory:new', provider);
    expect(AvatarCache.lastSuccessful('identity:memory:1'), isNull);
    expect(AvatarCache.lastSuccessful('identity:memory:0'), same(provider));
    AvatarCache.clearRetainedForAccount('memory');
    expect(AvatarCache.lastSuccessful('identity:memory:0'), isNull);
  });
}
