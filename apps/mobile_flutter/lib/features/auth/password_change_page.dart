import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../../core/business_auth_contracts.dart';
import '../../core/account_credentials_gateway.dart';
import '../../ui/components/auth_surface_card.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'account_credentials_controller.dart';

/// Both authenticated password changes and forgotten-password recovery use this
/// exact page. Only a successful business proof opens the new-password step.
final class PasswordChangePage extends StatefulWidget {
  const PasswordChangePage(
      {super.key,
      required this.gateway,
      required this.onCompleted,
      this.authenticated = false,
      this.security});
  final AccountCredentialsGateway gateway;
  final Future<void> Function() onCompleted;
  final bool authenticated;
  final AccountSecurityData? security;
  @override
  State<PasswordChangePage> createState() => _PasswordChangePageState();
}

final class _PasswordChangePageState extends State<PasswordChangePage> {
  late final _operation = AccountCredentialsController(owner: widget.gateway);
  final _target = TextEditingController(), _code = TextEditingController();
  final _password = TextEditingController(),
      _confirmation = TextEditingController();
  String _channel = 'email';
  String? _proof;
  bool _done = false;
  DateTime? _proofExpiry;
  Timer? _proofTimer;
  StreamSubscription<BusinessSessionInvalidation>? _invalidationSubscription;
  bool _completionCalled = false;
  bool _resetStarted = false;
  int? _resetEpoch;
  late final Future<void> Function() _onCompleted = widget.onCompleted;
  Future<void> _complete() async {
    if (_completionCalled) return;
    final gateway = widget.gateway;
    if (widget.authenticated &&
        gateway is BusinessSessionMonitor &&
        (gateway as BusinessSessionMonitor).sessionEpoch !=
            (_resetEpoch ?? -2) + 1) {
      return;
    }
    _completionCalled = true;
    await _onCompleted();
  }

  @override
  void initState() {
    super.initState();
    if (widget.security?.canUseEmail == false &&
        widget.security?.canUsePhone == true) {
      _channel = 'phone';
    }
    _operation.addListener(_changed);
    _bindCooldown();
    _target.addListener(_bindCooldown);
    final gateway = widget.gateway;
    if (widget.authenticated && gateway is BusinessSessionMonitor) {
      _invalidationSubscription = (gateway as BusinessSessionMonitor)
          .sessionInvalidations
          .listen((event) {
        if (_resetStarted &&
            event.code == 'PASSWORD_CHANGED' &&
            event.epoch == (_resetEpoch ?? -2) + 1) {
          unawaited(_complete());
        }
      });
    }
  }

