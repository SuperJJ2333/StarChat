import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:liuhetong_mobile/main.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/auth/login_page.dart';
void main() {
  testWidgets('renders product identity', (tester) async {
    await tester.pumpWidget(const LiuhetongApp());
    expect(find.text('六合通'), findsOneWidget);
  });
  testWidgets('renders login form', (tester) async {
    final api = BusinessApiClient(baseUri: Uri.parse('http://localhost:8082'), sessionStore: SecureSessionStore());
    await tester.pumpWidget(MaterialApp(home: LoginPage(api: api, onLogin: (_, __) async {})));
    expect(find.text('登录'), findsNWidgets(2));
    expect(find.byType(TextField), findsNWidgets(2));
  });
}
