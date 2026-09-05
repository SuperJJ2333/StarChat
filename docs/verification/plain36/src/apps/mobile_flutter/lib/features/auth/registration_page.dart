import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../ui/components/auth_surface_card.dart';
import '../../ui/components/immersive_auth_scaffold.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../../core/business_auth_contracts.dart';
import 'registration_controller.dart';

final class RegistrationPage extends StatefulWidget {
  const RegistrationPage(
      {super.key,
      required this.controller,
      required this.onVerification,
      required this.onBack});
  final RegistrationController controller;
  final ValueChanged<String> onVerification;
  final VoidCallback onBack;
  @override
  State<RegistrationPage> createState() => _RegistrationPageState();
}

final class _RegistrationPageState extends State<RegistrationPage> {
  final nickname = TextEditingController();
  final username = TextEditingController();
  final password = TextEditingController();
  final passwordConfirmation = TextEditingController();
  final invitation = TextEditingController();
  final email = TextEditingController();
  bool _passwordVisible = false;
  bool _confirmationVisible = false;
  bool _submittedAttempted = false;
  // 邀请码校验状态机（BUG 1）：防抖触发、8s 超时、可"重新加载"。
  InvitationValidationState _inviteState = InvitationValidationState.initial;
  String _inviteMessage = '';
  Timer? _inviteDebounce;

