import 'dart:async';

import 'package:flutter/foundation.dart';

/// 当前用户的 referral 邀请码（服务端 30 分钟窗口轮换）。
final class ReferralInvite {
  const ReferralInvite({
    required this.code,
    required this.rotatesAt,
    required this.rotatesInSeconds,
    required this.shareUrl,
    required this.rewardEnabled,
  });

  final String code;

  /// 轮换时间点（服务端返回的 ISO 时间）。
  final DateTime rotatesAt;

  /// 距下次轮换的秒数（服务端权威；客户端据此做倒计时与自动刷新）。
  final int rotatesInSeconds;
  final String shareUrl;
  final bool rewardEnabled;
}

abstract interface class ReferralInviteGateway {
  Future<ReferralInvite> fetchReferralInvite();
  Future<bool> validateReferralCode(String referralCode);
}

enum InviteCodeStatus { idle, loading, ready, failed }

final class InviteCodeState {
  const InviteCodeState({
    this.status = InviteCodeStatus.idle,
    this.invite,
    this.remainingSeconds = 0,
    this.message,
  });

  final InviteCodeStatus status;
  final ReferralInvite? invite;

  /// 展示用倒计时（本地每秒递减；到 0 触发自动刷新取新码）。
  final int remainingSeconds;
  final String? message;

  InviteCodeState copyWith({
    InviteCodeStatus? status,
    ReferralInvite? invite,
    int? remainingSeconds,
    String? message,
    bool clearMessage = false,
  }) =>
      InviteCodeState(
        status: status ?? this.status,
        invite: invite ?? this.invite,
        remainingSeconds: remainingSeconds ?? this.remainingSeconds,
        message: clearMessage ? null : (message ?? this.message),
      );
}

/// 邀请码控制器：
/// - 打开页面即取当前窗口码；展示**每秒倒计时**；
/// - 倒计时归零自动重新拉取（服务端窗口切换后旧码立即失效，
///   客户端"实时同步"新码，无需用户手动操作）；
/// - 失败可重试（弱网）。
final class InviteCodeController extends ChangeNotifier {
  InviteCodeController({required this.gateway});

  final ReferralInviteGateway gateway;
  InviteCodeState state = const InviteCodeState();
  Timer? _countdownTimer;
  bool _disposed = false;

  Future<void> load() async {
    _countdownTimer?.cancel();
    state = state.copyWith(status: InviteCodeStatus.loading, clearMessage: true);
    notifyListeners();
    try {
      final invite = await gateway.fetchReferralInvite();
      if (_disposed) return;
      state = state.copyWith(
        status: InviteCodeStatus.ready,
        invite: invite,
        remainingSeconds: invite.rotatesInSeconds,
      );
      notifyListeners();
      _startCountdown();
    } catch (_) {
      if (_disposed) return;
      state = state.copyWith(
        status: InviteCodeStatus.failed,
        message: '邀请码加载失败，请重试',
      );
      notifyListeners();
    }
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed) return;
      final remaining = state.remainingSeconds;
      if (remaining <= 1) {
        // 窗口已切换：立即同步新码（服务端旧码此刻已失效）。
        load();
        return;
      }
      state = state.copyWith(remainingSeconds: remaining - 1);
      notifyListeners();
    });
  }

  void showMessage(String message) {
    state = state.copyWith(message: message);
    notifyListeners();
  }

  void clearMessage() {
    state = state.copyWith(clearMessage: true);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _countdownTimer?.cancel();
    super.dispose();
  }
}
