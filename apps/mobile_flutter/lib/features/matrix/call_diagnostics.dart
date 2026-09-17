import 'package:flutter/foundation.dart';

/// 通话关键路径阶段（诊断埋点，脱敏——不含任何通话内容）。
///
/// 被叫链路（[CallDiagStage.incomingUiShown] … [CallDiagStage.firstRemoteTrack]）
/// 与主叫链路（[CallDiagStage.outgoingStart] … [CallDiagStage.outgoingInviteSent]）
/// 时间线相互独立；[CallDiagStage.iceConnected] 为两条链路共用的汇合点。
enum CallDiagStage {
  // —— 被叫（incoming）——
  inviteReceived('invite_received'),
  incomingUiShown('incoming_ui_shown'),
  answerTapped('answer_tapped'),
  permissionGranted('permission_granted'),
  answerStarted('answer_started'),
  mediaAcquireStarted('media_acquire_started'),
  mediaAcquireReady('media_acquire_ready'),
  answerSent('answer_sent'),
  firstRemoteTrack('first_remote_track'),

  // —— 主叫（outgoing）——
  outgoingStart('outgoing_start'),
  securityValidated('security_validated'),
  outgoingPermissionGranted('outgoing_permission_granted'),
  outgoingMediaAcquireStarted('outgoing_media_acquire_started'),
  outgoingMediaAcquireReady('outgoing_media_acquire_ready'),
  outgoingInviteSent('outgoing_invite_sent'),
  remoteAnswerReceived('remote_answer_received'),

  // —— 汇合 / 终态 ——
  iceConnected('ice_connected'),
  ended('ended');

  const CallDiagStage(this.label);

  final String label;
}

/// 通话关键路径耗时诊断：invite→来电UI→点击接听→接听信令→ICE 接通。
///
/// 由组合根创建并注入 backend 与 controller（同一实例，同一时间线）；
/// 每次新通话 reset。仅记录时间戳与差值 + debugPrint
/// `[chatflow/calldiag]`，供真机 logcat 定位慢阶段。
///
/// 真机判断（不硬编码质量阈值，只用于定位）：
/// - `tap→sent` 高 → 本地 media / 应用架构延迟；
/// - `sent→ice` 高 → ICE / TURN / 网络协商；
/// - 主叫 `tap→invite` 高 → 「拨出去多久对方才响」；
/// - 主叫 `answer→ice` 高 → 「对方接听以后多久才通」。
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

  /// 阶段描述（含与「上一个已记录阶段」的差值，logcat 一眼定位慢阶段）。
  String describe(CallDiagStage stage) {
    final at = _stamps[stage];
    if (at == null) return stage.label;
    DateTime? priorAt;
    String? priorLabel;
    for (var index = stage.index - 1; index >= 0; index--) {
      final candidate = CallDiagStage.values[index];
      final stamp = _stamps[candidate];
      if (stamp != null) {
        priorAt = stamp;
        priorLabel = candidate.label;
        break;
      }
    }
    if (priorAt == null) return stage.label;
    return '${stage.label} '
        '(+${at.difference(priorAt).inMilliseconds}ms since $priorLabel)';
  }

  /// 两阶段之间的毫秒差（任一缺失为 null）。
  int? deltaMs(CallDiagStage from, CallDiagStage to) {
    final start = _stamps[from];
    final end = _stamps[to];
    if (start == null || end == null) return null;
    return end.difference(start).inMilliseconds;
  }

  static String _ms(int? value) => value == null ? '-' : '${value}ms';

  /// 全链路摘要（通话结束输出；缺阶段如实留空）。
  String summary() {
    final inviteToUi =
        deltaMs(CallDiagStage.inviteReceived, CallDiagStage.incomingUiShown);
    final uiToTap =
        deltaMs(CallDiagStage.incomingUiShown, CallDiagStage.answerTapped);
    final tapToSent =
        deltaMs(CallDiagStage.answerTapped, CallDiagStage.answerSent);
    final sentToIce =
        deltaMs(CallDiagStage.answerSent, CallDiagStage.iceConnected);
    // 被叫细分：权限 / getUserMedia / createAnswer+Matrix send / ICE。
    final tapToPermission =
        deltaMs(CallDiagStage.answerTapped, CallDiagStage.permissionGranted);
    final permissionToAnswer =
        deltaMs(CallDiagStage.permissionGranted, CallDiagStage.answerStarted);
    final answerToSent =
        deltaMs(CallDiagStage.answerStarted, CallDiagStage.answerSent);
    // 主叫细分：拨出→校验→权限→media→invite→对方接听→ICE。
    final outgoingStartToValidated =
        deltaMs(CallDiagStage.outgoingStart, CallDiagStage.securityValidated);
    final validatedToMedia = deltaMs(CallDiagStage.securityValidated,
        CallDiagStage.outgoingMediaAcquireStarted);
    final mediaToInvite = deltaMs(CallDiagStage.outgoingMediaAcquireStarted,
        CallDiagStage.outgoingInviteSent);
    final inviteToAnswer = deltaMs(
        CallDiagStage.outgoingInviteSent, CallDiagStage.remoteAnswerReceived);
    final answerToIce =
        deltaMs(CallDiagStage.remoteAnswerReceived, CallDiagStage.iceConnected);
    return '[chatflow/calldiag] summary '
        'invite→ui=${_ms(inviteToUi)} '
        'ui→tap=${_ms(uiToTap)} '
        'tap→sent=${_ms(tapToSent)} '
        'sent→ice=${_ms(sentToIce)} '
        '| incoming: '
        'tap→perm=${_ms(tapToPermission)} '
        'perm→answer=${_ms(permissionToAnswer)} '
        'answer→sent=${_ms(answerToSent)} '
        '| outgoing: '
        'start→verified=${_ms(outgoingStartToValidated)} '
        'verified→media=${_ms(validatedToMedia)} '
        'media→invite=${_ms(mediaToInvite)} '
        'invite→answer=${_ms(inviteToAnswer)} '
        'answer→ice=${_ms(answerToIce)}';
  }

  static void _defaultLog(String line) {
    // debugPrint 已在 mark 内输出；默认落 logcat 即可。
  }
}
