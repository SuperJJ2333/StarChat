import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/moments/moment_image_preprocessor.dart';

Uint8List _gif() =>
    base64Decode('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('direct Moments processing reuses GIF already within image budget',
      () async {
    final original = _gif();
    var calls = 0;
    final processor = MomentImagePreprocessor(compressBytes: (bytes,
        {required minWidth, required minHeight, required quality}) async {
      calls++;
      return Uint8List.fromList([1, 2, 3]);
    });
    expect(await processor.process(original), orderedEquals(original));
    expect(calls, 0);
  });

  test('injected static processing cannot flatten budget-compliant GIF',
      () async {
    var calls = 0;
    final original = _gif();
    final processor = MomentImagePreprocessor.functional((bytes) async {
      calls++;
      return Uint8List.fromList([9]);
    });
    expect(await processor.process(original), orderedEquals(original));
    expect(calls, 0);
  });

  test('truncated GIF is rejected before any image compression', () async {
    var calls = 0;
    final corrupt = _gif().sublist(0, 20);
    final processor = MomentImagePreprocessor.functional((bytes) async {
      calls++;
      return Uint8List.fromList([9]);
    });
    await expectLater(
        processor.process(corrupt), throwsA(isA<MomentImageException>()));
    expect(calls, 0);
  });
}
