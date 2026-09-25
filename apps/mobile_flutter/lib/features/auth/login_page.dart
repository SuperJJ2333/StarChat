import 'dart:async';

import 'phone_login_controller.dart';
import 'phone_number_format.dart';
import '../../core/privacy_consent.dart';
import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../../core/business_phone_contracts.dart';
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
    this.onPhoneInvitationContinue,
    this.onConfirmMatrixAccountSwitch,
    this.onCancelMatrixAccountSwitch,
    this.onAuthenticated,
    this.destination,
    this.onRegister,
    this.onUserAgreement,
    this.onPrivacyPolicy,
    this.now,
  });

  final BusinessApiClient api;
  final Future<void> Function(
    String phone,
    String code, {
    String invitationCode,
    bool termsAccepted,
    bool Function()? shouldContinue,
  })?
  onPhoneLogin;
  final Future<void> Function(
    String phone,
    String ticket,
    String invitationCode, {
    bool termsAccepted,
    bool Function()? shouldContinue,
  })?
  onPhoneInvitationContinue;
  final Future<void> Function(String username, String password)? onLogin;
  final Future<void> Function()? onConfirmMatrixAccountSwitch;
  final Future<void> Function()? onCancelMatrixAccountSwitch;
  final Future<void> Function()? onAuthenticated;
  final WidgetBuilder? destination;
  final VoidCallback? onRegister;
  final VoidCallback? onUserAgreement;
  final VoidCallback? onPrivacyPolicy;
  final DateTime Function()? now;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

