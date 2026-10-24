import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/statistics/statistics_assistant_page.dart';

void main() {
  test('only the bundled statistics asset may navigate or receive room state',
      () {
    expect(
        isStatisticsAssetUrl(
            'file:///var/mobile/Containers/Bundle/Application/uuid/Runner.app/Frameworks/App.framework/flutter_assets/assets/html/statistics_tools_combined_v2.html'),
        isTrue);
    expect(
        isStatisticsAssetUrl(
            'file:///android_asset/flutter_assets/assets/html/statistics_tools_combined_v2.html'),
        isTrue);
    for (final url in [
      'https://example.com/assets/html/statistics_tools_combined_v2.html',
      'javascript:alert(1)',
      'data:text/html,hello',
      'about:blank',
      'file:///etc/passwd',
      'file://evil/flutter_assets/assets/html/statistics_tools_combined_v2.html',
      'file:///tmp/statistics_tools_combined_v2.html',
      'file:///tmp/flutter_assets/assets/html/statistics_tools_combined_v2.html',
      'file:///android_asset/flutter_assets/assets/html/statistics_tools_combined_v2.html?redirect=x',
    ]) {
      expect(isStatisticsAssetUrl(url), isFalse, reason: url);
    }
  });
}
