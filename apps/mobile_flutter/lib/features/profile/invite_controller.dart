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

/// 一条邀请历史：邀请码被一位好友使用（注册消耗）的记录。
final class InviteHistoryItem {
  const InviteHistoryItem({
    required this.boundAt,
    required this.nickname,
    required this.username,
  });

  final DateTime boundAt;
  final String? nickname;
  final String username;

  factory InviteHistoryItem.fromJson(Map<String, dynamic> json) =>
      InviteHistoryItem(
        boundAt:
            DateTime.tryParse(json['bound_at']?.toString() ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
        nickname: json['nickname']?.toString(),
        username: json['username'] as String,
      );

  String get displayNickname =>
      (nickname == null || nickname!.trim().isEmpty) ? '未设置昵称' : nickname!;
}

/// 邀请历史分页结果：`nextOffset == null` 表示已到末页。
final class InviteHistoryPage {
  const InviteHistoryPage({required this.items, this.nextOffset});

  final List<InviteHistoryItem> items;
  final int? nextOffset;
}

abstract interface class InviteHistoryGateway {
  Future<InviteHistoryPage> fetchInviteHistory(
      {int limit = 20, int offset = 0});
}

enum InviteCodeStatus { idle, loading, ready, failed }

enum InviteHistoryStatus { idle, loading, ready, failed }

final class InviteCodeState {
  const InviteCodeState({
    this.status = InviteCodeStatus.idle,
    this.invite,
    this.message,
    this.historyStatus = InviteHistoryStatus.idle,
    this.history = const [],
    this.historyNextOffset,
  });

  final InviteCodeStatus status;
  final PersonalInvitation? invite;
  final String? message;
  final InviteHistoryStatus historyStatus;
  final List<InviteHistoryItem> history;

  /// 下一页 offset；null 表示邀请历史已加载完毕。
  final int? historyNextOffset;

  InviteCodeState copyWith({
    InviteCodeStatus? status,
    PersonalInvitation? invite,
    String? message,
    bool clearMessage = false,
    InviteHistoryStatus? historyStatus,
    List<InviteHistoryItem>? history,
    int? historyNextOffset,
    bool clearHistory = false,
  }) =>
      InviteCodeState(
        status: status ?? this.status,
        invite: invite ?? this.invite,
        message: clearMessage ? null : (message ?? this.message),
        historyStatus: historyStatus ?? this.historyStatus,
        history: history ?? this.history,
        historyNextOffset:
            clearHistory ? null : (historyNextOffset ?? this.historyNextOffset),
      );
}

/// 邀请码控制器：打开页面即拉取个人注册邀请码；失败可重试（弱网）。
/// 码固定不轮换，无需倒计时；手动刷新同步最新已用次数。
final class InviteCodeController extends ChangeNotifier {
  InviteCodeController({required this.gateway, this.historyGateway});

  final PersonalInvitationGateway gateway;

  /// 邀请历史数据源；缺省（如个人信息页只展示码与次数）不加载历史。
  final InviteHistoryGateway? historyGateway;
  InviteCodeState state = const InviteCodeState();
  bool _disposed = false;
  bool _historyLoadingMore = false;

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

  /// 邀请历史：首页加载（失败可重试）。
  Future<void> loadHistory({bool refresh = false}) async {
    final gateway = historyGateway;
    if (gateway == null) return;
    if (!refresh &&
        (state.historyStatus == InviteHistoryStatus.loading ||
            state.historyStatus == InviteHistoryStatus.ready)) {
      return;
    }
    state = state.copyWith(
        historyStatus: InviteHistoryStatus.loading, clearHistory: true);
    notifyListeners();
    try {
      final page = await gateway.fetchInviteHistory(offset: 0);
      if (_disposed) return;
      state = InviteCodeState(
        status: state.status,
        invite: state.invite,
        message: state.message,
        historyStatus: InviteHistoryStatus.ready,
        history: page.items,
        historyNextOffset: page.nextOffset,
      );
      notifyListeners();
    } catch (_) {
      if (_disposed) return;
      state = state.copyWith(historyStatus: InviteHistoryStatus.failed);
      notifyListeners();
    }
  }

  /// 邀请历史：加载下一页（追加；重复调用被串行化）。
  Future<void> loadMoreHistory() async {
    final gateway = historyGateway;
    final next = state.historyNextOffset;
    if (gateway == null || next == null || _historyLoadingMore) return;
    _historyLoadingMore = true;
    try {
      final page = await gateway.fetchInviteHistory(offset: next);
      if (_disposed) return;
      state = InviteCodeState(
        status: state.status,
        invite: state.invite,
        message: state.message,
        historyStatus: state.historyStatus,
        history: [...state.history, ...page.items],
        historyNextOffset: page.nextOffset,
      );
      notifyListeners();
    } catch (_) {
      // 追加失败保留现有列表；nextOffset 不变，用户可再次点击加载。
    } finally {
      _historyLoadingMore = false;
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