final class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _invitation = TextEditingController();
  bool _phoneMode = false;
  late final PhoneLoginController _phoneController = PhoneLoginController(
    gateway: widget.api,
    deviceKey: 'flutter-${DateTime.now().millisecondsSinceEpoch}',
    deviceName: '畅聊移动端',
  )..addListener(_phoneChanged);
  void _phoneChanged() {
    if (mounted) setState(() {});
  }

  String? get _normalizedPhone => normalizeMainlandPhone(_phone.text);

  bool get _canRequestPhoneCode =>
      !_loading && _invitationTicket == null && _phoneController.canRequestOtp;

  DateTime _now() => widget.now?.call() ?? DateTime.now();
  DateTime? _loginRetryUntil;
  Timer? _loginRetryTimer;
  int _loginRetrySeconds = 0;
  String? _phoneFormatError;
  bool _phoneFormatValidated = false;

  String? get _visibleError =>
      _loginRetrySeconds > 0 ? '登录请求较频繁，请等待 $_loginRetrySeconds 秒后重试' : _error;

  void _showLoginError(String? message, {int? retryAfterSeconds}) {
    _loginRetryTimer?.cancel();
    final seconds = retryAfterSeconds?.clamp(1, 86400);
    setState(() {
      _error = seconds == null ? message : null;
      _loginRetryUntil = seconds == null
          ? null
          : _now().add(Duration(seconds: seconds));
      _loginRetrySeconds = seconds ?? 0;
    });
    if (seconds != null) {
      _loginRetryTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _refreshLoginRetry(),
      );
    }
  }

  void _refreshLoginRetry() {
    final until = _loginRetryUntil;
    if (until == null || !mounted) return;
    final seconds = (until.difference(_now()).inMilliseconds / 1000)
        .ceil()
        .clamp(0, 86400);
    if (seconds == _loginRetrySeconds) return;
    setState(() {
      _loginRetrySeconds = seconds;
      if (seconds == 0) _loginRetryUntil = null;
    });
    if (seconds == 0) _loginRetryTimer?.cancel();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshLoginRetry();
  }

  Future<void> _requestPhoneCode() async {
    final requestedPhone = _normalizedPhone;
    if (requestedPhone == null) {
      setState(() {
        _phoneFormatError = '请输入中国大陆 11 位手机号';
        _phoneFormatValidated = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _phoneFormatError = null;
      _phoneFormatValidated = true;
    });
    if (!_agreementAccepted) {
      setState(() => _error = '请先阅读并同意用户协议和隐私政策');
      return;
    }
    setState(() {
      _invitationTicket = null;
      _invitationPhone = null;
      _requiresFreshPhoneCode = true;
      _error = null;
    });
    final accepted = await _phoneController.requestOtp(requestedPhone);
    if (!mounted) return;
    setState(() {
      if (accepted) {
        _code.clear();
        if (_normalizedPhone == requestedPhone) {
          // A 202 acknowledges the request, not actual SMS delivery.
          _requiresFreshPhoneCode = false;
          _error = '如收到新验证码，请输入；未收到请稍后再试';
        } else {
          _requiresFreshPhoneCode = true;
          _error = '手机号已更改，请重新请求验证码';
        }
      } else {
        _error = _phoneController.state.message;
      }
    });
  }

  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..forward();

  bool _loading = false;
  bool _requiresFreshPhoneCode = false;
  String? _invitationTicket;
  String? _invitationPhone;
  bool _agreementAccepted = false;
  bool _passwordVisible = false;
  String? _error;

  String _invitationMessage(PhoneInvitationIssue issue) => switch (issue) {
    PhoneInvitationIssue.required => '验证码已通过，请输入邀请码后完成注册',
    PhoneInvitationIssue.invalid => '验证码已通过，邀请码无效，请更换后继续',
    PhoneInvitationIssue.expired => '验证码已通过，邀请码已过期，请更换后继续',
    PhoneInvitationIssue.exhausted => '验证码已通过，邀请码使用次数已满，请更换后继续',
    PhoneInvitationIssue.terms => '验证码已通过，请同意用户协议和隐私政策后继续',
    PhoneInvitationIssue.uncertain => '验证码已通过，邀请码提交结果待确认；请在本页继续',
    PhoneInvitationIssue.provisioning => '验证码已通过，聊天账号仍在开通；请稍后在本页继续',
  };

  void _acceptInvitationProof(
    PhoneInvitationContinuationRequired proof,
    String phone,
  ) {
    _invitationTicket = proof.ticket;
    _invitationPhone = phone;
    _requiresFreshPhoneCode = false;
    _error = _invitationMessage(proof.issue);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _loginRetryTimer?.cancel();
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
    final continuationTicket = _phoneMode ? _invitationTicket : null;
    final continuing = continuationTicket != null;
    if (_phoneMode && _requiresFreshPhoneCode) {
      setState(() => _error = '原验证码不可再次提交，请重新获取验证码');
      return;
    }
    final username = _phoneMode
        ? _normalizedPhone ?? ''
        : _username.text.trim();
    final password = _phoneMode ? _code.text.trim() : _password.text;
    if (_phoneMode && username.isEmpty) {
      setState(() {
        _phoneFormatError = '请输入中国大陆 11 位手机号';
        _phoneFormatValidated = false;
      });
      return;
    }
    if (_phoneMode && !continuing && !RegExp(r'^\d{6}$').hasMatch(password)) {
      setState(() => _error = '请输入 6 位验证码');
      return;
    }
    if (continuing && username != _invitationPhone) {
      setState(() {
        _invitationTicket = null;
        _invitationPhone = null;
        _requiresFreshPhoneCode = true;
        _error = '手机号已更改，请重新获取验证码';
      });
      return;
    }
    if (continuing && _invitation.text.trim().isEmpty) {
      setState(() => _error = '验证码已通过，请输入邀请码后完成注册');
      return;
    }
    if (username.isEmpty || (!continuing && password.isEmpty)) {
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
      // An unknown OTP result cannot be replayed. Only a server-issued
      // invitation proof permits continuation without another SMS check.
      if (_phoneMode && !continuing) _requiresFreshPhoneCode = true;
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
        if (continuing) {
          if (widget.onPhoneInvitationContinue != null) {
            await widget.onPhoneInvitationContinue!(
              username,
              continuationTicket,
              _invitation.text.trim(),
              termsAccepted: _agreementAccepted,
              shouldContinue: _loginIsCurrent,
            );
          } else {
            await widget.api.completePhoneLoginInvitation(
              invitationTicket: continuationTicket,
              phone: username,
              invitationCode: _invitation.text.trim(),
              termsAccepted: _agreementAccepted,
              deviceKey: _phoneController.deviceKey,
              deviceName: _phoneController.deviceName,
              shouldContinue: _loginIsCurrent,
            );
          }
          success = true;
        } else if (widget.onPhoneLogin != null) {
          await widget.onPhoneLogin!(
            username,
            password,
            invitationCode: _invitation.text.trim(),
            termsAccepted: _agreementAccepted,
            shouldContinue: _loginIsCurrent,
          );
          success = true;
        } else {
          success = await _phoneController.submit(
            username,
            password,
            invitationCode: _invitation.text.trim(),
            termsAccepted: _agreementAccepted,
            shouldContinue: _loginIsCurrent,
          );
        }
      } else {
        success = await controller.submit(username, password);
      }
      if (success && mounted) {
        _invitationTicket = null;
        _invitationPhone = null;
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
        final proof = _phoneController.invitationContinuation;
        if (_phoneMode && proof != null) {
          setState(() => _acceptInvitationProof(proof, username));
        } else {
          final retrySeconds = _phoneMode
              ? _phoneController.state.loginRetryAfterSeconds
              : controller.state.retryAfterSeconds;
          _showLoginError(
            _phoneMode
                ? '${_phoneController.state.message ?? '登录结果待确认'}；原验证码不可再次提交，请重新获取验证码'
                : controller.state.message,
            retryAfterSeconds: retrySeconds,
          );
        }
      }
    } on PhoneInvitationContinuationRequired catch (proof) {
      if (mounted && _phoneMode && _normalizedPhone == username) {
        setState(() => _acceptInvitationProof(proof, username));
      }
    } on MatrixAccountSwitchRequired {
      final confirmed = await _confirmMatrixAccountSwitch();
      if (confirmed && mounted) {
        try {
          await widget.onConfirmMatrixAccountSwitch?.call();
          await widget.onAuthenticated?.call();
        } on BusinessApiException catch (error) {
          if (mounted) {
            _showLoginError(
              _phoneMode
                  ? '${error.message}；原验证码不可再次提交，请重新获取验证码'
                  : error.message,
              retryAfterSeconds: error.statusCode == 429
                  ? error.retryAfterSeconds ?? 60
                  : null,
            );
          }
        } on LoginStageException catch (error) {
          if (mounted) {
            setState(
              () => _error = _phoneMode
                  ? '聊天登录未完成；原验证码不可再次提交，请重新获取验证码'
                  : error.message,
            );
          }
        } catch (_) {
          if (mounted) {
            setState(
              () => _error = _phoneMode
                  ? '聊天登录未完成；原验证码不可再次提交，请重新获取验证码'
                  : '服务暂时不可用，请稍后重试',
            );
          }
        }
      } else {
        await widget.onCancelMatrixAccountSwitch?.call();
        if (mounted && _phoneMode) {
          setState(() => _error = '已取消切换；原验证码不可再次提交，请重新获取验证码');
        }
      }
    } on BusinessApiException catch (error) {
      if (mounted) {
        if (continuing &&
            (error.code == 'LOGIN_TICKET_INVALID' ||
                error.code == 'INVITATION_TICKET_INVALID')) {
          _invitationTicket = null;
          _invitationPhone = null;
          _requiresFreshPhoneCode = true;
        }
        _showLoginError(
          _phoneMode
              ? continuing && _invitationTicket != null
                    ? '补填结果待确认；请在本页重试，凭据失效后再获取新验证码'
                    : '${error.message}；原验证码不可再次提交，请重新获取验证码'
              : error.message,
          retryAfterSeconds: error.statusCode == 429
              ? error.retryAfterSeconds ?? 60
              : null,
        );
      }
    } on LoginStageException catch (error) {
      if (mounted) {
        setState(
          () => _error = _phoneMode
              ? '聊天登录未完成；原验证码不可再次提交，请重新获取验证码'
              : error.message,
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _phoneMode
              ? continuing && _invitationTicket != null
                    ? '补填结果待确认；请在本页重试，凭据失效后再获取新验证码'
                    : '登录结果待确认；原验证码不可再次提交，请重新获取验证码'
              : '服务暂时不可用，请稍后重试',
        );
      }
    } finally {
      controller.dispose();
      if (_phoneMode) _code.clear();
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
    final visibleError = _visibleError;
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
                        _invitationTicket = null;
                        _invitationPhone = null;
                        if (!_phoneMode) _requiresFreshPhoneCode = false;
                        _error = null;
                        _phoneFormatError = null;
                        _phoneFormatValidated = false;
                      }),
              ),
              const SizedBox(height: WeChatSpacing.md),
              if (_phoneMode) ...[
                const Text(
                  '请输入畅聊 ChatFlow 短信验证码',
                  style: TextStyle(
                    fontSize: WeChatTypography.caption,
                    color: WeChatColors.textSecondary,
                  ),
                ),
                const SizedBox(height: WeChatSpacing.sm),
                AuthTextField(
                  key: const Key('auth-login-phone'),
                  label: '手机号',
                  placeholder: '中国大陆 +86',
                  controller: _phone,
                  onChanged: (_) => setState(() {
                    final showFormatFeedback =
                        _phoneFormatError != null || _phoneFormatValidated;
                    if (showFormatFeedback) {
                      final valid = _normalizedPhone != null;
                      _phoneFormatError = valid ? null : '请输入中国大陆 11 位手机号';
                      _phoneFormatValidated = valid;
                    }
                    if (_invitationTicket != null &&
                        _normalizedPhone != _invitationPhone) {
                      _invitationTicket = null;
                      _invitationPhone = null;
                      _requiresFreshPhoneCode = true;
                      _error = '手机号已更改，请重新获取验证码';
                    }
                  }),
                  keyboardType: TextInputType.phone,
                  enabled: !_loading,
                ),
                if (_phoneFormatError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: WeChatSpacing.xs),
                    child: AuthErrorMessage(
                      key: const Key('auth-login-phone-error'),
                      message: _phoneFormatError!,
                      compact: true,
                    ),
                  ),
                if (_phoneFormatValidated)
                  const Padding(
                    padding: EdgeInsets.only(top: WeChatSpacing.xs),
                    child: Text(
                      '手机号格式正确',
                      key: Key('auth-login-phone-valid'),
                      style: TextStyle(
                        color: WeChatColors.brandPrimary,
                        fontSize: WeChatTypography.caption,
                      ),
                    ),
                  ),
                const SizedBox(height: WeChatSpacing.md),
                AuthTextField(
                  key: const Key('auth-login-code'),
                  label: _invitationTicket == null ? '短信验证码' : '短信验证码（已通过）',
                  placeholder: _invitationTicket == null ? '输入 6 位验证码' : '已验证',
                  controller: _code,
                  keyboardType: TextInputType.number,
                  enabled: !_loading && _invitationTicket == null,
                  trailing: AuthCodeRequestButton(
                    buttonKey: const Key('auth-login-send-code'),
                    label: _phoneController.state.resendAfterSeconds > 0
                        ? '${_phoneController.state.resendAfterSeconds}s'
                        : '获取验证码',
                    onPressed: _canRequestPhoneCode ? _requestPhoneCode : null,
                  ),
                ),
                const SizedBox(height: WeChatSpacing.md),
                AuthTextField(
                  key: const Key('auth-login-invitation'),
                  label: '邀请码（仅新用户必填）',
                  placeholder: '已有账号无需填写',
                  controller: _invitation,
                  enabled: !_loading,
                ),
                const SizedBox(height: WeChatSpacing.sm),
                const Text(
                  '新手机号验证后自动注册，用户名和畅聊号由系统生成',
                  style: TextStyle(
                    fontSize: 12,
                    color: WeChatColors.textSecondary,
                  ),
                ),
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
                onChanged: (value) =>
                    setState(() => _agreementAccepted = value),
                // BUG-02：入口必须有真实实现——调用方未注入回调时打开
                // 应用内置正文，保证点击一定打开而不是静默无响应。
                onUserAgreement:
                    widget.onUserAgreement ??
                    () => openLegalDocument(context, userAgreement),
                onPrivacyPolicy:
                    widget.onPrivacyPolicy ??
                    () => openLegalDocument(context, privacyPolicy),
              ),
              if (visibleError != null) ...[
                const SizedBox(height: WeChatSpacing.md),
                AuthErrorMessage(
                  key: const Key('auth-login-error'),
                  message: visibleError,
                ),
              ],
              const SizedBox(height: WeChatSpacing.md),
              SizedBox(
                width: double.infinity,
                child: ModernActionButton(
                  icon: visibleError == null
                      ? ChangliaoIcons.confirm
                      : ChangliaoIcons.retry,
                  label: _invitationTicket != null && _phoneMode
                      ? '完成注册'
                      : _requiresFreshPhoneCode && _phoneMode
                      ? '重新获取验证码'
                      : visibleError == null
                      ? '登录'
                      : '重试',
                  loading: _loading,
                  onPressed:
                      _loading || !_agreementAccepted || _loginRetrySeconds > 0
                      ? null
                      : _requiresFreshPhoneCode && _phoneMode
                      ? _canRequestPhoneCode
                            ? _requestPhoneCode
                            : null
                      : _submit,
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
              position: Tween(begin: const Offset(0, .035), end: Offset.zero)
                  .animate(
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
