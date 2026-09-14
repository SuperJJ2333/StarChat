
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/ui/chat/flash_photo.dart';

void main() {
  test('mock reset semantics after prior getInstance', () async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance(); // 模拟第一个测试先行加载
    SharedPreferences.setMockInitialValues({
      'flash-viewed:matrix:@flash-user:test': [r'$flash'],
    });
    final store = await FlashPhotoViewedStore.load('matrix:@flash-user:test');
    expect(store.isViewed(r'$flash'), isTrue);
  });
}