  @override
  void initState() {
    super.initState();
    nickname.text = widget.controller.draft.nickname;
    username.text = widget.controller.draft.username;
    password.text = widget.controller.draft.password;
    passwordConfirmation.text = widget.controller.draft.passwordConfirmation;
    invitation.text = widget.controller.draft.invitationCode;
    email.text = widget.controller.draft.email;
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    _inviteDebounce?.cancel();
    widget.controller.removeListener(_changed);
    nickname.dispose();
    username.dispose();
    password.dispose();
    passwordConfirmation.dispose();
    invitation.dispose();
    email.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// 输入防抖 600ms 后自动校验邀请码（避免每个字符都打接口）。
  void _scheduleInvitationCheck() {
    _inviteDebounce?.cancel();
    final code = invitation.text.trim();
    if (code.isEmpty) {
      setState(() {
        _inviteState = InvitationValidationState.initial;
        _inviteMessage = '';
      });
      return;
    }
    _inviteDebounce = Timer(const Duration(milliseconds: 600), () {
      _runInvitationCheck();
    });
  }

  /// 校验一次邀请码：LOADING → 终态；网络/服务端故障提供「重新加载」。
  Future<void> _runInvitationCheck() async {
    final code = invitation.text.trim();
    if (code.isEmpty || _inviteState == InvitationValidationState.loading) {
      return;
    }
    setState(() {
      _inviteState = InvitationValidationState.loading;
      _inviteMessage = '正在验证邀请码…';
    });
    try {
      final result = await widget.controller.gateway
          .validateInvitation(code)
          .timeout(const Duration(seconds: 8));
      if (!mounted) return;
      setState(() {
        _inviteState = result.state;
        _inviteMessage = result.message;
      });
    } catch (error) {
      if (!mounted) return;
      final mapped = mapInvitationFailure(error);
      setState(() {
        _inviteState = mapped.state;
        _inviteMessage = mapped.message;
      });
    }
  }

  /// 邀请码校验状态行：加载中/可用/各失效形态 + 失败可重试。
  Widget _inviteStatusRow() {
    if (_inviteState == InvitationValidationState.initial) {
      return const SizedBox.shrink();
    }
    final color = switch (_inviteState) {
      InvitationValidationState.ready => const Color(0xFF07C160),
      InvitationValidationState.loading => WeChatColors.textSecondary,
      InvitationValidationState.networkError ||
      InvitationValidationState.serverError =>
        WeChatColors.warning,
      _ => WeChatColors.danger,
    };
    final retryable = _inviteState == InvitationValidationState.networkError ||
        _inviteState == InvitationValidationState.serverError;
    return Padding(
      key: const Key('auth-invitation-status'),
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        if (_inviteState == InvitationValidationState.loading)
          const SizedBox(
              width: 12,
              height: 12,
              child: CupertinoActivityIndicator(radius: 6)),
        if (_inviteState == InvitationValidationState.ready)
          const Icon(CupertinoIcons.check_mark,
              size: 13, color: Color(0xFF07C160)),
        if (retryable)
          CupertinoButton(
            key: const Key('auth-invitation-reload'),
            minimumSize: Size.zero,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            onPressed: _runInvitationCheck,
            child: const Text('重新加载',
                style:
                    TextStyle(fontSize: 12, color: WeChatColors.brandPrimary)),
          ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(_inviteMessage,
              style: TextStyle(fontSize: 12, color: color)),
        ),
      ]),
    );
  }

  void _saveDraft() => widget.controller.saveDraft(
        nickname: nickname.text,
        username: username.text,
        password: password.text,
        passwordConfirmation: passwordConfirmation.text,
        invitationCode: invitation.text,
        email: email.text,
      );

  Map<String, String> get _errors => RegistrationController.validateFields(
      nickname: nickname.text,
      username: username.text,
      email: email.text,
      password: password.text,
      passwordConfirmation: passwordConfirmation.text,
      invitationCode: invitation.text);

  bool get _resendCoolingDown =>
      widget.controller.state.registrationSession != null &&
      widget.controller.state.resendAfterSeconds > 0;
  Widget _fieldError(String key) {
    final serverMessage = widget.controller.state.fieldErrors[key];
    final message = serverMessage ?? _errors[key];
    if (message == null ||
        (serverMessage == null &&
            !_submittedAttempted &&
            key != 'password_confirmation')) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: WeChatSpacing.xs),
      child: AuthErrorMessage(
        key: Key('auth-registration-error-$key'),
        message: message,
        compact: true,
      ),
    );
  }

  Future<void> _sendVerification() async {
    if (widget.controller.state.registrationSession != null) {
      await widget.controller.resend();
      return;
    }
    await submit();
  }

  Future<void> submit() async {
    if (_errors.isNotEmpty) {
      setState(() => _submittedAttempted = true);
      return;
    }
    final ok = await widget.controller.register(
        username: username.text.trim(),
        nickname: nickname.text.trim(),
        email: email.text.trim(),
        password: password.text,
        passwordConfirmation: passwordConfirmation.text,
        invitationCode: invitation.text.trim());
    if (ok && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final loading =
        widget.controller.state.status == RegistrationFlowStatus.submitting;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return ImmersiveAuthScaffold(
        child: ListView(
            key: const Key('auth-registration-scroll'),
            padding: EdgeInsets.fromLTRB(WeChatSpacing.xl, 96, WeChatSpacing.xl,
                WeChatSpacing.xl + bottomInset),
            children: [
          Center(
              child: Form(
                  key: const Key('auth-registration-form'),
                  child: AuthSurfaceCard(
                      child: AutofillGroup(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                        const AuthBrandMark(),
                        const SizedBox(height: WeChatSpacing.lg),
                        const Text('创建畅聊账号',
                            style: TextStyle(
                                fontSize: WeChatTypography.display,
                                fontWeight: FontWeight.w700)),
                        const Text('使用邀请码注册安全账号',
                            style: TextStyle(
                                color: WeChatColors.textSecondary,
                                fontSize: WeChatTypography.subhead)),
                        const SizedBox(height: 20),
                        AuthTextField(
                            key: const Key('auth-registration-nickname'),
                            label: '用户名',
                            placeholder: '可填写中文昵称',
                            controller: nickname,
                            enabled: !loading,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) => setState(() {})),
                        _fieldError('nickname'),
                        const SizedBox(height: WeChatSpacing.md),
                        AuthTextField(
                            key: const Key('auth-registration-username'),
                            label: '畅聊号',
                            placeholder: '3-64 位字母、数字、下划线或连字符',
                            controller: username,
                            enabled: !loading,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) => setState(() {})),
                        _fieldError('username'),
                        const SizedBox(height: WeChatSpacing.md),
                        AuthTextField(
                            key: const Key('auth-registration-password'),
                            label: '密码',
                            placeholder: '至少 12 位',
                            controller: password,
                            enabled: !loading,
                            obscureText: !_passwordVisible,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) => setState(() {}),
                            trailing: CupertinoButton(
                                key: const Key(
                                    'auth-registration-password-visibility'),
                                padding: EdgeInsets.zero,
                                onPressed: loading
                                    ? null
                                    : () => setState(() =>
                                        _passwordVisible = !_passwordVisible),
                                child: Icon(
                                    _passwordVisible
                                        ? CupertinoIcons.eye_slash
                                        : CupertinoIcons.eye,
                                    size: 19,
                                    color: WeChatColors.textSecondary))),
                        _fieldError('password'),
                        const SizedBox(height: WeChatSpacing.md),
                        AuthTextField(
                            key:
                                const Key('auth-registration-password-confirm'),
                            label: '再次输入密码',
                            placeholder: '再次输入密码',
                            controller: passwordConfirmation,
                            enabled: !loading,
                            obscureText: !_confirmationVisible,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) => setState(() {}),
                            trailing: CupertinoButton(
                                key: const Key(
                                    'auth-registration-password-confirm-visibility'),
                                padding: EdgeInsets.zero,
                                onPressed: loading
                                    ? null
                                    : () => setState(() =>
                                        _confirmationVisible =
                                            !_confirmationVisible),
                                child: Icon(
                                    _confirmationVisible
                                        ? CupertinoIcons.eye_slash
                                        : CupertinoIcons.eye,
                                    size: 19,
                                    color: WeChatColors.textSecondary))),
                        _fieldError('password_confirmation'),
                        const SizedBox(height: WeChatSpacing.md),
                        AuthTextField(
                            key: const Key('auth-registration-invitation'),
                            label: '邀请码',
                            placeholder: '邀请码（必填）',
                            controller: invitation,
                            enabled: !loading,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) {
                              setState(() {});
                              _scheduleInvitationCheck();
                            }),
                        _inviteStatusRow(),
                        _fieldError('invitation_code'),
                        const SizedBox(height: WeChatSpacing.md),
                        AuthTextField(
                            key: const Key('auth-registration-email'),
                            label: '邮箱',
                            placeholder: 'name@example.invalid',
                            controller: email,
                            enabled: !loading,
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.done,
                            onChanged: (_) => setState(() {}),
                            trailing: CupertinoButton(
                                key: const Key('auth-registration-send-code'),
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                                onPressed: loading || _resendCoolingDown
                                    ? null
                                    : _sendVerification,
                                child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: WeChatSpacing.sm,
                                        vertical: WeChatSpacing.xs),
                                    decoration: BoxDecoration(
                                        color: loading || _resendCoolingDown
                                            ? WeChatColors.textTertiary
                                            : WeChatColors.brandPrimary,
                                        borderRadius: BorderRadius.circular(
                                            WeChatRadius.tag)),
                                    child: Text(
                                        widget.controller.state
                                                    .resendAfterSeconds >
                                                0
                                            ? '${widget.controller.state.resendAfterSeconds}s'
                                            : '发送验证邮件',
                                        style: const TextStyle(
                                            color: CupertinoColors.white,
                                            fontSize: WeChatTypography.caption,
                                            fontWeight: FontWeight.w600))))),
                        _fieldError('email'),
                        if (widget.controller.state.message != null &&
                            widget.controller.state.fieldErrors.isEmpty)
                          Padding(
                            padding:
                                const EdgeInsets.only(top: WeChatSpacing.sm),
                            child: AuthErrorMessage(
                              key: const Key('auth-registration-error'),
                              message: widget.controller.state.message!,
                              compact: true,
                            ),
                          ),
                        if (widget.controller.state.registrationSession !=
                            null) ...[
                          const SizedBox(height: WeChatSpacing.sm),
                          SizedBox(
                              width: double.infinity,
                              child: ModernActionButton(
                                  icon: ChangliaoIcons.confirm,
                                  label: '继续验证邮箱',
                                  onPressed: () => widget.onVerification(widget
                                      .controller.state.registrationSession!))),
                        ],
                        const SizedBox(height: WeChatSpacing.sm),
                        SizedBox(
                            width: double.infinity,
                            child: ModernActionButton(
                                icon: ChangliaoIcons.back,
                                label: '返回登录',
                                kind: ModernActionKind.secondary,
                                onPressed: loading
                                    ? null
                                    : () {
                                        _saveDraft();
                                        widget.onBack();
                                      })),
                      ]))))),
        ]));
  }
}
