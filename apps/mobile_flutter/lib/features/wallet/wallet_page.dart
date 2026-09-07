import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/business_api_client.dart';
import 'wallet_conversion_card.dart';
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
    this.terminalStatuses = const {
      'CHAIN_CONFIRMED',
      'FAILED_COMPENSATED',
      'CANCELLED'
    },
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
        onError?.call(
            error is BusinessApiException ? error.message : '状态查询失败，将继续重试');
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
  String? _depositNotice;
  String? _depositFeedback;
  bool _depositLoading = false;
  bool _depositFundingEnabled = false;
  String? status;
  WithdrawalOrderPoller? _poller;

  /// U01：一次明确提现意图 = 一个持久化订单键（重试复用；服务端仍执行
  /// 全链路幂等，防抖不替代服务端）。
  static const _pendingOrderKeyPref = 'wallet.pending_withdrawal_order_key';
  String? _pendingOrderKey;
  String? _intentStorageKey;
  late final Future<void> _intentLoaded;
  Map<String, String>? _pendingWithdrawal;
  bool _withdrawalTerminal = false;

  /// U01：提交中互斥 + 按钮加载态。
  bool _submitting = false;

  String? _minDepositText;
  bool _conversionEnabled = false;

  static final RegExp _trc20Pattern = RegExp(r'^T[1-9A-HJ-NP-Za-km-z]{33}$');
  static final RegExp _amountPattern = RegExp(r'^(0|[1-9]\d*)(\.\d{1,6})?$');

  @override
  void initState() {
    super.initState();
    final api = widget.api;
    if (api != null) {
      balance = api.walletBalance();
      _loadWalletConfig();
    }
    _intentLoaded = _loadPendingOrderKey();
  }

  Future<void> _loadWalletConfig() async {
    try {
      final config = await widget.api?.walletConfig();
      if (!mounted) return;
      setState(() {
        _conversionEnabled = config?['conversion_enabled'] == true;
      });
    } catch (_) {
      // 配置不可得：保持通用文案（不显示可能错误的具体数字）。
    }
  }

  Future<void> _loadPendingOrderKey() async {
    if (widget.api == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final scope = await widget.api!.walletIntentScope();
      _intentStorageKey = '$_pendingOrderKeyPref.v2:$scope';
      if (prefs.containsKey(_pendingOrderKeyPref)) {
        if (mounted) setState(() => status = '存在旧版待确认提现，请先联系财务核对，暂不能创建新提现');
        _intentStorageKey = null;
        return;
      }
      final saved = prefs.getString(_intentStorageKey!);
      if (saved != null) {
        final intent = Map<String, String>.from(jsonDecode(saved) as Map);
        _pendingWithdrawal = intent;
        _pendingOrderKey = intent['key'];
        if (mounted) {
          setState(() {
            amount.text = intent['amount']!;
            address.text = intent['address']!;
            status = '有待确认提现，重试将查询同一申请';
          });
        }
      }
    } catch (_) {
      _intentStorageKey = null;
      if (mounted) setState(() => status = '无法读取提现记录，请重新登录后重试');
    }
  }

  Future<void> _rememberOrderKey(String key) async {
    if (_intentStorageKey == null) throw StateError('无法保存提现记录');
    final intent = _pendingWithdrawal ??
        {
          'key': key,
          'amount': amount.text.trim(),
          'address': address.text.trim()
        };
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_intentStorageKey!, jsonEncode(intent))) {
      throw StateError('无法保存提现记录');
    }
    _pendingOrderKey = key;
    _pendingWithdrawal = intent;
  }

  Future<void> _clearOrderKey() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(_intentStorageKey!)) throw StateError('无法更新提现记录');
    _pendingOrderKey = null;
    _pendingWithdrawal = null;
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
    if (BigInt.parse(text.replaceAll('.', '')) <= BigInt.zero) {
      return '提现金额必须大于0';
    }
    if (!_trc20Pattern.hasMatch(address.text.trim())) {
      return '请输入正确的 TRC20 收款地址';
    }
    return null;
  }

  Future<void> _loadDepositAddress() async {
    final api = widget.api;
    if (_depositLoading || api == null) return;
    setState(() {
      _depositLoading = true;
      depositAddress = null;
      _depositNotice = null;
      _depositFeedback = null;
      _depositFundingEnabled = false;
    });
    try {
      final body = await api.walletDepositAddress();
      final value = body['address'];
      final minimum = body['minimum_deposit'];
      final notice = body['notice'];
      if (value is! String ||
          !_validOfficialAddress(value) ||
          body['asset'] != 'USDT' ||
          body['network'] != 'TRC20' ||
          body['funding_enabled'] is! bool ||
          minimum is! String ||
          !RegExp(r'^(0|[1-9][0-9]{0,23})\.[0-9]{6}$').hasMatch(minimum) ||
          notice is! String ||
          notice.trim().isEmpty) {
        throw const FormatException('Invalid official deposit response');
      }
      if (mounted) {
        setState(() {
          depositAddress = value;
          _depositNotice = notice;
          _minDepositText = minimum;
          _depositFundingEnabled = body['funding_enabled'] as bool;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _depositFeedback = error is BusinessApiException
            ? error.message
            : error is FormatException
                ? '充值地址数据无效，请联系管理员'
                : '无法连接服务器，请检查网络后重试');
      }
    } finally {
      if (mounted) setState(() => _depositLoading = false);
    }
  }

  static bool _validOfficialAddress(String value) {
    if (!RegExp(r'^T[1-9A-HJ-NP-Za-km-z]{33}$').hasMatch(value)) return false;
    const alphabet =
        '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
    var number = BigInt.zero;
    for (final character in value.split('')) {
      number =
          number * BigInt.from(58) + BigInt.from(alphabet.indexOf(character));
    }
    final bytes = <int>[];
    while (number > BigInt.zero) {
      bytes.insert(0, (number & BigInt.from(255)).toInt());
      number >>= 8;
    }
    if (bytes.length != 25 || bytes.first != 0x41) return false;
    final checksum =
        sha256.convert(sha256.convert(bytes.take(21).toList()).bytes).bytes;
    return List.generate(4, (index) => bytes[index + 21] == checksum[index])
        .every((matches) => matches);
  }

  Future<void> _copyAddress() async {
    if (depositAddress == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: depositAddress!));
      if (mounted) setState(() => _depositFeedback = '充值地址已复制');
    } catch (_) {
      if (mounted) setState(() => _depositFeedback = '复制失败，请重试');
    }
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
      await _intentLoaded;
      if (_intentStorageKey == null || widget.api == null) {
        throw StateError('提现记录未准备好');
      }
      final scope = await widget.api!.walletIntentScope();
      if (_intentStorageKey != '$_pendingOrderKeyPref.v2:$scope') {
        throw StateError('账户已切换');
      }
      final existingId = _pendingWithdrawal?['order_id'];
      if (existingId != null) {
        _startPolling(existingId);
        return;
      }
      final orderKey = _pendingOrderKey ?? widget.api!.newIdempotencyKey();
      await _rememberOrderKey(orderKey);
      final r = await widget.api?.requestWithdrawal(
          amount: _pendingWithdrawal!['amount']!,
          address: _pendingWithdrawal!['address']!,
          clientOrderId: orderKey,
          reasonCode: 'USER_WITHDRAWAL');
      final orderId = r?['id']?.toString();
      if (!mounted) return;
      setState(() => status = '提现申请已提交：${r?['status'] ?? '审核中'}');
      if (orderId != null) {
        _pendingWithdrawal!['order_id'] = orderId;
        await _rememberOrderKey(orderKey);
        if (mounted) {
          setState(() {
            balance = widget.api!.walletBalance();
          });
        }
        _startPolling(orderId);
      }
    } catch (e) {
      // 失败/超时：保留订单键——重试复用同一键，服务端幂等返回原单。
      if (mounted) {
        setState(() =>
            status = e is BusinessApiException ? e.message : '提现提交失败，请稍后重试');
      }
    } finally {
      _submitting = false;
      if (mounted) setState(() {});
    }
  }

  void _startPolling(String orderId) {
    _poller?.stop();
    _poller = WithdrawalOrderPoller(
      fetch: (id) async => await widget.api?.withdrawalStatus(id),
      onStatus: (latest) {
        if (mounted) {
          setState(() {
            status = '提现状态：$latest';
            _withdrawalTerminal = const {
              'CHAIN_CONFIRMED',
              'FAILED_COMPENSATED',
              'CANCELLED'
            }.contains(latest);
          });
        }
      },
      onError: (message) {
        if (mounted) setState(() => status = message);
      },
    )..start(orderId);
  }

  Future<void> _newWithdrawal() async {
    if (!_withdrawalTerminal || _submitting) return;
    try {
      await _clearOrderKey();
      if (!mounted) return;
      setState(() {
        amount.clear();
        address.clear();
        status = null;
        _withdrawalTerminal = false;
      });
    } catch (_) {
      if (mounted) setState(() => status = '无法更新提现记录，请重试');
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
              const Text('USDT 六位小数 · 点钻两位小数',
                  style: TextStyle(
                      color: WeChatColors.textSecondary, fontSize: 12)),
              FutureBuilder<Map<String, dynamic>>(
                future: balance,
                builder: (_, snapshot) => Text(
                    '冻结 ${snapshot.data?['usdt_held'] ?? '--'} USDT · '
                    '点钻 ${snapshot.data?['caibi_available'] ?? '--'}',
                    key: const Key('wallet-held-points'),
                    style: const TextStyle(
                        fontSize: 12, color: WeChatColors.textSecondary)),
              ),
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
            key: const Key('wallet-deposit-load'),
            leading: Icon(CupertinoIcons.arrow_down_circle,
                size: 24, color: WeChatColors.brandPrimary),
            title: Text('获取充值地址',
                style: TextStyle(
                    fontSize: 16,
                    color: WeChatColors.resolveTextPrimary(context))),
            subtitle: Text(
                _depositLoading ? '正在获取官方充值地址…' : '官方固定地址 · USDT (TRC20)',
                style: const TextStyle(
                    color: WeChatColors.textSecondary, fontSize: 13)),
            trailing: _depositLoading
                ? const CupertinoActivityIndicator(
                    key: Key('wallet-deposit-loading'))
                : null,
            onTap: _depositLoading || widget.api == null
                ? null
                : _loadDepositAddress,
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
              Text(_depositFundingEnabled ? '官方充值地址' : '充值入账暂未开放',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(_depositNotice!,
                  key: const Key('wallet-deposit-notice'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: WeChatColors.textSecondary)),
              const SizedBox(height: 12),
              QrImageView(
                  key: const Key('wallet-deposit-qr'),
                  data: depositAddress!,
                  size: 180,
                  backgroundColor: CupertinoColors.white,
                  semanticsLabel: '官方 USDT TRC20 充值地址二维码'),
              const SizedBox(height: 10),
              Text(depositAddress!,
                  key: const Key('wallet-deposit-address'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: WeChatColors.resolveTextPrimary(context))),
              const SizedBox(height: 10),
              Text('最低充值 $_minDepositText USDT · TRC20',
                  style: const TextStyle(
                      fontSize: 12, color: WeChatColors.textSecondary)),
              const SizedBox(height: 10),
              ModernActionButton(
                key: const Key('wallet-deposit-copy'),
                icon: ChangliaoIcons.confirm,
                label: '复制完整地址',
                onPressed: _copyAddress,
              ),
            ]),
          ),
        ],
        if (_depositFeedback != null) ...[
          const SizedBox(height: 8),
          Text(_depositFeedback!,
              key: const Key('wallet-deposit-feedback'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 13, color: WeChatColors.textSecondary)),
        ],
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text('提现',
                style:
                    TextStyle(fontSize: 13, color: WeChatColors.textSecondary)),
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
          label: _submitting
              ? '提交中…'
              : (_pendingOrderKey != null ? '查询原提现申请' : '提交提现申请'),
          // U01：提交中互斥（loading 禁用）——快速双击只创建一单。
          loading: _submitting,
          onPressed: widget.api == null ? null : withdraw,
        ),
        if (_withdrawalTerminal)
          CupertinoButton(
            key: const Key('wallet-withdraw-new'),
            onPressed: _newWithdrawal,
            child: const Text('创建新的提现申请'),
          ),
        if (status != null) ...[
          const SizedBox(height: 12),
          Text(status!,
              key: const Key('wallet-status'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: WeChatColors.textSecondary, fontSize: 13)),
        ],
        if (widget.api != null) ...[
          const SizedBox(height: 16),
          WalletConversionCard(
              api: widget.api!,
              enabled: _conversionEnabled,
              onCompleted: () {
                if (mounted) {
                  setState(() {
                    balance = widget.api!.walletBalance();
                  });
                }
              }),
        ],
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text('交易记录',
                style:
                    TextStyle(fontSize: 13, color: WeChatColors.textSecondary)),
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
                              color: WeChatColors.resolveTextPrimary(context))),
                      subtitle: Text(r['status'].toString(),
                          style: const TextStyle(
                              color: WeChatColors.textSecondary, fontSize: 13)),
                      trailing: Text('${r['amount']} USDT',
                          style: TextStyle(
                              fontSize: 14,
                              color: WeChatColors.resolveTextPrimary(context))),
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
