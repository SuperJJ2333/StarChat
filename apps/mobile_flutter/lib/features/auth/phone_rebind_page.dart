import '../../ui/components/wechat_scaffold.dart';
import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../../core/business_api_error.dart';
import '../../core/business_phone_contracts.dart';
import '../../ui/components/auth_surface_card.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../wallet/manual_wallet_page.dart' show walletStepIndicator;

/// Two server-authorized stages. Opening the page never sends a message.
final class PhoneRebindPage extends StatefulWidget {
  const PhoneRebindPage({super.key, required this.api});
  final PhoneAuthGateway api;
  @override
  State<PhoneRebindPage> createState() => _PhoneRebindPageState();
}

final class _PhoneRebindPageState extends State<PhoneRebindPage> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  int _step = 0;
  int _cooldown = 0;
  Timer? _timer;
  bool _busy = false;
  bool _done = false;
  String? _message;
  String _channel = '当前绑定的手机或邮箱';
  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on BusinessApiException catch (error) {
      if (mounted) setState(() => _message = _failureMessage(error));
    } catch (_) {
      if (mounted) setState(() => _message = '请求结果待确认，请稍后重试或联系客服');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _failureMessage(BusinessApiException error) {
    if (error.statusCode == 404 || error.statusCode == 405) {
      return '当前服务暂不支持手机号换绑，请联系客服';
    }
    switch (error.code) {
      case 'PHONE_AUTH_DISABLED':
        return '手机号功能暂未开启，请联系客服';
      case 'SMS_NOT_CONFIGURED':
      case 'SMS_SEND_REJECTED':
        return '短信服务暂不可用，请联系客服';
      case 'SMS_PROVIDER_TIMEOUT':
      case 'SMS_SEND_UNKNOWN':
        return '请求结果待确认，请稍后重试或联系客服';
      case 'SMS_VERIFY_UNAVAILABLE':
        return '验证码校验暂不可用，请稍后重试';
    }
    if (error.message.isNotEmpty && error.message != '业务请求失败') {
      return error.message;
    }
    return error.statusCode >= 500
        ? '验证服务暂不可用，请稍后重试或联系客服'
        : '验证请求未被接受，请稍后重试或联系客服';
  }

  void _startCooldown() {
    _cooldown = 60;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _cooldown--);
      if (_cooldown <= 0) timer.cancel();
    });
  }

  Future<void> _send() => _perform(() async {
        if (_cooldown > 0) return;
        if (_step == 1 &&
            !RegExp(r'^1[3-9]\d{9}$').hasMatch(_phone.text.trim())) {
          setState(() => _message = '请输入中国大陆 11 位手机号');
          return;
        }
        // A lost response can still mean a message was sent. Keep the cooldown.
        setState(_startCooldown);
        if (_step == 0) {
          final receipt = await widget.api
              .rebindOldRequest()
              .timeout(const Duration(seconds: 8));
          if (!mounted) return;
          final channel = switch (receipt['channel']) {
            'email' => '当前绑定邮箱',
            'phone' => '当前绑定手机',
            _ => null,
          };
          if (channel == null) {
            setState(() => _message = '暂时无法确认验证方式，请稍后重试或联系客服');
            return;
          }
          setState(() => _channel = channel);
        } else {
          await widget.api
              .rebindNewRequest(phone: _phone.text.trim())
              .timeout(const Duration(seconds: 8));
        }
        if (mounted) setState(() => _message = '验证码请求已受理，请查看$_channel');
      });

  Future<void> _confirm() => _perform(() async {
        if (!RegExp(r'^\d{6}$').hasMatch(_code.text.trim())) {
          setState(() => _message = '请输入 6 位验证码');
          return;
        }
        if (_step == 0) {
          await widget.api
              .rebindOldConfirm(code: _code.text.trim())
              .timeout(const Duration(seconds: 8));
          if (!mounted) return;
          _timer?.cancel();
          setState(() {
            _step = 1;
            _cooldown = 0;
            _code.clear();
            _channel = '新手机号';
          });
        } else {
          await widget.api
              .rebindNewConfirm(
                  phone: _phone.text.trim(), code: _code.text.trim())
              .timeout(const Duration(seconds: 8));
          if (mounted) setState(() => _done = true);
        }
      });

  @override
  Widget build(BuildContext context) => WeChatPageScaffold(
        title: '绑定 / 更换手机号',
        child: SafeArea(
            child: ListView(padding: const EdgeInsets.all(20), children: [
          walletStepIndicator(context, const ['验证当前身份', '绑定新手机号'], _step,
              keyPrefix: 'phone-rebind-step'),
          const SizedBox(height: 24),
          AuthSurfaceCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(
                    _done
                        ? '手机号已更新'
                        : _step == 0
                            ? '验证当前身份'
                            : '绑定新手机号',
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                Text(
                    _done
                        ? '新手机号可用于短信登录。'
                        : _step == 0
                            ? '验证码将发送至$_channel。验证通过后才能更换手机号。'
                            : '请输入新的中国大陆手机号。',
                    style: const TextStyle(color: WeChatColors.textSecondary)),
                if (!_done) ...[
                  const SizedBox(height: WeChatSpacing.sm),
                  const Text('请输入畅聊 ChatFlow 验证码',
                      style: TextStyle(
                          fontSize: WeChatTypography.caption,
                          color: WeChatColors.textSecondary)),
                  const SizedBox(height: 20),
                  if (_step == 1) ...[
                    AuthTextField(
                        key: const Key('phone-rebind-phone'),
                        label: '新手机号',
                        placeholder: '中国大陆 +86',
                        controller: _phone,
                        enabled: !_busy && _cooldown == 0,
                        keyboardType: TextInputType.phone),
                    const SizedBox(height: 16),
                  ],
                  AuthTextField(
                      key: const Key('phone-rebind-code'),
                      label: '验证码',
                      placeholder: '输入 6 位验证码',
                      controller: _code,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      trailing: CupertinoButton(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          onPressed: _busy || _cooldown > 0 ? null : _send,
                          child:
                              Text(_cooldown > 0 ? '${_cooldown}s' : '获取验证码'))),
                  const SizedBox(height: 20),
                  SizedBox(
                      width: double.infinity,
                      child: ModernActionButton(
                          key: const Key('phone-rebind-confirm'),
                          icon: CupertinoIcons.check_mark,
                          label: _step == 0 ? '下一步' : '确认绑定',
                          loading: _busy,
                          onPressed: _busy ? null : _confirm)),
                ],
                if (_message != null) ...[
                  const SizedBox(height: 12),
                  AuthErrorMessage(message: _message!)
                ],
                if (_done)
                  CupertinoButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('完成')),
              ])),
        ])),
      );
}
