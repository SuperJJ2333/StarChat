import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../../ui/components/wechat_scaffold.dart';

/// Only explicitly safe, user-facing server messages belong here.
class PaymentPinException implements Exception {
  const PaymentPinException(this.message);
  final String message;
}

Future<bool> showPaymentPinSetup(
  BuildContext context, {
  required Future<void> Function(String pin, String loginPassword) onSetup,
  Future<bool> Function()? isScopeCurrent,
}) async =>
    await Navigator.of(context, rootNavigator: true).push<bool>(
      CupertinoPageRoute(
          builder: (_) => PaymentPinPage.setup(
              onSetup: onSetup, isScopeCurrent: isScopeCurrent),
          fullscreenDialog: true),
    ) ??
    false;

Future<String?> showPaymentPinAuthorization(
  BuildContext context, {
  required String title,
  required String recipient,
  required String amount,
  String? fee,
  required Future<String> Function(String pin) onAuthorize,
  Future<bool> Function()? isScopeCurrent,
}) =>
    Navigator.of(context, rootNavigator: true).push<String>(
      CupertinoPageRoute(
          builder: (_) => PaymentPinPage.authorize(
              title: title,
              recipient: recipient,
              amount: amount,
              fee: fee,
              onAuthorize: onAuthorize,
              isScopeCurrent: isScopeCurrent),
          fullscreenDialog: true),
    );

class PaymentPinPage extends StatefulWidget {
  const PaymentPinPage.authorize(
      {super.key,
      required this.title,
      required this.recipient,
      required this.amount,
      this.fee,
      required this.onAuthorize,
      this.isScopeCurrent})
      : onSetup = null;
  const PaymentPinPage.setup(
      {super.key, required this.onSetup, this.isScopeCurrent})
      : title = '设置支付密码',
        recipient = '',
        amount = '',
        fee = null,
        onAuthorize = null;
  final String title, recipient, amount;
  final String? fee;
  final Future<void> Function(String, String)? onSetup;
  final Future<String> Function(String)? onAuthorize;
  final Future<bool> Function()? isScopeCurrent;
  @override
  State<PaymentPinPage> createState() => _PaymentPinPageState();
}

