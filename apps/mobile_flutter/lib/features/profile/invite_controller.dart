import 'package:flutter/foundation.dart';

/// 当前用户的固定个人注册邀请码（统一邀请码体系，规格 §6.2）。
///
/// 每个用户一个码，永不轮换；注册页唯一的「邀请码」字段与之同一体系，
/// 好友注册消耗该码即建立邀请关系。
final class PersonalInvitation {
  const PersonalInvitation({
    required this.code,
    required this.maxUses,
    required this.useCount,
    required this.shareUrl,
  });

  final String code;
  final int maxUses;
  final int useCount;
  final String shareUrl;

  int get remainingUses => maxUses - useCount;
}

abstract interface class PersonalInvitationGateway {
  Future<PersonalInvitation> fetchPersonalInvitation();
}

enum InviteCodeStatus { idle, loading, ready, failed }

final class InviteCodeState {
  const InviteCodeState({
    this.status = InviteCodeStatus.idle,
    this.invite,
    this.message,
  });

  final InviteCodeStatus status;
  final PersonalInvitation? invite;
  final String? message;

  InviteCodeState copyWith({
    InviteCodeStatus? status,
    PersonalInvitation? invite,
    String? message,
    bool clearMessage = false,
  }) =>
      InviteCodeState(
        status: status ?? this.status,
        invite: invite ?? this.invite,
        message: clearMessage ? null : (message ?? this.message),
      );
}

/// 邀请码控制器：打开页面即拉取个人注册邀请码；失败可重试（弱网）。
/// 码固定不轮换，无需倒计时；手动刷新同步最新已用次数。
final class InviteCodeController extends ChangeNotifier {
  InviteCodeController({required this.gateway});

  final PersonalInvitationGateway gateway;
  InviteCodeState state = const InviteCodeState();
  bool _disposed = false;

  Future<void> load() async {
    state =
        state.copyWith(status: InviteCodeStatus.loading, clearMessage: true);
    notifyListeners();
    try {
      final invite = await gateway.fetchPersonalInvitation();
      if (_disposed) return;
      state = InviteCodeState(
        status: InviteCodeStatus.ready,
        invite: invite,
      );
      notifyListeners();
    } catch (_) {
      if (_disposed) return;
      state = state.copyWith(
        status: InviteCodeStatus.failed,
        message: '邀请码加载失败，请重试',
      );
      notifyListeners();
    }
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
    super.dispose();
  }
}
