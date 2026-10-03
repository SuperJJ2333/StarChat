import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_security_page.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_recovery_vault.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/app_home.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

void main() {
  testWidgets('normal settings opens the automatic history status page',
      (tester) async {
    final matrix = MatrixSdkE2eeClient(Client('settings-recovery'),
        homeserver: Uri.parse('https://example.test'));
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore());
    await tester.pumpWidget(CupertinoApp(
        home: SettingsPage(api: api, matrix: matrix, onLogout: () async {})));
    await tester.tap(find.text('聊天记录同步'));
    await tester.pumpAndSettle();
    expect(find.byType(MatrixSecurityPage), findsOneWidget);
    expect(find.text('正在恢复聊天记录'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'normal history sync has automatic truthful states without manual key barrier',
      (tester) async {
    final matrix = MatrixSdkE2eeClient(Client('sync-page'),
        homeserver: Uri.parse('https://example.test'));
    await tester
        .pumpWidget(CupertinoApp(home: MatrixSecurityPage(matrix: matrix)));
    expect(find.text('聊天记录同步'), findsOneWidget);
    expect(find.text('正在恢复聊天记录'), findsOneWidget);
    expect(find.byType(CupertinoTextField), findsNothing);
    expect(find.textContaining('SAS'), findsNothing);
    matrix.historySyncStatus.setPhase(VaultSyncPhase.partial);
    await tester.pump();
    expect(find.text('部分旧记录缺少历史密钥'), findsOneWidget);
    expect(find.text('重试同步'), findsOneWidget);
    matrix.historySyncStatus.setPhase(VaultSyncPhase.revoked);
    await tester.pump();
    expect(find.text('已退出当前账号，同步已停止'), findsOneWidget);
    expect(find.text('重试同步'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
