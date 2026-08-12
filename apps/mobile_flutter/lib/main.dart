import 'package:flutter/material.dart';
import 'core/session_store.dart';
import 'core/app_config.dart';
import 'core/business_api_client.dart';
import 'features/matrix/matrix_e2ee_client.dart';
import 'app_home.dart';
void main() => runApp(const LiuhetongApp());
class LiuhetongApp extends StatelessWidget {
  const LiuhetongApp({super.key});
  @override Widget build(BuildContext context) => MaterialApp(title: '六合通', theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true), home: AppHome(api: BusinessApiClient(baseUri: Uri.parse(AppConfig.businessApiBaseUrl), sessionStore: SecureSessionStore())));
}
final class ClientComposition {
  ClientComposition({required this.sessionStore, required this.matrixClient});
  final SecureSessionStore sessionStore;
  final MatrixE2eeClient matrixClient;
}
