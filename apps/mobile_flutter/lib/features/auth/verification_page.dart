import 'package:flutter/cupertino.dart';

import '../../ui/components/auth_surface_card.dart';
import '../../ui/components/immersive_auth_scaffold.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'registration_controller.dart';

final class VerificationPage extends StatefulWidget {
  const VerificationPage({
    super.key,
    required this.controller,
    required this.onChangeEmail,
    required this.onCompleted,
  });

  final RegistrationController controller;
  final VoidCallback onChangeEmail;
  final VoidCallback onCompleted;

  @override
  State<VerificationPage> createState() => _VerificationPageState();
}

final class _VerificationPageState extends State<VerificationPage> {
  final code = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_change);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_change);
    code.dispose();
    super.dispose();
  }

  void _change() {
    if (mounted) setState(() {});
  }

  Future<void> verify() async {
    await widget.controller.verifyCode(code.text);
    if (await widget.controller.pollUntilActive() && mounted) {
      widget.onCompleted();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return ImmersiveAuthScaffold(
      child: ListView(
        key: const Key('auth-verification-scroll'),
        padding: EdgeInsets.fromLTRB(
          WeChatSpacing.xl,
          120,
          WeChatSpacing.xl,
          WeChatSpacing.xl + bottomInset,
        ),
        children: [
          Center(
            child: AuthSurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const AuthBrandMark(),
                  const SizedBox(height: WeChatSpacing.lg),
                  const Text(
                    '验证邮箱',
                    style: TextStyle(
                      fontSize: WeChatTypography.display,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: WeChatSpacing.sm),
                  const Text(
                    '请输入邮件中的 6 位验证码，或返回应用查看验证链接结果。',
                    style: TextStyle(color: WeChatColors.textSecondary),
                  ),
                  const SizedBox(height: WeChatSpacing.lg),
                  CupertinoTextField(
                    controller: code,
                    placeholder: '6 位验证码',
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                  ),
                  const SizedBox(height: WeChatSpacing.md),
                  SizedBox(
                    width: double.infinity,
                    child: ModernActionButton(
                      icon: CupertinoIcons.check_mark_circled,
                      label: '验证并继续',
                      onPressed: verify,
                    ),
                  ),
                  const SizedBox(height: WeChatSpacing.sm),
                  SizedBox(
                    width: double.infinity,
                    child: ModernActionButton(
                      icon: CupertinoIcons.mail,
                      label: state.resendAfterSeconds > 0
                          ? '${state.resendAfterSeconds} 秒后重发'
                          : '重新发送邮件',
                      kind: ModernActionKind.secondary,
                      onPressed: state.resendAfterSeconds > 0
                          ? null
                          : widget.controller.resend,
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: ModernActionButton(
                      icon: CupertinoIcons.pencil,
                      label: '修改邮箱',
                      kind: ModernActionKind.secondary,
                      onPressed: widget.onChangeEmail,
                    ),
                  ),
                  const SizedBox(height: WeChatSpacing.md),
                  Text(
                    state.status == RegistrationFlowStatus.provisioning
                        ? '正在创建加密通信账号…'
                        : state.status == RegistrationFlowStatus.completed
                            ? '账号已就绪'
                            : '等待邮箱验证',
                    key: const Key('registration-status'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
