import 'package:flutter/cupertino.dart';

import '../../ui/components/auth_surface_card.dart';
import '../../ui/components/immersive_auth_scaffold.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'registration_controller.dart';

final class RegistrationPage extends StatefulWidget {
  const RegistrationPage({
    super.key,
    required this.controller,
    required this.onVerification,
    required this.onBack,
  });

  final RegistrationController controller;
  final ValueChanged<String> onVerification;
  final VoidCallback onBack;

  @override
  State<RegistrationPage> createState() => _RegistrationPageState();
}

final class _RegistrationPageState extends State<RegistrationPage> {
  final username = TextEditingController();
  final email = TextEditingController();
  final password = TextEditingController();
  final invitation = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    username.dispose();
    email.dispose();
    password.dispose();
    invitation.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> submit() async {
    if (invitation.text.trim().isEmpty) return;
    final ok = await widget.controller.register(
      username: username.text.trim(),
      email: email.text.trim(),
      password: password.text,
      invitationCode: invitation.text.trim(),
    );
    if (ok && mounted) {
      widget.onVerification(widget.controller.state.registrationSession!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loading =
        widget.controller.state.status == RegistrationFlowStatus.submitting;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return ImmersiveAuthScaffold(
      child: ListView(
        key: const Key('auth-registration-scroll'),
        padding: EdgeInsets.fromLTRB(
          WeChatSpacing.xl,
          96,
          WeChatSpacing.xl,
          WeChatSpacing.xl + bottomInset,
        ),
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
                      const Text(
                        '创建畅聊账号',
                        style: TextStyle(
                          fontSize: WeChatTypography.display,
                          fontWeight: FontWeight.w700,
                          height: 36 / 28,
                          letterSpacing: -1,
                        ),
                      ),
                      const Text(
                        '使用邀请码注册安全账号',
                        style: TextStyle(
                          color: WeChatColors.textSecondary,
                          fontSize: WeChatTypography.subhead,
                          height: 20 / 14,
                        ),
                      ),
                      const SizedBox(height: 20),
                      AuthTextField(
                        key: const Key('auth-registration-username'),
                        label: '用户名',
                        placeholder: '设置用户名',
                        controller: username,
                        enabled: !loading,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.newUsername],
                      ),
                      const SizedBox(height: WeChatSpacing.md),
                      AuthTextField(
                        key: const Key('auth-registration-email'),
                        label: '邮箱',
                        placeholder: 'name@example.invalid',
                        controller: email,
                        enabled: !loading,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.email],
                      ),
                      const SizedBox(height: WeChatSpacing.md),
                      AuthTextField(
                        key: const Key('auth-registration-password'),
                        label: '密码',
                        placeholder: '设置密码',
                        controller: password,
                        enabled: !loading,
                        obscureText: true,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.newPassword],
                      ),
                      const SizedBox(height: WeChatSpacing.md),
                      AuthTextField(
                        key: const Key('auth-registration-invitation'),
                        label: '邀请码',
                        placeholder: '邀请码（必填）',
                        controller: invitation,
                        enabled: !loading,
                        textInputAction: TextInputAction.done,
                        onChanged: (_) => setState(() {}),
                      ),
                      for (final error
                          in widget.controller.state.fieldErrors.values) ...[
                        const SizedBox(height: WeChatSpacing.sm),
                        Text(
                          error,
                          style: const TextStyle(
                            color: WeChatColors.danger,
                            fontSize: WeChatTypography.caption,
                          ),
                        ),
                      ],
                      if (widget.controller.state.message != null) ...[
                        const SizedBox(height: WeChatSpacing.sm),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            widget.controller.state.message!,
                            key: const Key('auth-registration-error'),
                            style: const TextStyle(
                              color: WeChatColors.danger,
                              fontSize: WeChatTypography.caption,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: WeChatSpacing.md),
                      SizedBox(
                        width: double.infinity,
                        child: ModernActionButton(
                          icon: ChangliaoIcons.add,
                          label: '创建账号',
                          loading: loading,
                          onPressed: loading || invitation.text.trim().isEmpty
                              ? null
                              : submit,
                        ),
                      ),
                      const SizedBox(height: WeChatSpacing.sm),
                      SizedBox(
                        width: double.infinity,
                        child: ModernActionButton(
                          icon: ChangliaoIcons.back,
                          label: '返回登录',
                          kind: ModernActionKind.secondary,
                          onPressed: loading ? null : widget.onBack,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
