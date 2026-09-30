import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/encrypted_media_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('gallery export saves original GIF bytes with gif extension',
      (tester) async {
    final original = base64Decode(
        'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7');
    final preview = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1kAAAAASUVORK5CYII=');
    final saved = <Map>[];
    var originalLoads = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const gallery = MethodChannel('chatflow/gallery');
    const photos = MethodChannel('com.fluttercandies/photo_manager');
    messenger.setMockMethodCallHandler(gallery, (_) async => 33);
    messenger.setMockMethodCallHandler(photos, (call) async {
      if (call.method == 'saveImage') {
        saved.add(Map.from(call.arguments as Map));
        return {
          'id': 'saved',
          'type': 1,
          'width': 1,
          'height': 1,
          'duration': 0,
          'createDt': 0,
          'modifiedDt': 0,
        };
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(gallery, null);
      messenger.setMockMethodCallHandler(photos, null);
    });
    await tester.pumpWidget(CupertinoApp(
        home: ImageViewerPage(
      previewBytes: preview,
      loadOriginal: () async {
        originalLoads++;
        return original;
      },
    )));
    await tester.pump();
    await tester.tap(find.byKey(const Key('viewer-download')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(saved, hasLength(1));
    expect(saved.single['filename'], endsWith('.gif'));
    expect(saved.single['image'], orderedEquals(original));
    expect(originalLoads, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }, variant: TargetPlatformVariant({TargetPlatform.android}));
}
