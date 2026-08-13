import 'package:flutter/cupertino.dart';
import 'core/session_store.dart';
import 'core/app_config.dart';
import 'core/business_api_client.dart';
import 'features/matrix/matrix_e2ee_client.dart';
import 'features/auth/login_page.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption/utils/key_verification.dart';
import 'app_home.dart';
void main() => runApp(const LiuhetongApp());
class LiuhetongApp extends StatelessWidget {
  const LiuhetongApp({super.key});
  @override Widget build(BuildContext context) {
    final store = SecureSessionStore();
    final api = BusinessApiClient(baseUri: Uri.parse(AppConfig.businessApiBaseUrl), sessionStore: store);
    final matrix = MatrixSdkE2eeClient(Client('liuhetong_mobile', verificationMethods: {KeyVerificationMethod.emoji, KeyVerificationMethod.numbers}), homeserver: Uri.parse(AppConfig.matrixHomeserver));
    return CupertinoApp(title: '六合通', theme: const CupertinoThemeData(primaryColor: CupertinoColors.systemIndigo), builder: (context, child) => CupertinoTheme(data: CupertinoThemeData(brightness: MediaQuery.platformBrightnessOf(context), primaryColor: CupertinoColors.systemIndigo), child: child!), home: LoginPage(api: api, onLogin: (username, password) async { await api.login(username: username, password: password, deviceKey: 'flutter-${DateTime.now().millisecondsSinceEpoch}', deviceName: '六合通移动端'); await matrix.login('@$username:matrix.localhost', password); await matrix.sync(); }, destination: (_) => AppHome(api: api, matrix: matrix)));
  }
}
final class ClientComposition {
  ClientComposition({required this.sessionStore, required this.matrixClient});
  final SecureSessionStore sessionStore;
  final MatrixE2eeClient matrixClient;
}