  void _bindCooldown() => _operation.bindCooldown(
      purpose: 'password_recovery',
      channel: _channel,
      target: _normalizedTarget() ?? _target.text,
      authenticated: widget.authenticated);
  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _operation.removeListener(_changed);
    _operation.dispose();
    _proofTimer?.cancel();
    unawaited(_invalidationSubscription?.cancel());
    _target.dispose();
    _code.dispose();
    _password.dispose();
    _confirmation.dispose();
    _proof = null;
    super.dispose();
  }

  bool get _available =>
      widget.security == null ||
      widget.security!.canUseEmail ||
      widget.security!.canUsePhone;
  String? _normalizedTarget() {
    if (_channel == 'email') {
      final value = _target.text.trim();
      return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value)
          ? value
          : null;
    }
    var value = _target.text.replaceAll(RegExp(r'[\s\-()]'), '');
    if (value.startsWith('+86')) {
      value = value.substring(3);
    } else if (value.startsWith('86') && value.length == 13) {
      value = value.substring(2);
    }
    return RegExp(r'^1[3-9]\d{9}$').hasMatch(value) ? value : null;
  }

  Future<void> _send() async {
    if (_operation.cooldown > 0 || _operation.busy) return;
    final target = _normalizedTarget();
    if (target == null) {
      _operation
          .setMessage('请输入有效的已绑定${_channel == 'email' ? '邮箱' : '中国大陆手机号'}');
      return;
    }
    _bindCooldown();
    if (!_operation.reserveCooldown()) return;
    await _operation.perform(() async {
      final generation = _operation.generation;
      final seconds = await widget.gateway.requestPasswordCode(
          channel: _channel,
          target: target,
          authenticated: widget.authenticated);
      if (!mounted || !_operation.isCurrent(generation)) return;
      _operation.startCooldown(seconds > 60 ? seconds : 60);
      _operation
          .setMessage('验证码请求已受理，请查看已绑定的${_channel == 'email' ? '邮箱' : '手机'}');
    }, sendingCode: true);
  }

  Future<void> _verify() async {
    final target = _normalizedTarget();
    if (target == null || !RegExp(r'^\d{6}$').hasMatch(_code.text.trim())) {
      _operation.setMessage('请输入有效联系方式和 6 位验证码');
      return;
    }
    await _operation.perform(() async {
      final generation = _operation.generation;
      final proof = await widget.gateway.verifyPasswordCode(
          channel: _channel,
          target: target,
          code: _code.text.trim(),
          authenticated: widget.authenticated);
      if (!mounted || !_operation.isCurrent(generation) || proof.isEmpty) {
        return;
      }
      setState(() {
        _proof = proof;
        _proofExpiry = DateTime.now().add(const Duration(minutes: 5));
      });
      _proofTimer?.cancel();
      _proofTimer = Timer(const Duration(minutes: 5), () {
        if (!mounted || _done) return;
        _password.clear();
        _confirmation.clear();
        setState(() {
          _proof = null;
          _proofExpiry = null;
        });
        _operation.setMessage('验证已过期，请重新获取验证码');
      });
      _code.clear();
      _operation.clearCooldown();
    });
  }

  Future<void> _submit() async {
    if (_password.text.length < 12 || _password.text.length > 256) {
      _operation.setMessage('密码需为 12–256 位');
      return;
    }
    if (_password.text != _confirmation.text) {
      _operation.setMessage('两次输入的密码不一致');
      return;
    }
    if (_proof == null || !DateTime.now().isBefore(_proofExpiry!)) {
      _operation.setMessage('验证已过期，请返回重新获取验证码');
      return;
    }
    await _operation.perform(() async {
      _resetStarted = true;
      final gateway = widget.gateway;
      if (gateway is BusinessSessionMonitor) {
        _resetEpoch = (gateway as BusinessSessionMonitor).sessionEpoch;
      }
      await widget.gateway.resetPassword(
          token: _proof!,
          newPassword: _password.text,
          authenticated: widget.authenticated);
      _proof = null;
      _proofTimer?.cancel();
      if (mounted) {
        _password.clear();
        _confirmation.clear();
        setState(() => _done = true);
      }
      // Reset can settle after timeout or navigation. Lifecycle completion must
      // follow server success even after the form has been disposed.
      await _complete();
    });
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold(
      title: '更换密码',
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
                          ? '密码已更换'
                          : _proof == null
                              ? '验证已绑定的联系方式'
                              : '设置新密码',
                      style:
                          const TextStyle(fontSize: WeChatTypography.title2)),
                  const SizedBox(height: WeChatSpacing.md),
                  if (_done)
                    const Text('请使用新密码重新登录。本地聊天记录已保留。')
                  else if (!_available)
                    const Text('当前账号没有可用的已验证联系方式，请联系客服。')
                  else if (_proof == null) ...[
                    if (widget.security != null &&
                        !(widget.security!.canUseEmail &&
                            widget.security!.canUsePhone))
                      Text(_channel == 'email' ? '通过邮箱验证' : '通过手机号验证')
                    else
                      CupertinoSlidingSegmentedControl<String>(
                          groupValue: _channel,
                          children: {
                            if (widget.security == null ||
                                widget.security!.canUseEmail)
                              'email': const Text('邮箱'),
                            if (widget.security == null ||
                                widget.security!.canUsePhone)
                              'phone': const Text('手机号'),
                          },
                          onValueChanged: (value) {
                            if (value != null &&
                                !_operation.busy &&
                                _operation.cooldown == 0) {
                              setState(() {
                                _channel = value;
                                _target.clear();
                                _code.clear();
                              });
                            }
                          }),
                    const SizedBox(height: WeChatSpacing.md),
                    AuthTextField(
                        key: const Key('password-target'),
                        label: _channel == 'email' ? '已绑定邮箱' : '已绑定手机号',
                        placeholder:
                            _channel == 'email' ? '输入完整邮箱地址' : '中国大陆 +86',
                        controller: _target,
                        enabled: !_operation.busy && _operation.cooldown == 0,
                        keyboardType: _channel == 'email'
                            ? TextInputType.emailAddress
                            : TextInputType.phone),
                    const SizedBox(height: WeChatSpacing.md),
                    AuthTextField(
                        key: const Key('password-code'),
                        label: '验证码',
                        placeholder: '输入 6 位验证码',
                        controller: _code,
                        enabled: !_operation.busy,
                        keyboardType: TextInputType.number,
                        trailing: CupertinoButton(
                            key: const Key('password-send-code'),
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
                        key: const Key('password-verify'),
                        icon: CupertinoIcons.check_mark,
                        label: '下一步',
                        loading: _operation.busy,
                        onPressed: _operation.busy ? null : _verify),
                  ] else ...[
                    AuthTextField(
                        key: const Key('password-new'),
                        label: '新密码',
                        placeholder: '12–256 位密码',
                        controller: _password,
                        enabled: !_operation.busy,
                        obscureText: true,
                        autofillHints: const [AutofillHints.newPassword]),
                    const SizedBox(height: WeChatSpacing.md),
                    AuthTextField(
                        key: const Key('password-confirmation'),
                        label: '确认密码',
                        placeholder: '再次输入新密码',
                        controller: _confirmation,
                        enabled: !_operation.busy,
                        obscureText: true),
                    const SizedBox(height: WeChatSpacing.lg),
                    ModernActionButton(
                        key: const Key('password-submit'),
                        icon: CupertinoIcons.lock,
                        label: '确认更换',
                        loading: _operation.busy,
                        onPressed: _operation.busy ? null : _submit),
                  ],
                  if (_operation.message != null) ...[
                    const SizedBox(height: WeChatSpacing.md),
                    AuthErrorMessage(message: _operation.message!)
                  ],
                  const SizedBox(height: WeChatSpacing.md),
                  const Text('验证码仅恢复登录权，聊天历史仍需本机加密密钥。',
                      style: TextStyle(
                          fontSize: WeChatTypography.caption,
                          color: WeChatColors.textSecondary)),
                ])),
          ])));
}
