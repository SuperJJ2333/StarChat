import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/business_api_client.dart';
import 'manual_wallet_api.dart';

/// 提现申请状态的本地快照（微信级加载模型 L1：本地优先 → 立即展示 → 后台同步
/// → 失败不覆盖）。
///
/// 背景（Mi 6 真机 A/B 证据，2026-09-19，见
/// `docs/verification/2026-09-19-wallet-offline-device-verification.md` §2）：
/// `ManualWalletPage.refresh()` 里 `payout = await api.payout(id)`
/// （`manual_wallet_page.dart:312-315`）是状态卡的**唯一**数据来源，而卡片渲染条件
/// 是 `payout != null`（`:1945-1973`）。断网时该请求失败，页面只剩余额与步骤条，
/// 用户看不到「管理员人工付款处理中 / 订单 / 提现 USDT」——正是
/// 「提现页（余额/申请/状态）」里缺的那一块。
///
/// **为什么不复用 [ManualOperationStore]**：它的 `save` 是安全白名单，只允许
/// `key/amount/version/id/quote_id/address/method/confirm_key/funding_asset`，
/// 状态对象里的 `status`/`review_reason`/`settlement_txid` 会被它拒绝
/// （`manual_operation_store.dart:43-68`）。这里因此单独建一个 store，并把允许落盘
/// 的字段**显式列全**：全部是服务端已经回给本机的展示字段，不含任何凭据、签名
/// 材料或密钥。
///
/// 账号边界：key 里带 `walletIntentScope()`，读写前重新校验作用域；账号切换后旧
/// 快照立即失效（读取按"无缓存"处理，不跨账号展示他人提现记录）。
final class ManualPayoutStatusStore {
  ManualPayoutStatusStore(this.client);

  final BusinessApiClient client;
  String? _scope;
  SharedPreferences? _prefs;

  /// 允许落盘的字段：与 [ManualPayout.fromJson] 的输入一一对应，且都是服务端已
  /// 返回给客户端的展示字段。新增字段必须在此显式登记（缺字段视为不可用）。
  static const Set<String> allowedFields = {
    'id',
    'user_id',
    'quote_id',
    'amount',
    'status',
    'digest',
    'candidate_txid',
    'settlement_txid',
    'review_reason',
    'final_receive',
    'final_rate',
    'expires_at',
    'processing_stage',
  };

  Future<void> initialize() async {
    _scope = await client.walletIntentScope();
    _prefs = await SharedPreferences.getInstance();
  }

  Future<String> _key(String payoutId) async {
    if (_scope == null || await client.walletIntentScope() != _scope) {
      throw StateError('账户已切换，请重新打开钱包');
    }
    return 'wallet.payout.status.v1:$_scope:$payoutId';
  }

  /// 读取指定申请的本地状态快照。
  ///
  /// 不存在、损坏、id 不符或含未登记字段时一律返回 `null`（按"无本地数据"处理，
  /// 由调用方回退到网络，绝不把不可信内容当成最新状态展示）。
  Future<ManualPayout?> read(String payoutId) async {
    final prefs = _prefs;
    if (prefs == null || payoutId.isEmpty) return null;
    try {
      final raw = prefs.getString(await _key(payoutId));
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final record = Map<String, dynamic>.from(decoded);
      if (record['id'] != payoutId) return null;
      if (record.keys.any((key) => !allowedFields.contains(key))) return null;
      return ManualPayout.fromJson(record);
    } catch (_) {
      return null;
    }
  }

  /// 写入最近一次成功取回的申请状态；写失败不是加载失败（也覆盖账号切换场景）。
  Future<void> save(ManualPayout payout) async {
    try {
      final prefs = _prefs;
      if (prefs == null) return;
      await prefs.setString(await _key(payout.id), jsonEncode(encode(payout)));
    } catch (_) {
      // 本地快照写失败不影响本次展示。
    }
  }

  Future<void> clear(String payoutId) async {
    try {
      final prefs = _prefs;
      if (prefs == null) return;
      await prefs.remove(await _key(payoutId));
    } catch (_) {
      // 账号已切换时无需清理（key 已随作用域失效）。
    }
  }

  /// 只落非密展示字段：敏感/未知字段一律不写。
  ///
  /// 可选字段即使为 null 也要写出：`ManualPayout.fromJson` 要求这些键**存在**
  /// （缺失即判定契约不合法），省略会让快照在读取时被判为损坏而丢弃。
  static Map<String, dynamic> encode(ManualPayout payout) => {
        'id': payout.id,
        'user_id': payout.userId,
        'quote_id': payout.quoteId,
        'amount': payout.amount,
        'status': payout.status.name.toUpperCase(),
        'digest': payout.digest,
        'candidate_txid': payout.candidateTxid,
        'settlement_txid': payout.settlementTxid,
        'review_reason': payout.reviewReason,
        'final_receive': payout.finalReceive,
        'final_rate': payout.finalRate,
        'expires_at': payout.expiresAt?.toUtc().toIso8601String(),
        'processing_stage': payout.processingStage,
      };
}
