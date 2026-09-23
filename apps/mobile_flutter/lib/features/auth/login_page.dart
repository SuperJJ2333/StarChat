import 'phone_login_controller.dart';
import '../../core/privacy_consent.dart';
import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/auth_surface_card.dart';
import '../../ui/components/immersive_auth_scaffold.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'legal_document_page.dart';
import 'legal_documents.dart';
import 'login_controller.dart';
import '../../ui/motion/motion_page_route.dart';

final class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.api,
    this.onLogin,
    this.onPhoneLogin,
    this.onConfirmMatrixAccountSwitch,
    this.onCancelMatrixAccountSwitch,
    this.onAuthenticated,
    this.destination,
    this.onRegister,
    this.onUserAgreement,
    this.onPrivacyPolicy,
  });

  final BusinessApiClient api;
  final Future<void> Function(String phone, String code,
      {String invitationCode,
      bool termsAccepted,
      bool Function()? shouldContinue})? onPhoneLogin;
  final Future<void> Function(String username, String password)? onLogin;
  final Future<void> Function()? onConfirmMatrixAccountSwitch;
  final Future<void> Function()? onCancelMatrixAccountSwitch;
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
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _invitation = TextEditingController();
  bool _phoneMode = false;
  late final PhoneLoginController _phoneController = PhoneLoginController(
      gateway: widget.api,
      deviceKey: 'flutter-${DateTime.now().millisecondsSinceEpoch}',
      deviceName: '畅聊移动端')
    ..addListener(_phoneChanged);
  void _phoneChanged() {
    if (mounted) setState(() {});
  }

  String? get _normalizedPhone {
    var value = _phone.text.replaceAll(RegExp(r'[ \-\(\)]'), '');
    if (value.startsWith('+86')) {
      value = value.substring(3);
    } else if (value.startsWith('86') && value.length == 13) {
      value = value.substring(2);
    }
    return RegExp(r'^1[3-9][0-9]{9}$').hasMatch(value) ? value : null;
  }

  bool get _canRequestPhoneCode =>
      !_loading && _normalizedPhone != null && _phoneController.canRequestOtp;

  Future<void> _requestPhoneCode() async {
    if (_normalizedPhone == null) {
      setState(() => _error = '请输入中国大陆 11 位手机号');
      return;
    }
    if (!_agreementAccepted) {
      setState(() => _error = '请先阅读并同意用户协议和隐私政策');
      return;
    }
    setState(() => _error = null);
    await _phoneController.requestOtp(_normalizedPhone!);
    if (mounted) setState(() => _error = _phoneController.state.message);
  }

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
    _phone.dispose();
    _code.dispose();
    _invitation.dispose();
    _phoneController.removeListener(_phoneChanged);
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username =
        _phoneMode ? _normalizedPhone ?? '' : _username.text.trim();
    final password = _phoneMode ? _code.text.trim() : _password.text;
    if (_phoneMode &&
        (!RegExp(r'^1[3-9]\d{9}$').hasMatch(username) ||
            !RegExp(r'^\d{6}$').hasMatch(password))) {
      setState(() => _error = '请输入有效手机号和 6 位验证码');
      return;
    }
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = '请输入畅聊号/邮箱和密码');
      return;
    }
    if (username.contains('@') &&
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(username)) {
      setState(() => _error = '请输入正确的邮箱地址');
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
      final bool success;
      if (_phoneMode) {
        if (widget.onPhoneLogin != null) {
          await widget.onPhoneLogin!(username, password,
              invitationCode: _invitation.text.trim(),
              termsAccepted: _agreementAccepted,
              shouldContinue: _loginIsCurrent);
          success = true;
        } else {
          success = await _phoneController.submit(username, password,
              invitationCode: _invitation.text.trim(),
              termsAccepted: _agreementAccepted,
              shouldContinue: _loginIsCurrent);
        }
      } else {
        success = await controller.submit(username, password);
      }
      if (success && mounted) {
        // 勾选《用户协议和隐私政策》是登录前置条件；成功后持久化，
        // 作为个推等第三方 SDK 初始化的同意依据（docs/PUSH_SETUP.md）。
        if (_agreementAccepted) {
          await const SharedPreferencesPrivacyConsentStore().accept();
        }
        await widget.onAuthenticated?.call();
        if (widget.destination != null && mounted) {
          Navigator.of(
            context,
          ).pushReplacement(MotionPageRoute(builder: widget.destination!));
        } else if (widget.onAuthenticated == null && mounted) {
          Navigator.of(context).pushReplacement(
            MotionPageRoute(builder: (_) => const _LoginSuccessPage()),
          );
        }
      }
      if (!success && mounted) {
        setState(() => _error = _phoneMode
            ? _phoneController.state.message
            : controller.state.message);
      }
    } on MatrixAccountSwitchRequired {
      final confirmed = await _confirmMatrixAccountSwitch();
      if (confirmed && mounted) {
        try {
          await widget.onConfirmMatrixAccountSwitch?.call();
          await widget.onAuthenticated?.call();
        } on BusinessApiException catch (error) {
          if (mounted) setState(() => _error = error.message);
        } on LoginStageException catch (error) {
          if (mounted) setState(() => _error = error.message);
        } catch (_) {
          if (mounted) setState(() => _error = '服务暂时不可用，请稍后重试');
        }
      } else {
        await widget.onCancelMatrixAccountSwitch?.call();
      }
    } on BusinessApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on LoginStageException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = '服务暂时不可用，请稍后重试');
      }
    } finally {
      controller.dispose();
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _loginIsCurrent() =>
      mounted &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);

  Future<bool> _confirmMatrixAccountSwitch() async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('切换聊天账号'),
        content: const Text('确认后将清除本机聊天数据，并使用新账号创建新的加密设备。'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认切换'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
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
              Text(
                _phoneMode ? '使用中国大陆手机号登录' : '使用用户名或邮箱登录',
                style: TextStyle(
                  color: WeChatColors.textSecondary,
                  fontSize: WeChatTypography.subhead,
                  height: 20 / 14,
                ),
              ),
              const SizedBox(height: 20),
              CupertinoSlidingSegmentedControl<bool>(
                groupValue: _phoneMode,
                children: const {false: Text('密码登录'), true: Text('手机号登录')},
                onValueChanged: _loading
                    ? (_) {}
                    : (value) => setState(() {
                          _phoneMode = value ?? false;
                          _error = null;
                        }),
              ),
              const SizedBox(height: WeChatSpacing.md),
              if (_phoneMode) ...[
                AuthTextField(
                    key: const Key('auth-login-phone'),
                    label: '手机号',
                    placeholder: '中国大陆 +86',
                    controller: _phone,
                    onChanged: (_) => setState(() {}),
                    keyboardType: TextInputType.phone,
                    enabled: !_loading),
                const SizedBox(height: WeChatSpacing.md),
                AuthTextField(
                    key: const Key('auth-login-code'),
                    label: '短信验证码',
                    placeholder: '输入 6 位验证码',
                    controller: _code,
                    keyboardType: TextInputType.number,
                    enabled: !_loading,
                    trailing: CupertinoButton(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        onPressed:
                            _canRequestPhoneCode ? _requestPhoneCode : null,
                        child: Text(
                            _phoneController.state.resendAfterSeconds > 0
                                ? '${_phoneController.state.resendAfterSeconds}s'
                                : '获取验证码',
                            style: TextStyle(
                                color: _canRequestPhoneCode
                                    ? WeChatColors.brandPrimary
                                    : WeChatColors.textTertiary)))),
                const SizedBox(height: WeChatSpacing.md),
                AuthTextField(
                    key: const Key('auth-login-invitation'),
                    label: '邀请码（仅新用户必填）',
                    placeholder: '已有账号无需填写',
                    controller: _invitation,
                    enabled: !_loading),
                const SizedBox(height: WeChatSpacing.sm),
                const Text('新手机号验证后自动注册，用户名和畅聊号由系统生成',
                    style: TextStyle(
                        fontSize: 12, color: WeChatColors.textSecondary)),
              ] else ...[
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
              ],
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
                // BUG-02：入口必须有真实实现——调用方未注入回调时打开
                // 应用内置正文，保证点击一定打开而不是静默无响应。
                onUserAgreement: widget.onUserAgreement ??
                    () => openLegalDocument(context, userAgreement),
                onPrivacyPolicy: widget.onPrivacyPolicy ??
                    () => openLegalDocument(context, privacyPolicy),
              ),
              if (_error != null) ...[
                const SizedBox(height: WeChatSpacing.md),
                AuthErrorMessage(
                  key: const Key('auth-login-error'),
                  message: _error!,
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
