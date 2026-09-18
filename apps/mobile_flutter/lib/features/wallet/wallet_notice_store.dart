import 'package:shared_preferences/shared_preferences.dart';

import '../../core/business_api_client.dart';

/// 充值申请提醒的通知栏身份。
///
/// 返回 `null` 表示当前没有待跟进的充值申请。身份取服务端受理后的申请 id；
/// 结果未确认的草稿退回使用本机幂等键（同一份草稿重试时身份不变）。
String? depositNoticeIdentity(Map<String, dynamic>? depositOp) {
  if (depositOp == null) return null;
  final identity = depositOp['id'] ?? depositOp['key'];
  return identity is String && identity.isNotEmpty ? 'deposit:$identity' : null;
}

/// 提现申请提醒的通知栏身份。
///
/// 「报价 → 提现订单」是同一条申请链路：订单上保留 `quote_id`，因此确认提现
/// 之后身份**不会**改变（提醒不会因为换了个 id 又冒出来），只有真正新的一笔
/// （新报价 / 新订单）才会得到新身份。
String? payoutNoticeIdentity(
    Map<String, dynamic>? payoutOp, Map<String, dynamic>? quoteOp) {
  if (payoutOp == null && quoteOp == null) return null;
  final identity = payoutOp?['quote_id'] ??
      quoteOp?['id'] ??
      payoutOp?['id'] ??
      payoutOp?['key'] ??
      quoteOp?['key'];
  return identity is String && identity.isNotEmpty ? 'payout:$identity' : null;
}

/// 通知栏「不再通知」标记的持久化存储。
///
/// 存的是**被忽略的那一笔申请的身份**（按钱包作用域 + 提醒类型分区），不是内存
/// bool：因此
/// - 进程重启后仍然有效；
/// - 出现新的一笔充值/提现申请（身份不同）时提醒自然重新出现；
/// - 切换账号不会串用上一个账号的忽略标记。
final class WalletNoticeStore {
  WalletNoticeStore(this.client);

  final BusinessApiClient client;

  static const _prefix = 'wallet.notice.v1';

  String? _scope;
  SharedPreferences? _prefs;

  bool get ready => _prefs != null && _scope != null;

  Future<void> initialize() async {
    _scope = await client.walletIntentScope();
    _prefs = await SharedPreferences.getInstance();
  }

  Future<String> _key(String kind) async {
    if (_prefs == null) throw StateError('提醒设置尚未就绪，请刷新后重试');
    if (_scope == null || await client.walletIntentScope() != _scope) {
      throw StateError('账户已切换，请重新打开钱包');
    }
    return '$_prefix:$_scope:$kind';
  }

  /// 已忽略的申请身份；`null` 表示尚未忽略（此时提醒应继续展示）。
  Future<String?> ignoredIdentity(String kind) async {
    final prefs = _prefs;
    if (prefs == null) return null;
    return prefs.getString(await _key(kind));
  }

  /// 记录「不再通知」：只忽略这一笔申请。
  Future<void> ignore(String kind, String identity) async {
    final prefs = _prefs;
    if (prefs == null) throw StateError('提醒设置尚未就绪，请刷新后重试');
    if (!await prefs.setString(await _key(kind), identity)) {
      throw StateError('无法保存提醒设置，请稍后重试');
    }
  }
}
