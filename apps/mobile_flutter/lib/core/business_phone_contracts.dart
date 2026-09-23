import 'package:flutter/foundation.dart';

/// ADR-0075：手机号认证与人工充值/汇率/转让意图的客户端契约。
///
/// 独立于 [RegistrationGateway]（避免破坏既有邮箱注册替身）；实现方
/// （BusinessApiClient）同时实现两套接口。所有方法遵循仓库红线：
/// 不打印验证码/完整手机号；充值提交沿用调用方幂等键。
/// 未登录请求有有限超时；超时不证明服务端未执行，不自动重发验证码。
abstract interface class PhoneAuthGateway {
  /// 手机通道注册：服务端创建 PENDING_PHONE 用户（短信验证码随后请求）。
  Future<RegistrationPhoneReceipt> registerWithPhone({
    required String username,
    String? nickname,
    required String phone,
    required String password,
    required String invitationCode,
  });

  /// 请求注册短信验证码（绑定 registration_session，5 分钟有效）。
  Future<void> requestRegistrationOtp(String registrationSession);

  /// 校验注册短信验证码：成功后用户进入 PENDING_MATRIX（Outbox 开通 Matrix）。
  /// 服务端目前不按此请求的幂等键重放；返回丢失时通过注册状态查询恢复。
  Future<void> verifyRegistrationPhone({
    required String registrationSession,
    required String phone,
    required String code,
  });

  /// 请求登录短信验证码（防枚举：账号不存在同样返回 accepted）。
  Future<void> requestPhoneLoginOtp(String phone);

  /// 短信验证码登录：仅恢复登录权，不恢复 E2EE 历史密钥。
  Future<Map<String, dynamic>> phoneLogin({
    required String phone,
    required String code,
    required String deviceKey,
    required String deviceName,
    String invitationCode = '',
    bool termsAccepted = false,
    bool Function()? shouldContinue,
  });

  /// 换绑第一步：验证当前凭证（已绑手机→旧手机码；仅邮箱账号→邮箱码）。
  Future<Map<String, dynamic>> rebindOldRequest();

  Future<void> rebindOldConfirm({required String code});

  /// 换绑第二步前提满足后：向新手机号请求验证码。
  Future<void> rebindNewRequest({required String phone});

  /// 换绑完成：消费新号验证码并原子换绑。
  Future<void> rebindNewConfirm({required String phone, required String code});

  /// 完整号码精确搜索（隐私开关关闭/不存在→found:false，响应无手机号）。
  Future<Map<String, dynamic>> searchByPhone(String phone);

  /// 隐私开关：允许通过手机号找到我。
  Future<void> setPhoneFindable(bool enabled);
}

/// ADR-0077：人工充值（客服结算）与 ADR-0076 参考汇率 / ADR-0079 转让意图。
abstract interface class RechargeGateway {
  /// 官方充值客服目录（仅启用条目）。
  Future<List<Map<String, dynamic>>> rechargeDirectory();

  /// 提交充值申请：只生成待处理订单，不增加余额。
  Future<Map<String, dynamic>> submitRecharge({
    required String amountUsdt,
    String? evidenceTxid,
    String? note,
    required String idempotencyKey,
  });

  /// 我的充值申请（含处理状态；SUBMITTED ≠ 已到账）。
  Future<List<Map<String, dynamic>>> myRecharges();

  /// 取消返回丢失时先查我的申请状态；重复取消可能返回 409。
  Future<void> cancelRecharge(String requestId);

  /// USD/CNY 参考汇率快照（stale=true 表示过期参考）。
  Future<Map<String, dynamic>> fxRate();

  /// 房间转让意图时间线（群主或管理员）。
  Future<List<Map<String, dynamic>>> transferIntents(String roomId);
}

@immutable
final class RegistrationPhoneReceipt {
  const RegistrationPhoneReceipt({
    required this.registrationSession,
    required this.status,
    required this.resendAfterSeconds,
  });

  final String registrationSession;
  final String status;
  final int resendAfterSeconds;
}
