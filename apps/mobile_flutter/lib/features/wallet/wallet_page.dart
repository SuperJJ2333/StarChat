import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';

/// 单一可取消提现轮询控制器（U02）：
/// - 固定订单 ID（回调不共享可变字段）；
/// - 串行轮询（上一轮完成后再调度下一轮，慢请求不并发堆积）；
/// - 轮询异常转为明确可恢复状态（不中断后续轮询）；
/// - 终态自动停止；`stop()` 取消全部资源。
final class WithdrawalOrderPoller {
  WithdrawalOrderPoller({
    required this.fetch,
    this.interval = const Duration(seconds: 10),
    this.terminalStatuses = const {'CHAIN_CONFIRMED', 'FAILED', 'FAILED_COMPENSATED'},
    this.onStatus,
    this.onError,
  });

  final Future<Map<String, dynamic>?> Function(String orderId) fetch;
  final Duration interval;
  final Set<String> terminalStatuses;
  final void Function(String status)? onStatus;
  final void Function(String message)? onError;

  String? _orderId;
  Timer? _timer;
  bool _inFlight = false;

  bool get isActive => _orderId != null;

  void start(String orderId) {
    stop();
    _orderId = orderId;
    _timer = Timer.periodic(interval, (_) => _tick());
    unawaited(_tick());
  }

  Future<void> _tick() async {
    final orderId = _orderId;
    if (orderId == null || _inFlight) return;
    _inFlight = true;
    try {
      final latest = await fetch(orderId);
      final status = latest?['status']?.toString();
      if (status != null && _orderId == orderId) onStatus?.call(status);
      if (status != null && terminalStatuses.contains(status)) stop();
    } catch (error) {
      if (_orderId == orderId) {
        // 轮询失败转明确可恢复状态；下一轮继续（不抛出不中断）。
        onError?.call(error is BusinessApiException ? error.message : '状态查询失败，将继续重试');
      }
    } finally {
      _inFlight = false;
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _orderId = null;
  }
}

final class WalletPage extends StatefulWidget {
  const WalletPage({super.key, this.api});
  final BusinessApiClient? api;
  @override
  State<WalletPage> createState() => _WalletPageState();
}

final class _WalletPageState extends State<WalletPage> {
  final amount = TextEditingController();
  final address = TextEditingController();
  Future<Map<String, dynamic>>? balance;
  String? depositAddress;
  String? status;
  WithdrawalOrderPoller? _poller;

  /// U01：一次明确提现意图 = 一个持久化订单键（重试复用；服务端仍执行
  /// 全链路幂等，防抖不替代服务端）。
  static const _pendingOrderKeyPref = 'wallet.pending_withdrawal_order_key';
  String? _pendingOrderKey;

  /// U01：提交中互斥 + 按钮加载态。
  bool _submitting = false;

  /// U03：服务端有效确认阈值（0/未取到时隐藏具体数字文案）。
  int? _confirmationThreshold;
  String? _minDepositText;

  static final RegExp _trc20Pattern = RegExp(r'^T[1-9A-HJ-NP-Za-km-z]{33}$');
  static final RegExp _amountPattern = RegExp(r'^(0|[1-9]\d*)(\.\d{1,6})?$');

  @override
  void initState() {
    super.initState();
    final api = widget.api;
    if (api != null) {
      balance = api.walletBalance();
      _loadWalletConfig();
      _loadPendingOrderKey();
    }
  }

  Future<void> _loadWalletConfig() async {
    try {
      final config = await widget.api?.walletConfig();
      final threshold = config?['confirmation_threshold'];
      if (!mounted) return;
      setState(() {
        _confirmationThreshold = threshold is int ? threshold : null;
        final min = config?['min_deposit']?.toString();
        _minDepositText = (min == null || min.isEmpty) ? null : min;
      });
    } catch (_) {
      // 配置不可得：保持通用文案（不显示可能错误的具体数字）。
    }
  }

