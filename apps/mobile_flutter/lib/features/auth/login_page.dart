import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';

final class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.api, this.onLogin, this.destination});
  final BusinessApiClient api;
  final Future<void> Function(String username, String password)? onLogin;
  final WidgetBuilder? destination;
  @override State<LoginPage> createState() => _LoginPageState();
}

final class _LoginPageState extends State<LoginPage> with SingleTickerProviderStateMixin {
  final _username = TextEditingController();
  final _password = TextEditingController();
  late final AnimationController _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 500))..forward();
  bool _loading = false;
  final bool _obscure = true;
  String? _error;
  @override void dispose() { _intro.dispose(); _username.dispose(); _password.dispose(); super.dispose(); }
  Future<void> _submit() async {
    final username = _username.text.trim(); final password = _password.text;
    if (username.isEmpty || password.isEmpty) { setState(() => _error = '请输入用户名和密码'); return; }
    setState(() { _loading = true; _error = null; });
    try {
      if (widget.onLogin != null) { await widget.onLogin!(username, password); } else { await widget.api.login(username: username, password: password, deviceKey: 'flutter-${DateTime.now().millisecondsSinceEpoch}', deviceName: '六合通移动端'); }
      if (mounted) Navigator.of(context).pushReplacement(CupertinoPageRoute(builder: widget.destination ?? (_) => const _LoginSuccessPage()));
    } catch (error) { if (mounted) setState(() => _error = error.toString().replaceFirst('Bad state: ', '')); }
    finally { if (mounted) setState(() => _loading = false); }
  }
  @override Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final body = SafeArea(child: ListView(padding: const EdgeInsets.fromLTRB(24, 48, 24, 24), children: [const _BrandMark(), const SizedBox(height: 20), const Text('六合通', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: -1)), const SizedBox(height: 8), const Text('安全、私密的加密通信与资产服务', style: TextStyle(color: CupertinoColors.secondaryLabel, fontSize: 16)), const SizedBox(height: 36), CupertinoFormSection.insetGrouped(children: [CupertinoTextFormFieldRow(controller: _username, enabled: !_loading, prefix: const Text('用户名'), placeholder: '输入用户名', textInputAction: TextInputAction.next), CupertinoTextFormFieldRow(controller: _password, enabled: !_loading, prefix: const Text('密码'), placeholder: '输入密码', obscureText: _obscure)]), if (_error != null) Padding(padding: const EdgeInsets.only(top: 14), child: Text(_error!, style: const TextStyle(color: CupertinoColors.systemRed))), const SizedBox(height: 20), CupertinoButton.filled(onPressed: _loading ? null : _submit, borderRadius: BorderRadius.circular(14), child: _loading ? const CupertinoActivityIndicator(color: CupertinoColors.white) : const Text('登录')), const SizedBox(height: 18), const Center(child: Text('端到端加密 · 恢复密钥仅保存在设备', style: TextStyle(color: CupertinoColors.tertiaryLabel, fontSize: 13)))]));
    if (reduceMotion) return CupertinoPageScaffold(navigationBar: const CupertinoNavigationBar(middle: Text('登录')), child: body);
    return CupertinoPageScaffold(navigationBar: const CupertinoNavigationBar(middle: Text('登录')), child: FadeTransition(opacity: CurvedAnimation(parent: _intro, curve: Curves.easeOut), child: SlideTransition(position: Tween(begin: const Offset(0, .035), end: Offset.zero).animate(CurvedAnimation(parent: _intro, curve: Curves.easeOutCubic)), child: body)));
  }
}
final class _BrandMark extends StatelessWidget { const _BrandMark(); @override Widget build(BuildContext context) => Container(width: 72, height: 72, decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: const Color(0xff07c160)), child: const Icon(CupertinoIcons.bubble_left_bubble_right_fill, color: CupertinoColors.white, size: 36)); }
final class _LoginSuccessPage extends StatelessWidget { const _LoginSuccessPage(); @override Widget build(BuildContext context) => const CupertinoPageScaffold(child: Center(child: Text('登录成功'))); }
