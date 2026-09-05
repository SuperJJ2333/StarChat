import 'dart:async';

import 'package:flutter/foundation.dart';

/// kConnected 丢失兜底（规格 §五）：被叫 accept 后若 Matrix SDK 的
/// `CallState.kConnected` 状态事件丢失，而 WebRTC peerConnection 实际
/// 已接通，主动补发 [emitConnected]（恰好一次）。
///
/// - 事件先到（[markConnected]）：立即停轮询，绝不补发；
/// - 轮询 [pollInterval] 检查 [isPeerConnected]，[timeout] 内未连则放弃；
/// - 一切失败静默（连接超时逻辑由 CallController 的 connectTimeout 兜底）。
final class ConnectedFallbackWatcher {
  ConnectedFallbackWatcher({
    required this.pollInterval,
    required this.timeout,
    required this.isPeerConnected,
    required this.emitConnected,
  });

  final Duration pollInterval;
  final Duration timeout;
  final Future<bool> Function() isPeerConnected;
  final void Function() emitConnected;

  Timer? _timer;
  bool _settled = false;
  bool _emitted = false;

  /// 超时或已补发/事件已到。
  bool get isDone => _settled;

  /// 本观察器是否已补发过（适配器据此去重后续 SDK 事件）。
  bool get didEmit => _emitted;

  void start() {
    _settled = false;
    _emitted = false;
    _timer?.cancel();
    var elapsed = Duration.zero;
    _timer = Timer.periodic(pollInterval, (timer) async {
      if (_settled) {
        timer.cancel();
        return;
      }
      elapsed += pollInterval;
      if (elapsed >= timeout) {
        timer.cancel();
        _settled = true;
        debugPrint('[call-fallback] peer 未在 ${timeout.inSeconds}s 内接通，放弃兜底');
        return;
      }
      try {
        if (!await isPeerConnected()) return;
      } catch (_) {
        return; // 单次查询失败继续轮询。
      }
      if (_settled) return;
      timer.cancel();
      _settled = true;
      if (!_emitted) {
        _emitted = true;
        debugPrint('[call-fallback] kConnected 丢失：peerConnection 已连，补发 connected');
        emitConnected();
      }
    });
  }

  /// SDK `CallState.kConnected` 事件到达：停轮询（绝不补发）。
  void markConnected() {
    _settled = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> stop() async {
    _settled = true;
    _timer?.cancel();
    _timer = null;
  }
}