  Future<void> _loadPendingOrderKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = prefs.getString(_pendingOrderKeyPref);
      if (key != null && mounted) setState(() => _pendingOrderKey = key);
    } catch (_) {}
  }

  Future<void> _rememberOrderKey(String key) async {
    _pendingOrderKey = key;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingOrderKeyPref, key);
    } catch (_) {}
  }

  Future<void> _clearOrderKey() async {
    _pendingOrderKey = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_pendingOrderKeyPref);
    } catch (_) {}
  }

  @override
  void dispose() {
    _poller?.stop();
    amount.dispose();
    address.dispose();
    super.dispose();
  }

  String? _validateWithdrawal() {
    final text = amount.text.trim();
    if (text.isEmpty) return '请输入提现金额';
    if (!_amountPattern.hasMatch(text)) {
      return text.split('.').length > 1 && text.split('.').last.length > 6
          ? '提现金额最多支持六位小数'
          : '提现金额格式不正确';
    }
    if (double.tryParse(text)! <= 0) return '提现金额必须大于0';
    if (!_trc20Pattern.hasMatch(address.text.trim())) {
      return '请输入正确的 TRC20 收款地址';
    }
    return null;
  }

  Future<void> _loadDepositAddress() async {
    try {
      final body = await widget.api?.walletDepositAddress();
      if (mounted) setState(() => depositAddress = body?['address']?.toString());
    } catch (_) {
      if (mounted) setState(() => status = '充值地址获取失败，请稍后重试');
    }
  }

  Future<void> _copyAddress() async {
    if (depositAddress == null) return;
    await Clipboard.setData(ClipboardData(text: depositAddress!));
    if (mounted) setState(() => status = '充值地址已复制');
  }

  Future<void> withdraw() async {
    final error = _validateWithdrawal();
    if (error != null) {
      setState(() => status = error);
      return;
    }
    // U01：提交中互斥——快速双击只创建一单；新订单键仅在明确的新意图
    // （上次提交已结束且无保留键）时生成。
    if (_submitting) return;
    _submitting = true;
    setState(() {}); // 按钮 loading。
    try {
      final orderKey =
          _pendingOrderKey ?? 'mobile-${DateTime.now().millisecondsSinceEpoch}';
      await _rememberOrderKey(orderKey);
      final r = await widget.api?.requestWithdrawal(
          amount: amount.text.trim(),
          address: address.text.trim(),
          clientOrderId: orderKey,
          reasonCode: 'USER_WITHDRAWAL');
      final orderId = r?['id']?.toString();
      if (!mounted) return;
      setState(() => status = '提现申请已提交：${r?['status'] ?? '审核中'}');
      if (orderId != null) {
        // 提交成功：本次意图已落单，清除保留键（下一次点击=新意图新键）。
        await _clearOrderKey();
        _poller?.stop();
        _poller = WithdrawalOrderPoller(
          fetch: (id) async => await widget.api?.withdrawalStatus(id),
          onStatus: (latest) {
            if (mounted) setState(() => status = '提现状态：$latest');
          },
          onError: (message) {
            if (mounted) setState(() => status = message);
          },
        )..start(orderId);
      }
    } catch (e) {
      // 失败/超时：保留订单键——重试复用同一键，服务端幂等返回原单。
      if (mounted) {
        setState(
            () => status = e is BusinessApiException ? e.message : '提现提交失败，请稍后重试');
      }
    } finally {
      _submitting = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = WeChatColors.elevatedSurface(context);
    return ListView(
      key: const Key('wallet-page-list'),
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: card,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(ChangliaoIcons.wallet,
                    size: 20, color: WeChatColors.brandPrimary),
                const SizedBox(width: 8),
                Text('USDT-TRC20 余额',
                    style: const TextStyle(
                        color: WeChatColors.textSecondary, fontSize: 14)),
              ]),
              const SizedBox(height: 10),
              FutureBuilder<Map<String, dynamic>>(
                future: balance,
                builder: (_, snapshot) => Text(
                  snapshot.hasError
                      ? '钱包暂不可用'
                      : '${snapshot.data?['balance'] ?? '--'} USDT',
                  key: const Key('wallet-balance-value'),
                  style: TextStyle(
                      fontSize: WeChatTypography.display,
                      fontWeight: FontWeight.w600,
                      height: 36 / 28,
                      color: WeChatColors.resolveTextPrimary(context)),
                ),
              ),
              const SizedBox(height: 6),
              const Text('六位小数 · 与点钻严格隔离，不可互兑',
                  style:
                      TextStyle(color: WeChatColors.textSecondary, fontSize: 12)),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Container(
          decoration: BoxDecoration(
            color: card,
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: WeChatListTile(
            leading: Icon(CupertinoIcons.arrow_down_circle,
                size: 24, color: WeChatColors.brandPrimary),
            title: Text('获取充值地址',
                style: TextStyle(
                    fontSize: 16,
                    color: WeChatColors.resolveTextPrimary(context))),
            // U03：确认数文案来自服务端 /wallet/config（阈值后端可配，
            // 客户端不再硬编码"20 个确认"）。
            subtitle: Text(depositAddress == null
                ? (_confirmationThreshold == null
                    ? '最低充值${_minDepositText == null ? '' : ' $_minDepositText USDT'}，确认到账以钱包说明为准'
                    : '最低充值${_minDepositText == null ? '' : ' $_minDepositText USDT'}，$_confirmationThreshold 个确认后到账')
                : '已生成专属充值地址',
                style: const TextStyle(
                    color: WeChatColors.textSecondary, fontSize: 13)),
            onTap: _loadDepositAddress,
          ),
        ),
        if (depositAddress != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: card,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(children: [
              Text(depositAddress!,
                  key: const Key('wallet-deposit-address'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: WeChatColors.resolveTextPrimary(context))),
              const SizedBox(height: 10),
              ModernActionButton(
                icon: ChangliaoIcons.confirm,
                label: '复制完整地址',
                onPressed: _copyAddress,
              ),
            ]),
          ),
        ],
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text('提现',
                style: TextStyle(
                    fontSize: 13,
                    color: WeChatColors.textSecondary)),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: card,
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            _field('金额', amount, '0.000000',
                key: const Key('wallet-withdraw-amount'),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                suffix: 'USDT'),
            _divider(),
            _field('地址', address, 'TRC20 收款地址',
                key: const Key('wallet-withdraw-address')),
          ]),
        ),
        const SizedBox(height: 8),
        const Text('提现状态：申请 → 审核 → 托管方处理 → 链上确认',
            textAlign: TextAlign.center,
            style: TextStyle(color: WeChatColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 16),
        ModernActionButton(
          key: const Key('wallet-withdraw-submit'),
          icon: ChangliaoIcons.transfer,
          label: _submitting ? '提交中…' : '提交提现申请',
          // U01：提交中互斥（loading 禁用）——快速双击只创建一单。
          loading: _submitting,
          onPressed: widget.api == null ? null : withdraw,
        ),
        if (status != null) ...[
          const SizedBox(height: 12),
          Text(status!,
              key: const Key('wallet-status'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: WeChatColors.textSecondary, fontSize: 13)),
        ],
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text('交易记录',
                style: TextStyle(
                    fontSize: 13, color: WeChatColors.textSecondary)),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: card,
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: FutureBuilder<Map<String, dynamic>>(
            future: widget.api?.walletHistory(),
            builder: (_, snapshot) {
              final rows = (snapshot.data?['items'] as List?) ?? const [];
              if (rows.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(
                      child: Text('暂无交易记录',
                          style: TextStyle(
                              color: WeChatColors.textSecondary,
                              fontSize: 14))),
                );
              }
              return Column(
                children: [
                  for (final r in rows)
                    WeChatListTile(
                      leading: Icon(
                        r['kind'] == 'deposit'
                            ? CupertinoIcons.arrow_down_circle
                            : CupertinoIcons.arrow_up_circle,
                        size: 24,
                        color: WeChatColors.brandPrimary,
                      ),
                      title: Text(r['kind'] == 'deposit' ? '充值' : '提现',
                          style: TextStyle(
                              fontSize: 16,
                              color:
                                  WeChatColors.resolveTextPrimary(context))),
                      subtitle: Text(r['status'].toString(),
                          style: const TextStyle(
                              color: WeChatColors.textSecondary,
                              fontSize: 13)),
                      trailing: Text('${r['amount']} USDT',
                          style: TextStyle(
                              fontSize: 14,
                              color:
                                  WeChatColors.resolveTextPrimary(context))),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _field(
    String label,
    TextEditingController controller,
    String placeholder, {
    Key? key,
    TextInputType? keyboardType,
    String? suffix,
  }) =>
      Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        color: WeChatColors.elevatedSurface(context),
        child: Row(children: [
          SizedBox(
              width: 64,
              child: Text(label,
                  style: TextStyle(
                      fontSize: 16,
                      color: WeChatColors.resolveTextPrimary(context)))),
          Expanded(
            child: CupertinoTextField(
              key: key,
              controller: controller,
              textAlign: TextAlign.right,
              keyboardType: keyboardType,
              placeholder: placeholder,
              placeholderStyle: const TextStyle(
                  fontSize: 15, color: WeChatColors.textTertiary),
              style: TextStyle(
                  fontSize: 15,
                  color: WeChatColors.resolveTextPrimary(context)),
              decoration: const BoxDecoration(),
            ),
          ),
          if (suffix != null) ...[
            const SizedBox(width: 6),
            Text(suffix,
                style: const TextStyle(
                    fontSize: 14, color: WeChatColors.textSecondary)),
          ],
        ]),
      );

  Widget _divider() => Container(
      height: .5,
      margin: const EdgeInsets.only(left: 16),
      color: WeChatColors.divider);
}
