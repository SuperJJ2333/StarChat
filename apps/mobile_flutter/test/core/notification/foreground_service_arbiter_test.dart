import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/foreground_service_arbiter.dart';
import 'package:liuhetong_mobile/core/notification/notification_diagnostics.dart';
import 'package:liuhetong_mobile/core/notification/sync_keepalive_service.dart';
import 'package:liuhetong_mobile/features/matrix/call_notifications.dart';

/// 根因：flutter_local_notifications 全局仅一个 Android ForegroundService，
/// 通话结束的 stopForegroundService 会同时杀掉消息保活（同一 OS 服务）。
/// 仲裁器必须保证：通话释放后保活被重申而不是被停止。
void main() {
  late _RecordingForegroundBackend backend;
  late NotificationDiagnostics diagnostics;

  ForegroundServiceRequest keepAliveRequest() => const ForegroundServiceRequest(
        notificationId: 41003,
        channelId: 'chatflow_sync',
        channelName: '消息同步',
        channelDescription: '保持消息与来电实时到达的后台同步服务',
        title: '畅聊消息服务运行中',
        body: '保持消息与来电实时到达',
      );

  ForegroundServiceRequest callRequest() => ForegroundServiceRequest(
        notificationId: CallNotifications.ongoingCallId,
        channelId: 'call-ongoing',
        channelName: '通话中',
        channelDescription: '通话进行中的常驻通知',
        title: '畅聊通话中',
        body: '通话中',
        category: AndroidNotificationCategory.call,
        foregroundServiceTypes: const {
          AndroidServiceForegroundType.foregroundServiceTypeMicrophone,
          AndroidServiceForegroundType.foregroundServiceTypeCamera,
        },
      );

  setUp(() {
    backend = _RecordingForegroundBackend();
    diagnostics = NotificationDiagnostics(
      store: MemoryNotificationDiagStoreShim(),
    );
  });

  ForegroundServiceArbiter arbiterInstance() => ForegroundServiceArbiter(
        backend: backend,
        diagnostics: diagnostics,
      );

  group('仲裁器状态机', () {
    test('唯一 owner：acquire 应用其请求', () async {
      final arbiter = arbiterInstance();
      await arbiter.acquire(
          ForegroundServiceOwner.keepAlive, keepAliveRequest());
      expect(backend.starts, hasLength(1));
      expect(backend.starts.single.notificationId, 41003);
      expect(backend.stops, 0);
      expect(arbiter.isActive(ForegroundServiceOwner.keepAlive), isTrue);
    });

    test('通话优先：通话期间 acquire 不打断通话呈现', () async {
      final arbiter = arbiterInstance();
      await arbiter.acquire(
          ForegroundServiceOwner.keepAlive, keepAliveRequest());
      await arbiter.acquire(ForegroundServiceOwner.ongoingCall, callRequest());
      // 保活的重复 acquire（看门狗重申）不得把通话通知顶掉。
      await arbiter.acquire(
          ForegroundServiceOwner.keepAlive, keepAliveRequest());
      expect(
          backend.starts.last.notificationId, CallNotifications.ongoingCallId,
          reason: '通话前台服务优先级高于消息保活');
      expect(backend.stops, 0);
    });

    test('核心回归：通话结束不得停止消息保活，必须重申保活通知', () async {
      final arbiter = arbiterInstance();
      await arbiter.acquire(
          ForegroundServiceOwner.keepAlive, keepAliveRequest());
      await arbiter.acquire(ForegroundServiceOwner.ongoingCall, callRequest());
      await arbiter.release(ForegroundServiceOwner.ongoingCall);
      expect(backend.stops, 0, reason: '保活仍持有所有权时禁止 stopService');
      expect(backend.starts.last.notificationId, 41003,
          reason: '通话释放后必须回写保活通知');
      expect(arbiter.isActive(ForegroundServiceOwner.keepAlive), isTrue);
    });

    test('保活在通话期间释放：通话不受影响', () async {
      final arbiter = arbiterInstance();
      await arbiter.acquire(
          ForegroundServiceOwner.keepAlive, keepAliveRequest());
      await arbiter.acquire(ForegroundServiceOwner.ongoingCall, callRequest());
      await arbiter.release(ForegroundServiceOwner.keepAlive);
      expect(backend.stops, 0, reason: '通话仍持有所有权');
      expect(
          backend.starts.last.notificationId, CallNotifications.ongoingCallId);
      // 通话结束后无剩余 owner：此时才真正停止。
      await arbiter.release(ForegroundServiceOwner.ongoingCall);
      expect(backend.stops, 1);
    });

    test('全部释放才停止，且 stop 只调一次', () async {
      final arbiter = arbiterInstance();
      await arbiter.acquire(
          ForegroundServiceOwner.keepAlive, keepAliveRequest());
      await arbiter.release(ForegroundServiceOwner.keepAlive);
      await arbiter.release(ForegroundServiceOwner.keepAlive);
      expect(backend.stops, 1);
    });

    test('reassert：无 owner 时为空操作，有 owner 时重申最高优先级', () async {
      final arbiter = arbiterInstance();
      await arbiter.reassert();
      expect(backend.starts, isEmpty);
      await arbiter.acquire(
          ForegroundServiceOwner.keepAlive, keepAliveRequest());
      await arbiter.reassert();
      expect(backend.starts, hasLength(2));
      expect(backend.starts.last.notificationId, 41003);
    });

    test('后端失败不抛出（保活尽力而为）且记录诊断', () async {
      backend.failStart = true;
      final arbiter = arbiterInstance();
      await arbiter.acquire(
          ForegroundServiceOwner.keepAlive, keepAliveRequest());
      expect(
        diagnostics
            .snapshot()
            .any((e) => e.stage == NotificationDiagStage.foregroundService),
        isTrue,
        reason: '前台服务失败必须留下诊断痕迹（可定位层级）',
      );
    });
  });

  group('跨业务集成（keepalive + 通话共用一个仲裁器）', () {
    test('看门狗重申与通话呈现互不干扰；通话结束回写保活', () async {
      final arbiter = arbiterInstance();
      final keepAlive = SyncKeepAliveService(
        backend: ArbiterSyncKeepAliveBackend(arbiter: arbiter),
        hooks: const _NoopHooks(),
      );
      await keepAlive.ensureStarted();
      expect(backend.starts.single.notificationId, 41003);

      // 模拟 CallNotifications.showOngoing：经同一仲裁器获取通话所有权。
      await arbiter.acquire(ForegroundServiceOwner.ongoingCall,
          CallNotifications.ongoingCallRequest(title: '张三'));
      expect(backend.starts.last.notificationId, 41002);

      // keepalive 看门狗周期重申（不得顶掉通话通知）。
      await keepAlive.runWatchdogTick();
      expect(backend.starts.last.notificationId, 41002,
          reason: '看门狗重申不得打断通话前台服务');
      expect(backend.stops, 0);

      // 通话结束（hideOngoing）：保活必须被重申而非停止。
      await arbiter.release(ForegroundServiceOwner.ongoingCall);
      expect(backend.stops, 0);
      expect(backend.starts.last.notificationId, 41003);
      expect(keepAlive.isRunning, isTrue);

      // 退出登录：保活释放后服务真正停止。
      await keepAlive.stop();
      expect(backend.stops, 1);
    });
  });
}

final class _RecordingForegroundBackend implements ForegroundServiceBackend {
  final starts = <ForegroundServiceRequest>[];
  var stops = 0;
  var failStart = false;

  @override
  Future<void> start(ForegroundServiceRequest request) async {
    if (failStart) throw StateError('foreground service denied');
    starts.add(request);
  }

  @override
  Future<void> stop() async => stops++;
}

final class _NoopHooks implements KeepAliveHooks {
  const _NoopHooks();

  @override
  Future<void> acquire() async {}

  @override
  Future<void> release() async {}
}

/// 测试内存诊断存储（诊断持久层走 SharedPreferences，单测用内存替身）。
final class MemoryNotificationDiagStoreShim implements NotificationDiagStore {
  String? _encoded;

  @override
  Future<String?> read() async => _encoded;

  @override
  Future<void> write(String encoded) async => _encoded = encoded;
}
