import 'dart:async';

import 'package:flutter/foundation.dart';

import 'invite_snapshot_store.dart';

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

  /// 本地快照载荷（仅展示字段，不含任何凭据）。
  Map<String, dynamic> toJson() => {
        'bound_at': boundAt.toUtc().toIso8601String(),
        'nickname': nickname,
        'username': username,
      };
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

/// 邀请码控制器：本地优先加载（上次成功的邀请码与邀请历史首页立即展示），
/// 后台同步（已有数据时不再进入 loading，避免每次进入闪一次加载圈），
/// 失败不覆盖旧数据（刷新失败只提示，不把页面打回错误占位）。
/// 码固定不轮换，无需倒计时；手动刷新同步最新已用次数与邀请历史。
final class InviteCodeController extends ChangeNotifier {
  InviteCodeController({
    required this.gateway,
    this.historyGateway,
    InviteSnapshotStore? snapshots,
    Future<String?> Function()? cacheScope,
  })  : _injectedStore = snapshots,
        _cacheScope = cacheScope {
    _hydration = _hydrate();
  }

  final PersonalInvitationGateway gateway;

  /// 邀请历史数据源；缺省（如个人信息页只展示码与次数）不加载历史。
  final InviteHistoryGateway? historyGateway;

  /// 显式注入的本地快照仓库（测试用）；缺省时使用进程级共享实例。
  final InviteSnapshotStore? _injectedStore;

  /// 显式注入的作用域来源（测试用）；缺省时向 [gateway] 索取。
  final Future<String?> Function()? _cacheScope;

  InviteSnapshotStore? _store;
  late final Future<void> _hydration;

  /// 当前展示数据来自哪个账号作用域；账号切换后必须丢弃（绝不跨账号展示）。
  String? _snapshotScope;

  InviteCodeState state = const InviteCodeState();
  bool _disposed = false;
  bool _historyLoadingMore = false;

  /// 本地快照水合完成（测试等待用，页面无需等待）。
  Future<void> get hydrationDone => _hydration;

  /// 本地优先：进入页面先用上次成功的快照填状态，随后仍会后台刷新。
  Future<void> _hydrate() async {
    try {
      final store = _injectedStore ?? await InviteSnapshotStores.ensureLoaded();
      _store = store;
      final snapshot = store.read();
      if (snapshot == null || _disposed) return;
      // 账号作用域校验：无法确认属于当前账号就丢弃（宁可少显示）。
      final scope = await _resolveScope();
      if (_disposed) return;
      if (scope == null || scope != snapshot.scope) {
        unawaited(store.clear());
        return;
      }
      _snapshotScope = snapshot.scope;
      // 网络结果先到时不覆盖更新的数据。
      if (state.invite != null) return;
      final history = <InviteHistoryItem>[];
      for (final row in snapshot.history) {
        try {
          history.add(InviteHistoryItem.fromJson(row));
        } catch (_) {
          // 单条损坏只跳过该条。
        }
      }
      state = InviteCodeState(
        status: InviteCodeStatus.ready,
        invite: PersonalInvitation(
          code: snapshot.code,
          maxUses: snapshot.maxUses,
          useCount: snapshot.useCount,
          shareUrl: snapshot.shareUrl,
        ),
        historyStatus: history.isEmpty
            ? InviteHistoryStatus.idle
            : InviteHistoryStatus.ready,
        history: history,
        historyNextOffset: snapshot.historyNextOffset,
      );
      notifyListeners();
    } catch (_) {
      // 本地快照不可用不影响正常加载。
    }
  }

