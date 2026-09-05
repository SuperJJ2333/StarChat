import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/notification_diagnostics.dart';

/// 结构化诊断日志：区分失败层级（sync 到达/策略抑制/系统调用/权限/
/// 渠道/前台服务/推送），且绝不落消息正文、Token、密钥或完整房间/事件 ID。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  NotificationDiagnostics diagnostics() => NotificationDiagnostics(
        store: MemoryNotificationDiagStore(),
        now: () => DateTime.fromMillisecondsSinceEpoch(1725400000000),
        capacity: 3,
      );

  test('record 按阶段记录并截断 eventId/roomId（脱敏）', () {
    final log = diagnostics();
    const longEventId = '\$veryLongOpaqueEventIdWithSecretSuffix123456';
    log.record(
      NotificationDiagStage.suppressed,
      'muted',
      eventId: longEventId,
      roomId: '!veryLongOpaqueRoomIdWithSuffix:matrix.example',
    );
    final snapshot = log.snapshot();
    expect(snapshot, hasLength(1));
    final entry = snapshot.single;
    expect(entry.stage, NotificationDiagStage.suppressed);
    expect(entry.detail.contains('muted'), isTrue);
    // 完整 ID 不得出现：只允许 12 字符前缀。
    expect(entry.detail.contains(longEventId), isFalse);
    expect(entry.detail.contains(NotificationDiagnostics.shortId(longEventId)),
        isTrue);
  });

  test('环形缓冲：超出容量丢弃最旧条目', () {
    final log = diagnostics();
    for (var i = 0; i < 5; i++) {
      log.record(NotificationDiagStage.policy, 'event#$i');
    }
    final details = log.snapshot().map((e) => e.detail).toList();
    expect(details, ['event#2', 'event#3', 'event#4']);
  });

  test('export 输出可复制文本（阶段标签 + 摘要行）', () {
    final log = diagnostics();
    log.record(NotificationDiagStage.permission, 'granted');
    log.record(NotificationDiagStage.systemShow, 'ok id=99');
    final text = log.export();
    expect(text, contains('[permission] granted'));
    expect(text, contains('[system_show] ok id=99'));
  });

  test('ensureLoaded 合并持久化条目且 clear 同时清空存储', () async {
    final store = MemoryNotificationDiagStore();
    final restored = NotificationDiagnostics(store: store, capacity: 3);
    restored.record(NotificationDiagStage.startup, 'boot');
    await restored.ensureLoaded();

    final log = NotificationDiagnostics(store: store, capacity: 3);
    await log.ensureLoaded();
    log.record(NotificationDiagStage.foregroundService, 'reassert');
    expect(
      log.snapshot().map((e) => e.detail).toList(),
      ['boot', 'reassert'],
      reason: '重启后应能看到之前的诊断条目',
    );

    await log.clear();
    expect(log.snapshot(), isEmpty);
    final fresh = NotificationDiagnostics(store: store, capacity: 3);
    await fresh.ensureLoaded();
    expect(fresh.snapshot(), isEmpty, reason: 'clear 必须同时清空持久层');
  });

  test('持久化内容不含正文/Token/密钥字段（结构白名单）', () async {
    final store = MemoryNotificationDiagStore();
    final log = NotificationDiagnostics(store: store);
    log.record(NotificationDiagStage.syncArrived, 'rooms=1',
        eventId: '\$opaqueEventId', roomId: '!opaqueRoom:matrix.example');
    await log.ensureLoaded();
    final raw = await store.read();
    expect(raw, isNotNull);
    final decoded = jsonDecode(raw!) as List;
    for (final entry in decoded.cast<Map<String, Object?>>()) {
      expect(entry.keys.toSet(), {'stage', 'detail', 'at'},
          reason: '诊断条目只允许 stage/detail/at 三个字段');
      expect(entry['detail']!.toString().contains('content'), isFalse);
      expect(entry['detail']!.toString().contains('token'), isFalse);
    }
  });
}

final class MemoryNotificationDiagStore implements NotificationDiagStore {
  String? _encoded;

  @override
  Future<String?> read() async => _encoded;

  @override
  Future<void> write(String encoded) async => _encoded = encoded;
}
