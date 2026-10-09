import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:liuhetong_mobile/ui/chat/emoji_resource_glyph.dart';

class PendingSupportPaths extends PathProviderPlatform {
  final pending = Completer<String?>();
  @override
  Future<String?> getApplicationSupportPath() => pending.future;
}

void main() {
  testWidgets(
      'default runtime startup is neutral before async paths and offline failure restores vector',
      (tester) async {
    final previous = PathProviderPlatform.instance;
    final paths = PendingSupportPaths();
    PathProviderPlatform.instance = paths;
    addTearDown(() {
      PathProviderPlatform.instance = previous;
    });
    await tester.pumpWidget(const MediaQuery(
        data: MediaQueryData(),
        child: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
                child: EmojiResourceGlyph(
                    asset: 'assets/emoji/joy.webp', size: 32)))));
    expect(find.byType(SvgPicture), findsNothing);
    expect(tester.getSize(find.byType(EmojiResourceGlyph)), const Size(32, 32));
    paths.pending.completeError(StateError('support directory offline'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(SvgPicture), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
