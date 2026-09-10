import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/media_resource_policy.dart';

void main() {
  testWidgets('memory pressure reaches encoded cache owners and decode budget',
      (tester) async {
    final cache = PaintingBinding.instance.imageCache;
    final previousBytes = cache.maximumSizeBytes;
    final previousEntries = cache.maximumSize;
    var clearCalls = 0;
    final policy = MediaResourcePolicy(clearEncoded: () => clearCalls++);
    try {
      policy.install();
      policy.install();
      expect(cache.maximumSizeBytes, 64 * 1024 * 1024);
      tester.binding.handleMemoryPressure();
      expect(clearCalls, 1);
      policy.dispose();
      tester.binding.handleMemoryPressure();
      expect(clearCalls, 1);
    } finally {
      policy.dispose();
      cache.maximumSizeBytes = previousBytes;
      cache.maximumSize = previousEntries;
    }
  });
}
