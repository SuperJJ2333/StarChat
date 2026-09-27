import 'package:flutter/cupertino.dart';
import '../../core/account_credentials_gateway.dart';
import '../../ui/components/auth_surface_card.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'account_credentials_controller.dart';

final class EmailRebindPage extends StatefulWidget {
  const EmailRebindPage({super.key, required this.gateway});
  final AccountCredentialsGateway gateway;
  @override
  State<EmailRebindPage> createState() => _EmailRebindPageState();
}

final class _EmailRebindPageState extends State<EmailRebindPage> {
  final _operation = AccountCredentialsController();
  final _email = TextEditingController(), _code = TextEditingController();
  bool _oldVerified = false, _done = false;
  String _destination = '当前已验证的邮箱或手机';
  @override
  void initState() {
    super.initState();
    _operation.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _operation.removeListener(_changed);
    _operation.dispose();
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  bool get _validEmail =>
      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(_email.text.trim());
  Future<void> _send() async {
    if (_operation.busy || _operation.cooldown > 0) return;
    if (_oldVerified && !_validEmail) {
      _operation.setMessage('请输入正确的新邮箱地址');
      return;
    }
    _operation.startCooldown();
    await _operation.perform(() async {
      final generation = _operation.generation;
      if (_oldVerified) {
        await widget.gateway.requestEmailRebindNewCode(_email.text.trim());
      } else {
        final receipt = await widget.gateway.requestEmailRebindOldCode();
        if (!mounted || !_operation.isCurrent(generation)) return;
        if (receipt['channel'] != 'email' && receipt['channel'] != 'phone') {
          _operation.setMessage('无法确认现有验证渠道，请联系客服');
          return;
        }
        setState(() => _destination =
            '${receipt['channel'] == 'email' ? '已绑定邮箱' : '已绑定手机'} ${receipt['target'] ?? ''}');
      }
      if (mounted && _operation.isCurrent(generation)) {
        _operation
            .setMessage('验证码请求已受理，请查看${_oldVerified ? '新邮箱' : _destination}');
      }
    });
    _recoverExpiredProof();
  }

  Future<void> _confirm() async {
    if (!RegExp(r'^\d{6}$').hasMatch(_code.text.trim())) {
      _operation.setMessage('请输入 6 位验证码');
      return;
    }
    if (_oldVerified && !_validEmail) {
      _operation.setMessage('请输入正确的新邮箱地址');
      return;
    }
    await _operation.perform(() async {
      final generation = _operation.generation;
      if (_oldVerified) {
        await widget.gateway.confirmEmailRebind(
            email: _email.text.trim(), code: _code.text.trim());
        if (mounted && _operation.isCurrent(generation)) {
          setState(() => _done = true);
        }
      } else {
        await widget.gateway.verifyEmailRebindOldCode(_code.text.trim());
        if (!mounted || !_operation.isCurrent(generation)) return;
        setState(() => _oldVerified = true);
        _code.clear();
        _operation.clearCooldown();
      }
    });
    _recoverExpiredProof();
  }

  void _recoverExpiredProof() {
    if (!mounted || _operation.errorCode != 'REBIND_OLD_VERIFICATION_REQUIRED') {
      return;
    }
    setState(() => _oldVerified = false);
    _code.clear();
    _operation.clearCooldown();
    _operation.setMessage('验证已过期，请重新验证当前身份');
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold(
      title: '绑定或更换邮箱',
      child: SafeArea(
          child: ListView(
              padding: const EdgeInsets.all(WeChatSpacing.lg),
              children: [
            AuthSurfaceCard(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(
                      _done
                          ? '邮箱已更新'
                          : _oldVerified
                              ? '验证新邮箱'
                              : '验证当前身份',
                      style:
                          const TextStyle(fontSize: WeChatTypography.title2)),
                  const SizedBox(height: WeChatSpacing.md),
                  if (_done)
                    ModernActionButton(
                        icon: CupertinoIcons.check_mark,
                        label: '完成',
                        onPressed: () => Navigator.of(context).pop(true))
                  else ...[
                    Text(_oldVerified
                        ? '新邮箱验证成功后才可用于登录和找回密码。'
                        : '请先验证$_destination，再绑定新邮箱。'),
                    const SizedBox(height: WeChatSpacing.md),
                    if (_oldVerified) ...[
                      AuthTextField(
                          key: const Key('email-rebind-email'),
                          label: '新邮箱',
                          placeholder: '输入新邮箱地址',
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          enabled:
                              !_operation.busy && _operation.cooldown == 0),
                      const SizedBox(height: WeChatSpacing.md)
                    ],
                    AuthTextField(
                        key: const Key('email-rebind-code'),
                        label: '验证码',
                        placeholder: '输入 6 位验证码',
                        controller: _code,
                        keyboardType: TextInputType.number,
                        enabled: !_operation.busy,
                        trailing: CupertinoButton(
                            key: const Key('email-rebind-send'),
                            padding: const EdgeInsets.symmetric(
                                horizontal: WeChatSpacing.sm),
                            onPressed:
                                _operation.busy || _operation.cooldown > 0
                                    ? null
                                    : _send,
                            child: Text(_operation.cooldown > 0
                                ? '${_operation.cooldown}s'
                                : '获取验证码'))),
                    const SizedBox(height: WeChatSpacing.lg),
                    ModernActionButton(
                        key: const Key('email-rebind-confirm'),
                        icon: CupertinoIcons.check_mark,
                        label: _oldVerified ? '确认绑定' : '下一步',
                        loading: _operation.busy,
                        onPressed: _operation.busy ? null : _confirm),
                  ],
                  if (_operation.message != null) ...[
                    const SizedBox(height: WeChatSpacing.md),
                    AuthErrorMessage(message: _operation.message!)
                  ],
                ])),
          ])));
}
