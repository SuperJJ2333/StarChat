import 'package:flutter/foundation.dart';

/// 通话关键路径阶段（诊断埋点，脱敏——不含任何通话内容）。
enum CallDiagStage {
  inviteReceived('invite_received'),
  incomingUiShown('incoming_ui_shown'),
  answerTapped('answer_tapped'),
  answerSent('answer_sent'),
  iceConnected('ice_connected'),
  ended('ended');

  const CallDiagStage(this.label);

  final String label;
}

/// 通话关键路径耗时诊断：invite→来电UI→点击接听→接听信令→ICE 接通。
///
/// 由组合根创建并注入 backend 与 controller（同一实例，同一时间线）；
/// 每次新通话 reset。仅记录时间戳与差值 + debugPrint
/// `[chatflow/calldiag]`，供真机 logcat 定位慢阶段
/// （如 invite→ui 过长=成员校验阻塞；tap→ice 过长=协商/网络慢）。
final class CallDiagnostics {
  CallDiagnostics({DateTime Function()? now, ValueChanged<String>? log})
      : _now = now ?? DateTime.now,
        _log = log ?? _defaultLog;

  final DateTime Function() _now;
  final ValueChanged<String> _log;

  final Map<CallDiagStage, DateTime> _stamps = {};

  /// 新通话开始：清空上一通的时间线。
  void reset() => _stamps.clear();

  bool has(CallDiagStage stage) => _stamps.containsKey(stage);

  DateTime? at(CallDiagStage stage) => _stamps[stage];

  void mark(CallDiagStage stage) {
    if (_stamps.containsKey(stage)) return;
    _stamps[stage] = _now();
    _log('[chatflow/calldiag] ${describe(stage)}');
    debugPrint('[chatflow/calldiag] ${describe(stage)}');
  }

  /// 阶段描述（含与上一阶段的差值，logcat 一眼定位慢阶段）。
  String describe(CallDiagStage stage) {
    final at = _stamps[stage];
    if (at == null) return stage.label;
    if (stage.index == 0) return stage.label;
    final prior = CallDiagStage.values[stage.index - 1];
    final priorAt = _stamps[prior];
    if (priorAt == null) return stage.label;
    return '${stage.label} '
        '(+${at.difference(priorAt).inMilliseconds}ms since ${prior.label})';
  }

  /// 全链路摘要（通话结束输出；缺阶段如实留空）。
  String summary() {
    int? delta(CallDiagStage a, CallDiagStage b) {
      final from = _stamps[a];
      final to = _stamps[b];
      if (from == null || to == null) return null;
      return to.difference(from).inMilliseconds;
    }

    final inviteToUi =
        delta(CallDiagStage.inviteReceived, CallDiagStage.incomingUiShown);
    final uiToTap =
        delta(CallDiagStage.incomingUiShown, CallDiagStage.answerTapped);
    final tapToSent =
        delta(CallDiagStage.answerTapped, CallDiagStage.answerSent);
    final sentToIce =
        delta(CallDiagStage.answerSent, CallDiagStage.iceConnected);
    return '[chatflow/calldiag] summary invite→ui=${inviteToUi ?? '-'}ms '
        'ui→tap=${uiToTap ?? '-'}ms tap→sent=${tapToSent ?? '-'}ms '
        'sent→ice=${sentToIce ?? '-'}ms';
  }

  static void _defaultLog(String line) {
    // debugPrint 已在 mark 内输出；默认落 logcat 即可。
  }
}
