import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 通知链路诊断阶段：用于区分失败发生在哪一层
/// （sync 是否到达 / 是否进入策略引擎 / 是否被抑制 / 系统调用是否成功 /
/// 权限与渠道状态 / 前台服务是否真实运行 / 推送注册与点击）。
enum NotificationDiagStage {
  startup('startup'),
  syncArrived('sync_arrived'),
  policy('policy'),
  suppressed('suppressed'),
  systemShow('system_show'),
  permission('permission'),
  channel('channel'),
  foregroundService('fgs'),
  push('push');

  const NotificationDiagStage(this.label);

  final String label;
}

final class NotificationDiagEntry {
  const NotificationDiagEntry({
    required this.stage,
    required this.detail,
    required this.at,
  });

  final NotificationDiagStage stage;
  final String detail;
  final DateTime at;

  Map<String, Object?> toJson() => {
        'stage': stage.label,
        'detail': detail,
        'at': at.toIso8601String(),
      };

  static NotificationDiagEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final stageLabel = json['stage']?.toString();
    final detail = json['detail']?.toString();
    final at = DateTime.tryParse(json['at']?.toString() ?? '');
    if (stageLabel == null || detail == null || at == null) return null;
    final stage = NotificationDiagStage.values
        .where((candidate) => candidate.label == stageLabel)
        .firstOrNull;
    if (stage == null) return null;
    return NotificationDiagEntry(stage: stage, detail: detail, at: at);
  }

  @override
  String toString() => '${at.toIso8601String()} [${stage.label}] $detail';
}

/// 诊断持久层（环形缓冲最近 N 条；只存 stage/detail/at 三字段）。
abstract interface class NotificationDiagStore {
  Future<String?> read();

  Future<void> write(String encoded);
}

final class SharedPreferencesNotificationDiagStore
    implements NotificationDiagStore {
  const SharedPreferencesNotificationDiagStore();

  static const prefsKey = 'notification.diagnostics.v1';

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(prefsKey);

  @override
  Future<void> write(String encoded) async =>
      (await SharedPreferences.getInstance()).setString(prefsKey, encoded);
}

/// 结构化诊断日志（脱敏）：
/// - 绝不记录消息正文、Token、密钥；房间/事件 ID 仅保留 12 字符前缀
///   （Matrix ID 为 opaque 标识，前缀足以排障比对）；
/// - 持久化尽力而为，失败只影响历史回看，绝不影响通知主流程；
/// - debugPrint 带 `[chatflow/notif-diag]` 前缀，便于 adb/logcat 过滤。
final class NotificationDiagnostics {
  NotificationDiagnostics({
    NotificationDiagStore? store,
    DateTime Function()? now,
    this.capacity = 120,
  })  : store = store ?? const SharedPreferencesNotificationDiagStore(),
        now = now ?? DateTime.now;

  static final NotificationDiagnostics shared = NotificationDiagnostics();

  static const _idPrefixLength = 12;

  final NotificationDiagStore store;
  final DateTime Function() now;
  final int capacity;

  final List<NotificationDiagEntry> _entries = [];
  bool _loaded = false;
  bool _writing = false;

  /// ID 截断：完整房间/事件 ID 不落日志与持久层。
  static String shortId(String id) =>
      id.length <= _idPrefixLength ? id : id.substring(0, _idPrefixLength);

  void record(
    NotificationDiagStage stage,
    String detail, {
    String? eventId,
    String? roomId,
  }) {
    var text = detail;
    if (eventId != null || roomId != null) {
      text = '$detail (event=${_short(eventId)}, room=${_short(roomId)})';
    }
    final entry = NotificationDiagEntry(
      stage: stage,
      detail: text,
      at: now(),
    );
    _entries.add(entry);
    while (_entries.length > capacity) {
      _entries.removeAt(0);
    }
    debugPrint('[chatflow/notif-diag] $entry');
    _persist();
  }

  /// 启动时恢复历史条目（设置页诊断视图可见跨重启记录）。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await store.read();
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final restored = <NotificationDiagEntry>[
        for (var i = decoded.length - 1; i >= 0; i--)
          if (NotificationDiagEntry.fromJson(decoded[i]) case final entry?)
            entry,
      ];
      _entries.insertAll(0, restored);
      while (_entries.length > capacity) {
        _entries.removeAt(0);
      }
    } catch (_) {
      // 历史损坏则从空开始，不影响新增记录。
    }
  }

  List<NotificationDiagEntry> snapshot() => List.unmodifiable(_entries);

  /// 设置页"通知诊断"导出的可复制文本。
  String export() => _entries.map((entry) => entry.toString()).join('\n');

  Future<void> clear() async {
    _entries.clear();
    try {
      await store.write('[]');
    } catch (_) {}
  }

  void _persist() {
    if (!_loaded) {
      // 尚未加载历史：先恢复再合并写入，避免覆盖旧记录。
      unawaited(ensureLoaded().then((_) => _persist()));
      return;
    }
    if (_writing) return;
    _writing = true;
    unawaited(() async {
      try {
        await store.write(jsonEncode([
          for (final entry in _entries) entry.toJson(),
        ]));
      } catch (_) {
        // 持久化失败不影响主流程。
      } finally {
        _writing = false;
      }
    }());
  }

  String _short(String? id) => id == null || id.isEmpty ? '-' : shortId(id);
}
