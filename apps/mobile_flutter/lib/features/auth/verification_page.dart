import '../wallet/manual_wallet_page.dart' show walletStepIndicator;
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
  bool _busy = false;
  String? _error;

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
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.verifyCode(code.text);
      if (widget.controller.state.status == RegistrationFlowStatus.completed) {
        if (mounted) widget.onCompleted();
      } else if (widget.controller.state.status ==
          RegistrationFlowStatus.provisioning) {
        if (await widget.controller.pollUntilActive() && mounted) {
          widget.onCompleted();
        }
      }
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法确认状态，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
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
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消')),
          CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext, input.text.trim()),
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
      showWeChatToast(
          context,
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
                  if (widget.controller.isPhoneRegistration)
                    walletStepIndicator(context, const ['填写注册信息', '验证手机号'], 1,
                        keyPrefix: 'phone-registration-step'),
                  const AuthBrandMark(),
                  const SizedBox(height: WeChatSpacing.lg),
                  Text(
                    widget.controller.isPhoneRegistration ? '验证手机号' : '验证邮箱',
                    style: TextStyle(
                      fontSize: WeChatTypography.display,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    widget.controller.isPhoneRegistration
                        ? '请输入短信中的 6 位验证码'
                        : '请输入邮件中的验证码，或返回应用查看验证链接结果。',
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
                    placeholder: widget.controller.isPhoneRegistration
                        ? '短信验证码'
                        : '邮件验证码',
                    enabled: !_busy,
                    keyboardType: TextInputType.text,
                  ),
                  const SizedBox(height: WeChatSpacing.md),
                  SizedBox(
                    width: double.infinity,
                    child: ModernActionButton(
                      key: const Key('auth-verification-verify'),
                      icon: CupertinoIcons.check_mark_circled,
                      label: state.status == RegistrationFlowStatus.provisioning
                          ? '查询开通状态'
                          : '验证并继续',
                      loading: _busy,
                      onPressed: _busy ? null : verify,
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
                          : (widget.controller.isPhoneRegistration
                              ? '重新发送短信'
                              : '重新发送邮件'),
                      kind: ModernActionKind.secondary,
                      onPressed: _busy ||
                              state.status ==
                                  RegistrationFlowStatus.provisioning ||
                              state.resendAfterSeconds > 0
                          ? null
                          : widget.controller.resend,
                    ),
                  ),
                  const SizedBox(height: WeChatSpacing.md),
                  if (!widget.controller.isPhoneRegistration)
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
                  if (_error != null || state.message != null)
                    AuthErrorMessage(message: _error ?? state.message!),
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
