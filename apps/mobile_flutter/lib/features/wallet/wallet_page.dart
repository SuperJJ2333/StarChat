import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'manual_wallet_page.dart';

import '../../core/business_api_client.dart';
import 'wallet_conversion_card.dart';
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
  Future<Map<String, dynamic>>? balance;
  String? depositAddress;
  String? _depositNotice;
  String? _depositFeedback;
  bool _depositLoading = false;
  bool _depositFundingEnabled = false;
  String? _minDepositText;
  bool _conversionEnabled = false;

  @override
  void initState() {
    super.initState();
    final api = widget.api;
    if (api != null) {
      balance = api.walletBalance();
      _loadWalletConfig();
    }
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
              Row(children: [
                Expanded(
                    child: Text(depositAddress!,
                        key: const Key('wallet-deposit-address'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: WeChatColors.resolveTextPrimary(context)))),
                Semantics(
                    label: '复制完整地址',
                    child: CupertinoButton(
                        key: const Key('wallet-deposit-copy'),
                        padding: const EdgeInsets.all(10),
                        onPressed: _copyAddress,
                        child:
                            const Icon(CupertinoIcons.doc_on_doc, size: 20))),
              ]),
              const SizedBox(height: 10),
              Text('最低充值 $_minDepositText USDT · TRC20',
                  style: const TextStyle(
                      fontSize: 12, color: WeChatColors.textSecondary)),
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
        WeChatListTile(
          key: const Key('wallet-manual-open'),
          leading:
              Icon(ChangliaoIcons.wallet, color: WeChatColors.brandPrimary),
          title: const Text('私人钱包与充提'),
          subtitle: const Text('钱包地址 · 充值 · 提现'),
          onTap: widget.api == null
              ? null
              : () => Navigator.of(context).push(CupertinoPageRoute<void>(
                  builder: (_) => ManualWalletPage(client: widget.api!))),
        ),
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
}
