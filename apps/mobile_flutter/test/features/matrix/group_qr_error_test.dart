import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_info_controller.dart';
import 'package:liuhetong_mobile/features/matrix/group_qr_code_page.dart';

class _Store implements SecureKeyValueStore {
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

void main() {
  testWidgets('签发接口未部署时明确显示服务未开通，而非稍后重试', (tester) async {
    final session = SecureSessionStore(_Store());
    await session.saveSession(
        accessToken: 'test-access', refreshToken: 'test-refresh');
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: session,
        client: MockClient(
            (_) async => http.Response('{"detail":"Not Found"}', 404)));
    await tester.pumpWidget(CupertinoApp(
        home: GroupQrCodePage(
            snapshot: const GroupChatInfoSnapshot(
                name: 'test',
                members: [],
                roomId: '!test:example',
                ownerId: '@owner:example',
                currentUserId: '@owner:example'),
            api: api)));
    await tester.pumpAndSettle();
    expect(find.text('群二维码服务尚未部署，暂时无法生成'), findsOneWidget);
  });
}
