import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class LocalHiddenEvents {
  Future<void> hide(String roomId, String eventId);
  bool isHidden(String roomId, String eventId);
}

/// 「删除该聊天」：隐藏本机历史，并把会话从消息列表移除。
abstract interface class LocalClearedHistory {
  Future<void> clearThrough(String roomId, DateTime cutoff);
  DateTime? clearedThrough(String roomId);
}

/// 「清空聊天记录」：只隐藏本机历史，会话本身保持可见。
///
/// 必须与 [LocalClearedHistory] 分开存储：共用一个截止时间会让会话列表
/// 把"清空过历史"误判成"已删除该聊天"，从而把会话移出消息列表。
abstract interface class LocalHistoryClearance {
  Future<void> clearHistoryThrough(String roomId, DateTime cutoff);
  DateTime? historyClearedThrough(String roomId);
}

typedef LocalHistoryFilter = bool Function(String eventId, DateTime? timestamp);

abstract interface class LocalHistoryFilterSnapshots {
  LocalHistoryFilter readFilter(String roomId);
}

extension LocalHiddenEventsFiltering on LocalHiddenEvents {
  LocalHistoryFilter readFilter(String roomId) {
    final store = this;
    if (store is LocalHistoryFilterSnapshots) {
      return (store as LocalHistoryFilterSnapshots).readFilter(roomId);
    }
    return (id, timestamp) =>
        isEventHidden(roomId, id, eventTimestamp: timestamp);
  }

  /// 该房间本机历史被清空或被删除后的最晚截止时间戳；两者都隐藏消息，
  /// 但只有 [LocalClearedHistory] 的截止时间代表"会话已删除"。
  DateTime? lastHistoryCutoff(String roomId) {
    final store = this;
    final deleted = store is LocalClearedHistory
        ? (store as LocalClearedHistory).clearedThrough(roomId)
        : null;
    final cleared = store is LocalHistoryClearance
        ? (store as LocalHistoryClearance).historyClearedThrough(roomId)
        : null;
    if (deleted == null) return cleared;
    if (cleared == null) return deleted;
    return deleted.isAfter(cleared) ? deleted : cleared;
  }

  bool isEventHidden(String roomId, String eventId,
      {DateTime? eventTimestamp}) {
    if (isHidden(roomId, eventId)) return true;
    if (eventTimestamp == null) return false;
    final cutoff = lastHistoryCutoff(roomId);
    return cutoff != null && !eventTimestamp.isAfter(cutoff);
  }

  List<T> visibleItems<T>(
    String roomId,
    Iterable<T> items, {
    required String Function(T item) eventId,
    DateTime Function(T item)? eventTimestamp,
  }) {
    final hidden = readFilter(roomId);
    return items
        .where((item) => !hidden(eventId(item), eventTimestamp?.call(item)))
        .toList(growable: false);
  }
}

final class SharedPreferencesLocalHiddenEvents
    implements
        LocalHiddenEvents,
        LocalClearedHistory,
        LocalHistoryClearance,
        LocalHistoryFilterSnapshots {
  const SharedPreferencesLocalHiddenEvents({
    required this.preferences,
    required this.accountId,
  });

  /// 「删除该聊天」写；会话列表据此把会话移出消息列表。
  ///
  /// 升级兼容：本键在引入 [LocalHistoryClearance] 之前也被「清空聊天记录」
  /// 写入过，历史数据保持原有含义（删除信号），不做迁移，避免把用户已经
  /// 删除的会话重新显示出来。
  static const _deletedSuffix = 'cleared-through';

  /// 「清空聊天记录」写；只影响本机历史可见性，不影响会话是否显示。
  static const _historySuffix = 'history-cleared-through';

  final SharedPreferences preferences;
  final String accountId;

  @override
  LocalHistoryFilter readFilter(String roomId) {
    final ids =
        preferences.getStringList(_key(roomId))?.toSet() ?? const <String>{};
    final cutoff = _lastHistoryCutoff(roomId);
    return (id, timestamp) =>
        ids.contains(id) ||
        (cutoff != null &&
            timestamp != null &&
            !timestamp.isAfter(cutoff));
  }

  DateTime? _lastHistoryCutoff(String roomId) {
    final deleted = clearedThrough(roomId);
    final cleared = historyClearedThrough(roomId);
    if (deleted == null) return cleared;
    if (cleared == null) return deleted;
    return deleted.isAfter(cleared) ? deleted : cleared;
  }

  String _key(String roomId) {
    final scope = sha256.convert(utf8.encode('$accountId\u0000$roomId'));
    return 'changliao.hidden-events.v1.$scope';
  }

  @override
  DateTime? clearedThrough(String roomId) =>
      _storedCutoff('${_key(roomId)}.$_deletedSuffix');

  @override
  DateTime? historyClearedThrough(String roomId) =>
      _storedCutoff('${_key(roomId)}.$_historySuffix');

  DateTime? _storedCutoff(String key) {
    final milliseconds = preferences.getInt(key);
    return milliseconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  }

  @override
  Future<void> clearThrough(String roomId, DateTime cutoff) =>
      _storeCutoff('${_key(roomId)}.$_deletedSuffix', cutoff);

  @override
  Future<void> clearHistoryThrough(String roomId, DateTime cutoff) =>
      _storeCutoff('${_key(roomId)}.$_historySuffix', cutoff);

  /// 截止时间只前进不后退：重复清空不得把已隐藏的历史重新暴露出来。
  Future<void> _storeCutoff(String key, DateTime cutoff) async {
    final previous = preferences.getInt(key);
    if (previous != null && cutoff.millisecondsSinceEpoch <= previous) return;
    final saved =
        await preferences.setInt(key, cutoff.millisecondsSinceEpoch);
    if (!saved) throw StateError('Unable to save local history cutoff');
  }

  @override
  Future<void> hide(String roomId, String eventId) async {
    final key = _key(roomId);
    final ids = preferences.getStringList(key)?.toSet() ?? <String>{};
    ids.add(eventId);
    final stable = ids.toList(growable: false)..sort();
    await preferences.setStringList(key, stable);
  }

  @override
  bool isHidden(String roomId, String eventId) =>
      preferences.getStringList(_key(roomId))?.contains(eventId) ?? false;
}