class _PaymentPinPageState extends State<PaymentPinPage>
    with WidgetsBindingObserver {
  final _password = TextEditingController();
  String _pin = '', _first = '';
  String? _error;
  int _step = 0;
  bool _busy = false, _closed = false;
  bool get _setup => widget.onSetup != null;
  bool get _login => _setup && _step == 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _closed = true;
    _pin = '';
    _first = '';
    _password.clear();
    _password.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      if (mounted) {
        setState(() {
          _pin = '';
        });
      }
    } else {
      unawaited(_scope());
    }
  }

  Future<bool> _scope() async {
    bool valid;
    try {
      valid = await widget.isScopeCurrent?.call() ?? true;
    } catch (_) {
      valid = false;
    }
    if (!mounted || _closed) return false;
    if (!valid) {
      _close();
      return false;
    }
    return true;
  }

  void _close([Object? result]) {
    if (_closed) return;
    _closed = true;
    _pin = '';
    _first = '';
    _password.clear();
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(result);
    } else if (mounted) {
      setState(() {});
    }
  }

  void _key(String value) {
    if (_busy || _closed) return;
    setState(() {
      _error = null;
      if (value == 'clear') {
        _pin = '';
      } else if (value == 'delete') {
        if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
      } else if (RegExp(r'^[0-9]$').hasMatch(value) && _pin.length < 6) {
        _pin += value;
      }
    });
  }

  Future<void> _submit() async {
    if (_busy ||
        _closed ||
        (_login ? _password.text.isEmpty : _pin.length != 6)) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await _scope()) return;
      if (_login) {
        FocusManager.instance.primaryFocus?.unfocus();
        setState(() {
          _step = 1;
        });
      } else if (_setup && _step == 1) {
        setState(() {
          _first = _pin;
          _pin = '';
          _step = 2;
        });
      } else if (_setup && _pin != _first) {
        setState(() {
          _pin = '';
          _error = '两次密码不一致，请重新输入';
        });
      } else {
        final pin = _pin;
        Object result;
        if (_setup) {
          await widget.onSetup!(pin, _password.text);
          result = true;
        } else {
          result = await widget.onAuthorize!(pin);
        }
        if (await _scope()) _close(result);
      }
    } catch (error) {
      if (mounted && !_closed) {
        setState(() {
          _pin = '';
          _error = error is PaymentPinException ? error.message : '操作未完成，请稍后重试';
          if (_setup) {
            _first = '';
            _step = 0;
            _password.clear();
          }
        });
      }
    } finally {
      if (mounted && !_closed) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final foreground = CupertinoColors.label.resolveFrom(context);
    final page = WeChatPageScaffold.navigation(
      backgroundColor: WeChatColors.pageBackground(context),
      navigationBar: CupertinoNavigationBar(
        middle: Text(widget.title),
        automaticallyImplyLeading: false,
        leading: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () => _close(),
            child: const Text('取消')),
      ),
      child: _closed
          ? const SizedBox.shrink()
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (_setup) ...[
                      const Icon(CupertinoIcons.lock_shield, size: 38),
                      const SizedBox(height: 16),
                      Text(
                          _login
                              ? '确认是你本人'
                              : _step == 1
                                  ? '设置6位数字支付密码'
                                  : '再次输入支付密码',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 21, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      Text(_login ? '请输入登录密码，验证身份后设置支付密码' : '用于发红包和转账，请妥善保管',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 14,
                              color: CupertinoColors.secondaryLabel
                                  .resolveFrom(context))),
                    ] else ...[
                      Text(widget.recipient, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      Text(widget.amount,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 32, fontWeight: FontWeight.w600)),
                      if (widget.fee != null)
                        Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child:
                                Text(widget.fee!, textAlign: TextAlign.center)),
                      const SizedBox(height: 20),
                      const Text('请输入支付密码'),
                    ],
                    const SizedBox(height: 20),
                    if (_login)
                      CupertinoTextField(
                        key: const ValueKey('payment-login-password'),
                        controller: _password,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        placeholder: '登录密码',
                        enabled: !_busy,
                        padding: const EdgeInsets.all(16),
                        onChanged: (_) => setState(() {}),
                      )
                    else ...[
                      Semantics(
                        label: '支付密码，已输入${_pin.length}位，共6位',
                        child: ExcludeSemantics(
                            child: Row(
                                children: List.generate(
                                    6,
                                    (index) => Expanded(
                                          child: Container(
                                              height: 48,
                                              alignment: Alignment.center,
                                              decoration: BoxDecoration(
                                                  color: WeChatColors
                                                      .elevatedSurface(context),
                                                  border: Border.all(
                                                      color: CupertinoColors
                                                          .separator
                                                          .resolveFrom(context),
                                                      width: .5)),
                                              child: Text(
                                                  index < _pin.length
                                                      ? '●'
                                                      : '',
                                                  style: TextStyle(
                                                      fontSize: 20,
                                                      color: foreground))),
                                        )))),
                      ),
                    ],
                    if (_error != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Semantics(
                              liveRegion: true,
                              child: Text(_error!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      color: CupertinoColors.systemRed)))),
                    const SizedBox(height: 20),
                    if (!_login)
                      ...List.generate(
                          4,
                          (row) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                    children: List.generate(3, (column) {
                                  final value = row < 3
                                      ? '${row * 3 + column + 1}'
                                      : ['clear', '0', 'delete'][column];
                                  final label = value == 'clear'
                                      ? '清空'
                                      : value == 'delete'
                                          ? '删除'
                                          : value;
                                  return Expanded(
                                      child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4),
                                    child: CupertinoButton(
                                        key: ValueKey('payment-pin-key-$value'),
                                        color: WeChatColors.elevatedSurface(
                                            context),
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 12),
                                        borderRadius: BorderRadius.circular(5),
                                        onPressed:
                                            _busy ? null : () => _key(value),
                                        child: Text(label,
                                            style: TextStyle(
                                                color: foreground,
                                                fontSize: value.length == 1
                                                    ? 24
                                                    : 16))),
                                  ));
                                })),
                              )),
                    const SizedBox(height: 8),
                    SizedBox(
                        width: double.infinity,
                        child: CupertinoButton(
                          key: const ValueKey('payment-pin-confirm'),
                          color: WeChatColors.brandPrimary,
                          onPressed: _busy ||
                                  (_login
                                      ? _password.text.isEmpty
                                      : _pin.length != 6)
                              ? null
                              : _submit,
                          child: _busy
                              ? const CupertinoActivityIndicator()
                              : Text(_login ? '下一步' : '确认',
                                  style: const TextStyle(
                                      color: CupertinoColors.white)),
                        )),
                  ]),
                ),
              ),
            ),
    );
    return PopScope<Object?>(
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop || _closed) return;
        // A popped route stays mounted during its exit animation. Invalidate
        // callbacks immediately so a late result cannot pop the form below it.
        _closed = true;
        _pin = '';
        _first = '';
        _password.clear();
      },
      child: page,
    );
  }
}
