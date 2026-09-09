import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/foundation/wechat_tokens.dart';

/// Server-authoritative conversion. Unknown responses retain the original intent.
final class WalletConversionCard extends StatefulWidget {
  const WalletConversionCard(
      {super.key,
      required this.api,
      required this.enabled,
      required this.onCompleted});
  final BusinessApiClient api;
  final bool enabled;
  final VoidCallback onCompleted;

  @override
  State<WalletConversionCard> createState() => _WalletConversionCardState();
}

final class _WalletConversionCardState extends State<WalletConversionCard> {
  final _amount = TextEditingController();
  String _direction = 'USDT_TO_CAIBI';
  String? _storageKey;
  Map<String, String>? _pending;
  String? _message;
  bool _ready = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final scope = await widget.api.walletIntentScope();
      final prefs = await SharedPreferences.getInstance();
      final key = 'wallet.conversion.v1:$scope';
      final raw = prefs.getString(key);
      final pending =
          raw == null ? null : Map<String, String>.from(jsonDecode(raw) as Map);
      if (!mounted) return;
      setState(() {
        _storageKey = key;
        _pending = pending;
        if (pending != null) {
          _amount.text = pending['amount']!;
          _direction = pending['direction']!;
          _message = '有待确认的兑换，请重试原订单';
        }
        _ready = true;
      });
    } catch (_) {
      if (mounted) setState(() => _message = '无法读取兑换记录，请重新登录后重试');
    }
  }

  String? _targetAmount(String text) {
    if (!RegExp(r'^(0|[1-9]\d*)(\.\d{1,6})?$').hasMatch(text)) return null;
    final pieces = text.split('.');
    final fractional = pieces.length == 2 ? pieces[1] : '';
    if (_direction == 'CAIBI_TO_USDT' && fractional.length > 2) return null;
    final micros = BigInt.parse(pieces[0]) * BigInt.from(1000000) +
        BigInt.parse(fractional.padRight(6, '0'));
    if (micros < BigInt.from(10000)) return null;
    final cents = micros ~/ BigInt.from(10000);
    final whole = cents ~/ BigInt.from(100);
    final fraction = (cents % BigInt.from(100)).toString().padLeft(2, '0');
    return '$whole.$fraction${_direction == 'CAIBI_TO_USDT' ? '0000' : ''}';
  }

  Future<void> _submit() async {
    if (_busy || !_ready || !widget.enabled) return;
    final text = _amount.text.trim();
    final target = _targetAmount(text);
    if (target == null) {
      setState(() => _message = '请输入至少 0.01 的有效金额；点钻最多两位小数');
      return;
    }
    setState(() => _busy = true);
    try {
      final scope = await widget.api.walletIntentScope();
      if ('wallet.conversion.v1:$scope' != _storageKey) {
        throw StateError('账户已切换，请重新打开钱包');
      }
      if (_pending == null) {
        if (!mounted) return;
        final confirmed = await showCupertinoDialog<bool>(
            context: context,
            builder: (context) => CupertinoAlertDialog(
                  title: const Text('确认兑换'),
                  content: Text(
                      '预计到账 $target ${_direction == 'USDT_TO_CAIBI' ? '点钻' : 'USDT'}\n'
                      '1 USDT = 1 点钻，兑换免手续费。\n不足 0.01 的 USDT 余量保留，最终以服务端结果为准。'),
                  actions: [
                    CupertinoDialogAction(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消')),
                    CupertinoDialogAction(
                        key: const Key('wallet-convert-confirm'),
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('确认兑换')),
                  ],
                ));
        if (confirmed != true) return;
        final intent = {
          'direction': _direction,
          'amount': text,
          'key': widget.api.newIdempotencyKey()
        };
        final prefs = await SharedPreferences.getInstance();
        if (!await prefs.setString(_storageKey!, jsonEncode(intent))) {
          throw StateError('无法保存兑换记录');
        }
        _pending = intent;
      }
      final intent = _pending!;
      final result = await widget.api.convertWallet(
          direction: intent['direction']!,
          amount: intent['amount']!,
          idempotencyKey: intent['key']!,
          expectedWalletScope: scope);
      if (result['status'] != 'COMPLETED') {
        if (mounted) setState(() => _message = '订单处理中，请重试查询原结果');
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.remove(_storageKey!)) throw StateError('无法更新兑换记录');
      _pending = null;
      if (!mounted) return;
      setState(() {
        _message = '兑换成功，到账 ${result['target_amount']}';
        _amount.clear();
      });
      widget.onCompleted();
    } catch (error) {
      if (error is BusinessApiException &&
          const {
            'WALLET_CONVERSION_REJECTED',
            'WALLET_RESERVE_INSUFFICIENT',
            'WALLET_ACCOUNT_RESTRICTED'
          }.contains(error.code) &&
          _storageKey != null) {
        final prefs = await SharedPreferences.getInstance();
        if (await prefs.remove(_storageKey!)) _pending = null;
      }
      if (mounted) {
        setState(() => _message = error is BusinessApiException
            ? '${error.message}${_pending != null ? '；可重试原订单' : ''}'
            : '暂时无法确认兑换结果，请重试原订单');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: WeChatColors.elevatedSurface(context),
            borderRadius: BorderRadius.circular(8)),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('点钻与 USDT 兑换',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text('1 USDT = 1 点钻 · 兑换免手续费',
              style:
                  TextStyle(fontSize: 12, color: WeChatColors.textSecondary)),
          if (!widget.enabled)
            const Padding(
                padding: EdgeInsets.only(top: 12), child: Text('兑换暂未开放')),
          if (widget.enabled) ...[
            const SizedBox(height: 12),
            CupertinoSlidingSegmentedControl<String>(
                groupValue: _direction,
                children: const {
                  'USDT_TO_CAIBI': Text('USDT → 点钻'),
                  'CAIBI_TO_USDT': Text('点钻 → USDT')
                },
                onValueChanged: (value) {
                  if (!_busy && _pending == null && value != null) {
                    setState(() => _direction = value);
                  }
                }),
            const SizedBox(height: 12),
            CupertinoTextField(
                key: const Key('wallet-convert-amount'),
                controller: _amount,
                readOnly: _busy || _pending != null,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                placeholder: '输入兑换金额'),
            const SizedBox(height: 12),
            ModernActionButton(
                key: const Key('wallet-convert-submit'),
                icon: CupertinoIcons.arrow_2_circlepath,
                label: _busy
                    ? '正在确认…'
                    : _pending != null
                        ? '重试原订单'
                        : '兑换',
                onPressed: _busy || !_ready ? null : _submit),
          ],
          if (_message != null)
            Padding(
                padding: const EdgeInsets.only(top: 10),
                child:
                    Text(_message!, key: const Key('wallet-convert-result'))),
        ]),
      );
}
