import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import 'manual_wallet_page.dart';

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

/// AppHome supplies the single 钱包 navigation bar.
final class WalletPage extends StatelessWidget {
  const WalletPage({super.key, this.api});
  final BusinessApiClient? api;

  @override
  Widget build(BuildContext context) {
    final client = api;
    if (client == null) {
      return const Center(child: Text('钱包暂不可用，请重新登录'));
    }
    return ManualWalletPage(client: client, embedded: true);
  }
}
