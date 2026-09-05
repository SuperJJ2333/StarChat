import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('render the unique SVG source to the launcher master PNG', () async {
    final source = File('assets/branding/liuhetong_logo.svg');
    final providedLogo = File('assets/branding/LOGO.png');
    final landing = File('assets/landing.png');
    final output = File('assets/branding/app_icon.png');
    final svg = await source.readAsString();
    final picture = await vg.loadPicture(SvgStringLoader(svg), null);
    final image = await picture.picture.toImage(1024, 1024);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    picture.picture.dispose();
    image.dispose();
    if (bytes == null) throw StateError('SVG renderer returned no PNG bytes');
    await output.writeAsBytes(bytes.buffer.asUint8List(), flush: true);

    final manifest = {
      'source': 'assets/branding/liuhetong_logo.svg',
      'source_sha256': sha256.convert(await source.readAsBytes()).toString(),
      'provided_logo_sha256': sha256.convert(await providedLogo.readAsBytes()).toString(),
      'landing_sha256': sha256.convert(await landing.readAsBytes()).toString(),
      'generated': 'assets/branding/app_icon.png',
      'generated_sha256': sha256.convert(await output.readAsBytes()).toString(),
      'width': 1024,
      'height': 1024,
    };
    await File('assets/branding/brand-assets.sha256.json').writeAsString('${const JsonEncoder.withIndent('  ').convert(manifest)}\n', flush: true);
    expect(await output.length(), greaterThan(1024));
  });
}
