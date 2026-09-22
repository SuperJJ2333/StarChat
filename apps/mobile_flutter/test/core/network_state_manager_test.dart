import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/core/network_state_manager.dart';

// 测试侧允许导入 package:http，用来验证默认分类器对真实
// http.ClientException / 5xx 响应的鸭子类型判定；实现文件本身不导入它。

void main() {
  group('发送失败类型化（2026-09-19 房间瘫痪修复）', () {
    test('MessageSendNetworkException（SDK 发送重试耗尽）判定为网络失败', () {
      expect(
          defaultNetworkFailureClassifier(
              const MessageSendNetworkException('消息发送失败')),
          isTrue,
          reason: 'SDK 只有网络类错误才会耗尽重试窗口并返回 null，'
              '该异常必须归类为网络失败 → waitingNetwork（自动重发）');
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);
      manager.report(transportAvailable: true);
      manager.reportFailure(const MessageSendNetworkException('消息发送失败'));
      expect(manager.current, NetworkState.weak, reason: '上报网络状态机，供恢复判定使用');
    });
  });

  group('NetworkStateManager 基础状态', () {
    test('初始状态为 online，shared 是可写的组合根槽位', () {
      expect(NetworkStateManager.shared, isNull);
      final manager = NetworkStateManager();
      expect(manager.current, NetworkState.online);
      NetworkStateManager.shared = manager;
      expect(NetworkStateManager.shared, same(manager));
      NetworkStateManager.shared = null;
      manager.dispose();
    });

    test('传输层不可用即 offline，恢复可用即 online', () {
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);

      manager.report(transportAvailable: false);
      expect(manager.current, NetworkState.offline);

      manager.report(transportAvailable: true);
      expect(manager.current, NetworkState.online);
    });

    test('传输层可用时单次网络失败只到 weak', () {
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);

      manager.report(transportAvailable: true);
      manager.reportFailure(const SocketException('connection refused'));
      expect(manager.current, NetworkState.weak);
    });

    test('传输层可用时连续两次网络失败到 offline，成功后退回 online', () {
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);

      manager.report(transportAvailable: true);
      manager.reportFailure(const SocketException('connection reset'));
      expect(manager.current, NetworkState.weak);
      manager.reportFailure(TimeoutException('request timed out'));
      expect(manager.current, NetworkState.offline);

      manager.reportSuccess();
      expect(manager.current, NetworkState.online);
    });

    test('失败计数可配置：offlineFailureStreak = 3', () {
      final manager = NetworkStateManager(offlineFailureStreak: 3);
      addTearDown(manager.dispose);

      manager.reportFailure(const SocketException('a'));
      manager.reportFailure(const SocketException('b'));
      expect(manager.current, NetworkState.weak);
      manager.reportFailure(const SocketException('c'));
      expect(manager.current, NetworkState.offline);
    });

    test('serverReachable 上报走同一条失败/成功路径', () {
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);

      manager.report(serverReachable: false);
      expect(manager.current, NetworkState.weak);
      manager.report(serverReachable: false);
      expect(manager.current, NetworkState.offline);

      manager.report(
        serverReachable: true,
        lastRoundTrip: const Duration(seconds: 3),
      );
      expect(manager.current, NetworkState.weak);
      manager.reportSuccess();
      expect(manager.current, NetworkState.online);
    });

    test('成功后失败计数清零，重新从 weak 开始累积', () {
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);

      manager.reportFailure(const SocketException('a'));
      manager.reportFailure(const SocketException('b'));
      expect(manager.current, NetworkState.offline);

      manager.reportSuccess();
      expect(manager.current, NetworkState.online);

      manager.reportFailure(const SocketException('c'));
      expect(manager.current, NetworkState.weak);
    });
  });

  group('NetworkStateManager 延迟判定', () {
    test('慢成功为 weak，快速成功回到 online', () {
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);

      manager.reportSuccess(roundTrip: const Duration(seconds: 3));
      expect(manager.current, NetworkState.weak);

      manager.reportSuccess(roundTrip: const Duration(milliseconds: 120));
      expect(manager.current, NetworkState.online);
    });

    test('阈值可注入，且等于阈值仍算 online', () {
      final manager = NetworkStateManager(
        weakRoundTripThreshold: const Duration(milliseconds: 500),
      );
      addTearDown(manager.dispose);

      manager.reportSuccess(roundTrip: const Duration(milliseconds: 600));
      expect(manager.current, NetworkState.weak);
      manager.reportSuccess(roundTrip: const Duration(milliseconds: 500));
      expect(manager.current, NetworkState.online);
      manager.reportSuccess(roundTrip: const Duration(milliseconds: 900));
      expect(manager.current, NetworkState.weak);
    });

    test('无耗时的成功清空旧的高延迟测量', () {
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);

      manager.reportSuccess(roundTrip: const Duration(seconds: 5));
      expect(manager.current, NetworkState.weak);
      manager.reportSuccess();
      expect(manager.current, NetworkState.online);
    });

    test('report(lastRoundTrip:) 只更新测量值，不改变失败计数', () {
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);

      manager.report(lastRoundTrip: const Duration(seconds: 4));
      expect(manager.current, NetworkState.weak);
      manager.report(lastRoundTrip: const Duration(milliseconds: 100));
      expect(manager.current, NetworkState.online);
    });
  });

  group('NetworkStateManager 失败分类', () {
    test('SocketException / TimeoutException / 5xx / ClientException 都算网络失败',
        () {
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);

      expect(
          defaultNetworkFailureClassifier(const SocketException('x')), isTrue);
      expect(defaultNetworkFailureClassifier(TimeoutException('x')), isTrue);
      expect(
        defaultNetworkFailureClassifier(http.Response('server error', 503)),
        isTrue,
      );
      expect(
        defaultNetworkFailureClassifier(http.ClientException('boom')),
        isTrue,
      );
      expect(
        defaultNetworkFailureClassifier(http.Response('not found', 404)),
        isFalse,
      );
      expect(defaultNetworkFailureClassifier(const FormatException('bad')),
          isFalse);
      expect(defaultNetworkFailureClassifier(StateError('bad')), isFalse);
    });

    test('非网络错误不改变状态', () {
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);

      manager.reportFailure(const FormatException('bad json'));
      manager.reportFailure(StateError('bad state'));
      expect(manager.current, NetworkState.online);

      manager.reportFailure(http.Response('bad request', 400));
      expect(manager.current, NetworkState.online);

      manager.reportFailure(http.Response('server error', 502));
      expect(manager.current, NetworkState.online);
    });

    test('Matrix 429 and 503 are retryable without declaring device offline',
        () {
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);
      for (final status in [429, 503]) {
        final error =
            MatrixException(http.Response('{"errcode":"M_UNKNOWN"}', status));
        expect(defaultNetworkFailureClassifier(error), isTrue);
        manager.reportFailure(error);
        manager.reportFailure(error);
        expect(manager.current, NetworkState.online);
      }
      expect(
          defaultNetworkFailureClassifier(
              MatrixException(http.Response('{"errcode":"M_FORBIDDEN"}', 403))),
          isFalse);
    });

    test('可注入自定义分类器，完全接管判定', () {
      final manager = NetworkStateManager(classifyFailure: (_) => true);
      addTearDown(manager.dispose);

      manager.reportFailure('任何错误都算网络失败');
      expect(manager.current, NetworkState.weak);
      manager.reportFailure('再来一次');
      expect(manager.current, NetworkState.offline);
    });
  });

  group('NetworkStateManager recovering', () {
    test('offline -> recovering -> online', () {
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);

      manager.report(transportAvailable: false);
      expect(manager.current, NetworkState.offline);

      manager.report(recovering: true);
      expect(manager.current, NetworkState.recovering);

      manager.reportSuccess();
      expect(manager.current, NetworkState.online);
    });

    test('传输层仍报不可用时，显式 recovering 优先', () {
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);

      manager.report(transportAvailable: false);
      manager.report(recovering: true);
      expect(manager.current, NetworkState.recovering);

      manager.report(recovering: false);
      expect(manager.current, NetworkState.offline);
    });

    test('重试期间再次失败会关闭 recovering 并回到离线判定', () {
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);

      manager.reportFailure(const SocketException('a'));
      manager.reportFailure(const SocketException('b'));
      expect(manager.current, NetworkState.offline);

      manager.report(recovering: true);
      expect(manager.current, NetworkState.recovering);

      manager.reportFailure(const SocketException('retry failed'));
      expect(manager.current, NetworkState.offline);
    });
  });

  group('NetworkStateManager whenOnline', () {
    test('已 online 时立即完成', () async {
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);

      await manager.whenOnline().timeout(const Duration(seconds: 1));
      expect(manager.current, NetworkState.online);
    });

    test('offline 时等待，恢复时所有等待者一起完成', () async {
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);

      manager.report(transportAvailable: false);
      var firstDone = false;
      var secondDone = false;
      final first = manager.whenOnline().then((_) => firstDone = true);
      final second = manager.whenOnline().then((_) => secondDone = true);

      await Future<void>.delayed(Duration.zero);
      expect(firstDone, isFalse);
      expect(secondDone, isFalse);

      manager.report(recovering: true);
      await Future.wait(<Future<void>>[first, second]);
      expect(firstDone, isTrue);
      expect(secondDone, isTrue);
    });

    test('recovering 期间注册的等待者立即完成', () async {
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);

      manager.report(transportAvailable: false);
      manager.report(recovering: true);
      await manager.whenOnline().timeout(const Duration(seconds: 1));
    });

    test('only report* drives whenOnline：不创建定时器', () async {
      final createdTimers = <Duration>[];
      late NetworkStateManager manager;
      late Future<void> pending;

      runZoned(
        () {
          manager = NetworkStateManager();
          manager.report(transportAvailable: false);
          pending = manager.whenOnline();
          manager.report(recovering: true);
          manager.report(transportAvailable: true);
          manager.reportSuccess();
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            createdTimers.add(duration);
            return parent.createTimer(zone, duration, callback);
          },
          createPeriodicTimer: (self, parent, zone, duration, callback) {
            createdTimers.add(duration);
            return parent.createPeriodicTimer(zone, duration, callback);
          },
        ),
      );

      expect(createdTimers, isEmpty, reason: 'whenOnline 必须由 report* 驱动，不得轮询');
      await pending.timeout(const Duration(seconds: 1));
      manager.dispose();
    });

    test('dispose 会完成悬挂的等待者，避免泄漏', () async {
      final manager = NetworkStateManager();
      manager.report(transportAvailable: false);
      final pending = manager.whenOnline();
      await Future<void>.delayed(Duration.zero);
      manager.dispose();
      await pending.timeout(const Duration(seconds: 1));
    });
  });

  group('NetworkStateManager 通知与生命周期', () {
    test('状态不变时不通知，变化时各通知一次', () {
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);
      final seen = <NetworkState>[];
      manager.state.addListener(() => seen.add(manager.current));

      manager.report(transportAvailable: true);
      manager.reportSuccess();
      manager.reportFailure(const FormatException('ignored'));
      expect(seen, isEmpty);

      manager.report(transportAvailable: false);
      manager.report(transportAvailable: false);
      expect(seen, <NetworkState>[NetworkState.offline]);

      manager.reportFailure(const SocketException('still offline'));
      expect(seen, <NetworkState>[NetworkState.offline]);

      manager.report(recovering: true);
      manager.report(recovering: true);
      manager.reportSuccess();
      expect(
        seen,
        <NetworkState>[
          NetworkState.offline,
          NetworkState.recovering,
          NetworkState.online,
        ],
      );
    });

    test('reset 回到初始状态并清空计数与延迟', () {
      final manager = NetworkStateManager();
      addTearDown(manager.dispose);

      manager.reportSuccess(roundTrip: const Duration(seconds: 5));
      manager.report(transportAvailable: false);
      manager.reportFailure(const SocketException('a'));
      manager.reportFailure(const SocketException('b'));
      expect(manager.current, NetworkState.offline);

      manager.reset();
      expect(manager.current, NetworkState.online);

      manager.reportFailure(const SocketException('c'));
      expect(manager.current, NetworkState.weak);
      manager.report(transportAvailable: true);
      expect(manager.current, NetworkState.weak);
      manager.reportSuccess();
      expect(manager.current, NetworkState.online);
    });

    test('dispose 后所有上报与等待都是安全空操作', () async {
      final manager = NetworkStateManager();
      var notifications = 0;
      manager.state.addListener(() => notifications++);
      manager.report(transportAvailable: false);
      expect(notifications, 1);

      manager.dispose();
      manager.dispose();

      expect(() {
        manager.report(
          transportAvailable: true,
          serverReachable: false,
          recovering: true,
          lastRoundTrip: const Duration(seconds: 9),
        );
        manager.reportFailure(const SocketException('after dispose'));
        manager.reportSuccess(roundTrip: const Duration(seconds: 9));
        manager.reset();
      }, returnsNormally);
      expect(notifications, 1);
      expect(manager.current, NetworkState.offline);
      await manager.whenOnline().timeout(const Duration(seconds: 1));
    });
  });
}