  Future<String?> _resolveScope() async {
    final resolver = _cacheScope;
    if (resolver != null) {
      try {
        return await resolver();
      } catch (_) {
        return null;
      }
    }
    // 静态类型为 Object：接口到无关接口的本地变量提升不可靠，显式按 Object 判断。
    final Object source = gateway;
    if (source is InviteCacheScopeProvider) {
      try {
        return await source.inviteCacheScope();
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// 账号切换保护：当前展示数据属于另一个账号时先丢弃再请求。
  Future<void> _dropForeignSnapshot() async {
    final snapshotScope = _snapshotScope;
    if (snapshotScope == null) return;
    final scope = await _resolveScope();
    if (_disposed) return;
    if (scope == snapshotScope) return;
    _snapshotScope = null;
    state = const InviteCodeState();
    unawaited(_store?.clear());
  }

  /// 落盘只缓存展示数据；作用域不可知时宁可不落盘，避免快照跨账号。
  Future<void> _persistSnapshot() async {
    final store = _store;
    final invite = state.invite;
    if (store == null || invite == null || _disposed) return;
    final scope = await _resolveScope();
    if (scope == null || _disposed) return;
    _snapshotScope = scope;
    try {
      await store.write(InviteSnapshot(
        scope: scope,
        code: invite.code,
        maxUses: invite.maxUses,
        useCount: invite.useCount,
        shareUrl: invite.shareUrl,
        history: [for (final item in state.history) item.toJson()],
        historyNextOffset: state.historyNextOffset,
        savedAt: DateTime.now(),
      ));
    } catch (_) {
      // 本地快照写失败不是刷新失败。
    }
  }

  Future<void> load() async {
    if (_disposed) return;
    if (_snapshotScope != null && state.invite != null) {
      await _dropForeignSnapshot();
      if (_disposed) return;
    }
    // 已有数据（本地快照或上次成功结果）时保持 ready：刷新期间旧码仍在屏幕上，
    // 不再出现「进入即闪加载圈」。
    final hasData = state.invite != null;
    state = hasData
        ? state.copyWith(clearMessage: true)
        : state.copyWith(
            status: InviteCodeStatus.loading, clearMessage: true);
    notifyListeners();
    try {
      final invite = await gateway.fetchPersonalInvitation();
      if (_disposed) return;
      // 保留已加载的邀请历史：刷新邀请码不应把历史列表清空。
      state = InviteCodeState(
        status: InviteCodeStatus.ready,
        invite: invite,
        historyStatus: state.historyStatus,
        history: state.history,
        historyNextOffset: state.historyNextOffset,
      );
      notifyListeners();
      unawaited(_persistSnapshot());
    } catch (_) {
      if (_disposed) return;
      if (state.invite != null) {
        // 失败不覆盖旧数据：码继续显示，只提示这次没刷新成功。
        state = state.copyWith(message: '邀请码刷新失败，正在显示上次结果');
      } else {
        state = state.copyWith(
          status: InviteCodeStatus.failed,
          message: '邀请码加载失败，请重试',
        );
      }
      notifyListeners();
    }
  }

  /// 邀请历史：首页加载（失败可重试；已有列表时刷新失败不清空）。
  Future<void> loadHistory({bool refresh = false}) async {
    final gateway = historyGateway;
    if (gateway == null) return;
    if (!refresh &&
        (state.historyStatus == InviteHistoryStatus.loading ||
            state.historyStatus == InviteHistoryStatus.ready)) {
      return;
    }
    final hasRows = state.history.isNotEmpty;
    if (hasRows) {
      // 有历史行时刷新不清列表、不进 loading 占位：旧行留在屏幕上。
      state = state.copyWith(historyStatus: InviteHistoryStatus.ready);
    } else {
      state = state.copyWith(
          historyStatus: InviteHistoryStatus.loading, clearHistory: true);
    }
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
      unawaited(_persistSnapshot());
    } catch (_) {
      if (_disposed) return;
      if (state.history.isNotEmpty) {
        // 失败不覆盖旧数据：错误占位只在从未成功过时出现。
        state = InviteCodeState(
          status: state.status,
          invite: state.invite,
          message: state.message,
          historyStatus: InviteHistoryStatus.ready,
          history: state.history,
          historyNextOffset: state.historyNextOffset,
        );
      } else {
        state = state.copyWith(historyStatus: InviteHistoryStatus.failed);
      }
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
