import 'package:flutter/cupertino.dart';

import '../../core/business_api_error.dart';
import '../../ui/components/auth_surface_card.dart';
import '../../ui/components/immersive_auth_scaffold.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/components/wechat_toast.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'registration_controller.dart';

final class VerificationPage extends StatefulWidget {
  const VerificationPage({
    super.key,
    required this.controller,
    required this.onCompleted,
  });

  final RegistrationController controller;
  final VoidCallback onCompleted;

  @override
  State<VerificationPage> createState() => _VerificationPageState();
}

final class _VerificationPageState extends State<VerificationPage> {
  final code = TextEditingController();

  @override
  void initState() {
    super.initState();
    code.text = widget.controller.verificationCodeHint ?? '';
    code.addListener(_clearCodeError);
    widget.controller.addListener(_change);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_change);
    code.removeListener(_clearCodeError);
    code.dispose();
    super.dispose();
  }

  void _clearCodeError() => widget.controller.clearVerificationCodeError();

  void _change() {
    if (mounted) setState(() {});
  }

  Future<void> verify() async {
    await widget.controller.verifyCode(code.text);
    if (widget.controller.state.status != RegistrationFlowStatus.provisioning) {
      return;
    }
    if (await widget.controller.pollUntilActive() && mounted) {
      widget.onCompleted();
    }
  }

  Future<void> _changeEmail() async {
    final input = TextEditingController();
    final newEmail = await showCupertinoDialog<String>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('修改邮箱'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('新的验证码将发送到新邮箱'),
          const SizedBox(height: WeChatSpacing.sm),
          CupertinoTextField(
            controller: input,
            autofocus: true,
            keyboardType: TextInputType.emailAddress,
            placeholder: '新邮箱地址',
          ),
        ]),
        actions: [
          CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
          CupertinoDialogAction(
              onPressed: () =>
                  Navigator.pop(dialogContext, input.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    input.dispose();
    if (newEmail == null || newEmail.isEmpty || !mounted) return;
    try {
      await widget.controller.changeEmail(newEmail);
      if (!mounted) return;
      showWeChatToast(context, '验证邮件已发送至新邮箱',
          semanticType: WeChatToastSemanticType.success);
    } on BusinessApiException catch (failure) {
      if (!mounted) return;
      showWeChatToast(context,
          failure.statusCode == 409
              ? '该邮箱已被使用'
              : (failure.message.isEmpty ? '修改邮箱失败，请稍后重试' : failure.message),
          semanticType: WeChatToastSemanticType.error);
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
                  const Text(
                    '请输入邮件中的验证码，或返回应用查看验证链接结果。',
                    style: TextStyle(color: WeChatColors.textSecondary),
                  ),
                  const SizedBox(height: WeChatSpacing.lg),
                  if (state.fieldErrors['code'] case final error?) ...[
                    AuthErrorMessage(
                      key: const Key('auth-verification-code-error'),
                      message: error,
                    ),
                    const SizedBox(height: WeChatSpacing.sm),
                  ],
                  CupertinoTextField(
                    controller: code,
                    placeholder: '邮件验证码',
                    keyboardType: TextInputType.text,
                  ),
                  const SizedBox(height: WeChatSpacing.md),
                  SizedBox(
                    width: double.infinity,
                    child: ModernActionButton(
                      key: const Key('auth-verification-verify'),
                      icon: CupertinoIcons.check_mark_circled,
                      label: '验证并继续',
                      onPressed: verify,
                    ),
                  ),
                  const SizedBox(height: WeChatSpacing.md),
                  SizedBox(
                    width: double.infinity,
                    child: ModernActionButton(
                      key: const Key('auth-verification-resend'),
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
                  const SizedBox(height: WeChatSpacing.md),
                  SizedBox(
                    width: double.infinity,
                    child: ModernActionButton(
                      key: const Key('auth-verification-change-email'),
                      icon: CupertinoIcons.pencil,
                      label: '修改邮箱',
                      kind: ModernActionKind.secondary,
                      // BUG-12：验证完成前可在原地更换邮箱（服务端把验证码
                      // 发到新邮箱，注册会话保持不变），不再退回注册页。
                      onPressed: _changeEmail,
                    ),
                  ),
                  if (state.status == RegistrationFlowStatus.provisioning ||
                      state.status == RegistrationFlowStatus.completed) ...[
                    const SizedBox(height: WeChatSpacing.md),
                    Text(
                      state.status == RegistrationFlowStatus.provisioning
                          ? '正在创建加密通信账号…'
                          : '账号已就绪',
                      key: const Key('registration-status'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
