import 'package:flutter/material.dart';
import 'core/session_store.dart';
import 'features/matrix/matrix_e2ee_client.dart';
void main() => runApp(const LiuhetongApp());
class LiuhetongApp extends StatelessWidget {
  const LiuhetongApp({super.key});
  @override Widget build(BuildContext context) => MaterialApp(title: '六合通', theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true), home: const Scaffold(body: Center(child: Text('六合通'))));
}
final class ClientComposition {
  ClientComposition({required this.sessionStore, required this.matrixClient});
  final SecureSessionStore sessionStore;
  final MatrixE2eeClient matrixClient;
}
