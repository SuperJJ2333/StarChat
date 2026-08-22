import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/auth_surface_card.dart';
import '../../ui/components/immersive_auth_scaffold.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'login_controller.dart';

final class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.api,
    this.onLogin,
    this.onAuthenticated,
    this.destination,
    this.onRegister,
    this.onUserAgreement,
    this.onPrivacyPolicy,
  });

  final BusinessApiClient api;
  final Future<void> Function(String username, String password)? onLogin;
  final Future<void> Function()? onAuthenticated;
  final WidgetBuilder? destination;
  final VoidCallback? onRegister;
  final VoidCallback? onUserAgreement;
  final VoidCallback? onPrivacyPolicy;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

final class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin {
  final _username = TextEditingController();
  final _password = TextEditingController();
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..forward();

  bool _loading = false;
  bool _agreementAccepted = false;
  bool _passwordVisible = false;
  String? _error;

  @override
  void dispose() {
    _intro.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _username.text.trim();
    final password = _password.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = '请输入用户名和密码');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    final controller = LoginController(
      operation: (user, secret) async {
        if (widget.onLogin != null) {
          await widget.onLogin!(user, secret);
        } else {
          await widget.api.login(
            username: user,
            password: secret,
            deviceKey: 'flutter-${DateTime.now().millisecondsSinceEpoch}',
            deviceName: '畅聊移动端',
          );
        }
      },
    );

    try {
      final success = await controller.submit(username, password);
      if (success && mounted) {
        await widget.onAuthenticated?.call();
        if (widget.destination != null && mounted) {
          Navigator.of(
            context,
          ).pushReplacement(CupertinoPageRoute(builder: widget.destination!));
        } else if (widget.onAuthenticated == null && mounted) {
          Navigator.of(context).pushReplacement(
            CupertinoPageRoute(builder: (_) => const _LoginSuccessPage()),
          );
        }
      }
      if (!success && mounted) {
        setState(() => _error = controller.state.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = '服务暂时不可用，请稍后重试');
      }
    } finally {
      controller.dispose();
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final dark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final form = Form(
      key: const Key('auth-login-form'),
      child: AuthSurfaceCard(
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AuthBrandMark(),
              const SizedBox(height: WeChatSpacing.sm),
              Text(
                '畅聊',
                style: TextStyle(
                  color: dark
                      ? WeChatColors.darkTextPrimary
                      : WeChatColors.lightTextPrimary,
                  fontSize: WeChatTypography.brand,
                  fontWeight: FontWeight.w700,
                  height: 42 / 34,
                  letterSpacing: -1,
                ),
              ),
              const Text(
                '使用用户名或邮箱登录',
                style: TextStyle(
                  color: WeChatColors.textSecondary,
                  fontSize: WeChatTypography.subhead,
                  height: 20 / 14,
                ),
              ),
              const SizedBox(height: 20),
              AuthTextField(
                key: const Key('auth-login-identity'),
                label: '用户名/邮箱',
                placeholder: '输入用户名或邮箱',
                controller: _username,
                enabled: !_loading,
                textInputAction: TextInputAction.next,
                autofillHints: const [
                  AutofillHints.username,
                  AutofillHints.email,
                ],
              ),
              const SizedBox(height: WeChatSpacing.md),
              AuthTextField(
                key: const Key('auth-login-password'),
                label: '密码',
                placeholder: '输入密码',
                controller: _password,
                enabled: !_loading,
                obscureText: !_passwordVisible,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.password],
                trailing: CupertinoButton(
                  key: const Key('auth-login-password-visibility'),
                  padding: EdgeInsets.zero,
                  onPressed: _loading
                      ? null
                      : () => setState(
                            () => _passwordVisible = !_passwordVisible,
                          ),
                  child: Icon(
                    _passwordVisible
                        ? CupertinoIcons.eye_slash
                        : CupertinoIcons.eye,
                    size: 19,
                    color: WeChatColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: WeChatSpacing.md),
              const Text(
                '端到端加密 · 恢复密钥仅保存在设备',
                style: TextStyle(
                  color: WeChatColors.textSecondary,
                  fontSize: WeChatTypography.caption,
                  height: 17 / 12,
                ),
              ),
              const SizedBox(height: WeChatSpacing.xs),
              AuthAgreementRow(
                value: _agreementAccepted,
                enabled: !_loading,
                onChanged: (value) => setState(
                  () => _agreementAccepted = value,
                ),
                onUserAgreement: widget.onUserAgreement,
                onPrivacyPolicy: widget.onPrivacyPolicy,
              ),
              if (_error != null) ...[
                const SizedBox(height: WeChatSpacing.md),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    key: const Key('auth-login-error'),
                    style: const TextStyle(
                      color: WeChatColors.danger,
                      fontSize: WeChatTypography.subhead,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: WeChatSpacing.md),
              SizedBox(
                width: double.infinity,
                child: ModernActionButton(
                  icon: _error == null
                      ? ChangliaoIcons.confirm
                      : ChangliaoIcons.retry,
                  label: _error == null ? '登录' : '重试',
                  loading: _loading,
                  onPressed: _loading || !_agreementAccepted ? null : _submit,
                ),
              ),
              if (widget.onRegister != null) ...[
                const SizedBox(height: WeChatSpacing.xs),
                AuthInlineRegisterLink(
                  enabled: !_loading,
                  onRegister: widget.onRegister!,
                ),
              ],
            ],
          ),
        ),
      ),
    );

    final scrollable = ListView(
      key: const Key('auth-login-scroll'),
      padding: EdgeInsets.fromLTRB(
        WeChatSpacing.xl,
        120,
        WeChatSpacing.xl,
        WeChatSpacing.xl + bottomInset,
      ),
      children: [Center(child: form)],
    );
    final content = reduceMotion
        ? scrollable
        : FadeTransition(
            opacity: CurvedAnimation(parent: _intro, curve: Curves.easeOut),
            child: SlideTransition(
              position:
                  Tween(begin: const Offset(0, .035), end: Offset.zero).animate(
                CurvedAnimation(parent: _intro, curve: Curves.easeOutCubic),
              ),
              child: scrollable,
            ),
          );
    return ImmersiveAuthScaffold(child: content);
  }
}

final class _LoginSuccessPage extends StatelessWidget {
  const _LoginSuccessPage();

  @override
  Widget build(BuildContext context) =>
      const CupertinoPageScaffold(child: Center(child: Text('登录成功')));
}
