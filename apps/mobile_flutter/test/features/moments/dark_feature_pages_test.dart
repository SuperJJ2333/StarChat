import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/moments/moment_visibility_page.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';

void main() {
  testWidgets('moments visibility surfaces follow live theme switching',
      (tester) async {
    final brightness = ValueNotifier(Brightness.light);
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://test.example'),
        sessionStore: SecureSessionStore(_MemoryStore()),
        client: MockClient((_) async => http.Response('{"items":[]}', 200)));
    await tester.pumpWidget(ValueListenableBuilder<Brightness>(
        valueListenable: brightness,
        builder: (_, value, __) => CupertinoApp(
            theme: CupertinoThemeData(brightness: value),
            home: MomentVisibilityPage(
                api: api,
                initialSelection: const MomentVisibilitySelection.public()))));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CupertinoNavigationBar>(find.byType(CupertinoNavigationBar))
            .backgroundColor,
        WeChatColors.chatNavigationBackground);
    brightness.value = Brightness.dark;
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CupertinoNavigationBar>(find.byType(CupertinoNavigationBar))
            .backgroundColor,
        WeChatColors.darkSurface);
    final panels = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) => c.color != null)
        .toList();
    expect(panels.where((c) => c.color == CupertinoColors.white), isEmpty);
    expect(panels.where((c) => c.color == WeChatColors.darkElevated).length,
        greaterThanOrEqualTo(2));
    brightness.value = Brightness.light;
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CupertinoNavigationBar>(find.byType(CupertinoNavigationBar))
            .backgroundColor,
        WeChatColors.chatNavigationBackground);
    await tester.pumpWidget(const SizedBox());
    brightness.dispose();
  });
}

class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
