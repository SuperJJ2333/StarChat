import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/call_connected_fallback.dart';

void main() {
  test('kConnected 事件先到：轮询立即停止，绝不补发', () async {
    var emitted = 0;
    var polls = 0;
    final watcher = ConnectedFallbackWatcher(
      pollInterval: const Duration(milliseconds: 20),
      timeout: const Duration(seconds: 10),
      isPeerConnected: () async {
        polls++;
        // 事件先到前提：peer 状态尚未就绪（"事件丢失+peer已连"由下一
        // 测试覆盖）。
        return false;
      },
      emitConnected: () => emitted++,
    );
    watcher.start();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    watcher.markConnected(); // SDK kConnected 事件到达
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final pollsAtMark = polls;
    expect(emitted, 0, reason: '事件已到不得重复补发');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(polls, pollsAtMark, reason: 'markConnected 后轮询必须停止');
    await watcher.stop();
  });

  test('kConnected 丢失：peerConnection 已连 → 兜底补发恰好一次', () async {
    var emitted = 0;
    var peerConnected = false;
    final watcher = ConnectedFallbackWatcher(
      pollInterval: const Duration(milliseconds: 20),
      timeout: const Duration(seconds: 10),
      isPeerConnected: () async => peerConnected,
      emitConnected: () => emitted++,
    );
    watcher.start();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    peerConnected = true; // ICE 实际接通但 SDK 状态事件丢失
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(emitted, 1, reason: '兜底补发且只发一次');
    await watcher.stop();
    expect(emitted, 1, reason: 'stop 后不再补发');
  });

  test('10 秒内 peer 未连：超时静默放弃（不 emit，不崩）', () async {
    var emitted = 0;
    final watcher = ConnectedFallbackWatcher(
      pollInterval: const Duration(milliseconds: 20),
      timeout: const Duration(milliseconds: 150),
      isPeerConnected: () async => false,
      emitConnected: () => emitted++,
    );
    watcher.start();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(emitted, 0);
    expect(watcher.isDone, isTrue, reason: '超时后观察器完结');
    await watcher.stop();
  });

  test('stop 立即停轮询', () async {
    var polls = 0;
    final watcher = ConnectedFallbackWatcher(
      pollInterval: const Duration(milliseconds: 20),
      timeout: const Duration(seconds: 10),
      isPeerConnected: () async {
        polls++;
        return false;
      },
      emitConnected: () {},
    );
    watcher.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await watcher.stop();
    final after = polls;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(polls, after, reason: 'stop 后不得再轮询');
  });
}
