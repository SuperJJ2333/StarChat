import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/cupertino.dart';
import 'package:liuhetong_mobile/main.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/auth/login_page.dart';
import 'package:liuhetong_mobile/ui/theme/theme_controller.dart';

final class _MemoryThemeStore implements ThemePreferenceStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async {}
}

void main() {
  testWidgets('renders product identity', (tester) async {
    await tester.pumpWidget(
      LiuhetongApp(
        themeController: ThemeController(store: _MemoryThemeStore()),
        home: const CupertinoPageScaffold(child: Center(child: Text('畅聊'))),
      ),
    );
    expect(find.text('畅聊'), findsOneWidget);
    expect(tester.widget<CupertinoApp>(find.byType(CupertinoApp)).locale,
        const Locale('zh', 'CN'));
  });
  testWidgets('renders login form', (tester) async {
    final api = BusinessApiClient(
      baseUri: Uri.parse('http://localhost:8082'),
      sessionStore: SecureSessionStore(),
    );
    await tester.pumpWidget(
      CupertinoApp(
        home: LoginPage(api: api, onLogin: (_, __) async {}),
      ),
    );
    expect(find.text('登录'), findsOneWidget);
    expect(find.byType(CupertinoTextField), findsNWidgets(2));
  });
}
