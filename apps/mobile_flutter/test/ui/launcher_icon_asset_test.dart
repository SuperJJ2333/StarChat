import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('launcher master artwork fills and is centered on its square canvas',
      () async {
    final bytes = await File('assets/branding/app_icon.png').readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);

    expect(image.width, image.height);
    expect(pixels, isNotNull);

    var minX = image.width;
    var minY = image.height;
    var maxX = -1;
    var maxY = -1;
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final alpha = pixels!.getUint8((y * image.width + x) * 4 + 3);
        if (alpha == 0) continue;
        minX = x < minX ? x : minX;
        minY = y < minY ? y : minY;
        maxX = x > maxX ? x : maxX;
        maxY = y > maxY ? y : maxY;
      }
    }

    expect(minX, 0);
    expect(minY, 0);
    expect(maxX, image.width - 1);
    expect(maxY, image.height - 1);
  });

  test('Android adaptive launcher uses zero foreground inset', () {
    final adaptiveIcon = File(
      'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml',
    ).readAsStringSync();

    expect(adaptiveIcon, contains('android:inset="0%"'));
  });
}
