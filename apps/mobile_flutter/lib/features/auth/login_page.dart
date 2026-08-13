import 'package:flutter/material.dart';
import '../../core/business_api_client.dart';

final class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.api, this.onLogin, this.destination});
  final BusinessApiClient api;
  final Future<void> Function(String username, String password)? onLogin;
  final WidgetBuilder? destination;
  @override State<LoginPage> createState() => _LoginPageState();
}

final class _LoginPageState extends State<LoginPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  String? _error;
  Future<void> _submit() async {
    final username = _username.text.trim();
    final password = _password.text;
    if (username.isEmpty || password.isEmpty) { setState(() => _error = '请输入用户名和密码'); return; }
    setState(() { _loading = true; _error = null; });
    try {
      if (widget.onLogin != null) { await widget.onLogin!(username, password); } else { await widget.api.login(username: username, password: password, deviceKey: 'flutter-${DateTime.now().millisecondsSinceEpoch}', deviceName: '六合通雷电模拟器'); }
      if (mounted) Navigator.of(context).pushReplacement(MaterialPageRoute(builder: widget.destination ?? (_) => const _LoginSuccessPage()));
    } catch (error) { if (mounted) setState(() => _error = error.toString().replaceFirst('Bad state: ', '')); }
    finally { if (mounted) setState(() => _loading = false); }
  }
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('登录')), body: ListView(padding: const EdgeInsets.all(24), children: [const Text('六合通', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)), const SizedBox(height: 8), const Text('用户名 + 密码登录，随后建立 Matrix 加密会话'), const SizedBox(height: 24), TextField(controller: _username, enabled: !_loading, decoration: const InputDecoration(labelText: '用户名', border: OutlineInputBorder())), const SizedBox(height: 16), TextField(controller: _password, enabled: !_loading, obscureText: true, decoration: const InputDecoration(labelText: '密码', border: OutlineInputBorder())), if (_error != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))), const SizedBox(height: 24), FilledButton(onPressed: _loading ? null : _submit, child: _loading ? const CircularProgressIndicator() : const Text('登录'))]));
}
final class _LoginSuccessPage extends StatelessWidget { const _LoginSuccessPage(); @override Widget build(BuildContext context) => const Scaffold(body: Center(child: Text('登录成功'))); }
