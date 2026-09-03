import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/notification_diagnostics.dart';
import 'package:liuhetong_mobile/core/notification/notification_system_bootstrapper.dart';

/// 根因：AppHome.initState 曾并发调用 _startNotificationSystem() 两次，
/// 产生两套 eventSource/coordinator/deduplicator（首套泄漏整个登录会话，
/// 双声/双震/双系统通知）。单例启动器必须保证一次装配 + 失败可重试。
void main() {
  late _AssemblyCalls calls;
  late NotificationDiagnostics diagnostics;

  setUp(() {
    calls = _AssemblyCalls();
    diagnostics = NotificationDiagnostics(store: _MemoryDiagStore());
  });

  NotificationSystemBootstrapper bootstrapper({
    bool failStart = false,
  }) =>
      NotificationSystemBootstrapper(
        start: calls.start(fail: failStart),
        stop: calls.stop,
        onReady: calls.onReady,
        diagnostics: diagnostics,
      );

  test('并发与重复 ensureStarted 只装配一次（单例语义）', () async {
    final boot = bootstrapper();
    final results = await Future.wait(
        [boot.ensureStarted(), boot.ensureStarted(), boot.ensureStarted()]);
    expect(results, everyElement(isTrue));
    expect(calls.starts, 1, reason: '禁止创建第二套通知协调器/事件源');
    expect(calls.readies, 1);
    expect(boot.isReady, isTrue);
    // 就绪后再次调用不得重复装配。
    expect(await boot.ensureStarted(), isTrue);
    expect(calls.starts, 1);
  });

  test('启动失败：needsRetry 置位、不抛出、留下诊断；重试成功后就绪', () async {
    var failNext = true;
    final boot = NotificationSystemBootstrapper(
      start: calls.start(fail: false, failFirst: () => failNext),
      stop: calls.stop,
      onReady: calls.onReady,
      diagnostics: diagnostics,
    );
    expect(await boot.ensureStarted(), isFalse);
    expect(boot.isReady, isFalse);
    expect(boot.needsRetry, isTrue, reason: '生命周期恢复时据此重试');
    expect(
      diagnostics
          .snapshot()
          .any((e) => e.stage == NotificationDiagStage.startup),
      isTrue,
      reason: '启动失败必须留下可定位的诊断（不得静默吞掉）',
    );

    failNext = false;
    expect(await boot.ensureStarted(), isTrue);
    expect(boot.isReady, isTrue);
    expect(boot.needsRetry, isFalse);
    expect(calls.starts, 1, reason: '成功装配只此一次（首次失败未计入）');
  });

  test('dispose：清理一次、幂等；dispose 后禁止复活', () async {
    final boot = bootstrapper();
    await boot.ensureStarted();
    await boot.dispose();
    await boot.dispose();
    expect(calls.stops, 1);
    expect(boot.isReady, isFalse);
    expect(await boot.ensureStarted(), isFalse, reason: '会话已结束，不得重启旧装配');
    expect(calls.starts, 1);
  });

  test('dispose 中 stop 失败不抛出（退出登录不被通知清理卡住）', () async {
    final boot = NotificationSystemBootstrapper(
      start: calls.start(fail: false),
      stop: calls.failingStop,
      onReady: calls.onReady,
      diagnostics: diagnostics,
    );
    await boot.ensureStarted();
    await boot.dispose();
    expect(calls.stops, 1);
  });
}

final class _AssemblyCalls {
  var starts = 0;
  var stops = 0;
  var readies = 0;

  Future<void> Function() start({
    required bool fail,
    bool Function()? failFirst,
  }) =>
      () async {
        if (fail || (failFirst?.call() ?? false)) {
          throw StateError('coordinator start failed');
        }
        starts++;
      };

  Future<void> stop() async => stops++;

  Future<void> failingStop() async {
    stops++;
    throw StateError('dispose failed');
  }

  void onReady() => readies++;
}

final class _MemoryDiagStore implements NotificationDiagStore {
  String? _encoded;

  @override
  Future<String?> read() async => _encoded;

  @override
  Future<void> write(String encoded) async => _encoded = encoded;
}
