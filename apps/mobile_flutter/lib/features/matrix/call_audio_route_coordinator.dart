import 'package:flutter/foundation.dart';

import '../../core/performance_metrics.dart';
import 'call_controller.dart';

/// 音频路由唯一所有者（Task I）。
///
/// 修复的架构缺陷：此前有**两个**组件同时改输出路由——
/// `CallController` → `CallBackend.setSpeaker` → `Helper.setSpeakerphoneOn`，
/// 以及 Matrix SDK 的 `CallSession.addLocalStream()`（内部按
/// `type == CallType.kVideo` 私自 `enableSpeakerphone`）。两者互相覆盖，
/// 造成「选择免提后又被切回听筒」「视频接通瞬间路由抖动」等回音/路由问题。
///
/// 现在：
/// - [CallAudioRouteCoordinator] 是**唯一**有权决定 speaker/earpiece 策略的组件；
/// - MediaStream / RTCPeerConnection 仍归 Matrix SDK，它不再触碰输出路由；
/// - 区分「用户显式选择」与「自动默认」：一旦用户显式选择，自动策略
///   （接通回调、媒体流重建、ICE restart）一律不得覆盖；
/// - 外部设备（蓝牙/有线耳机）在场时不下发强制扬声器，尊重系统路由。
final class CallAudioRouteCoordinator {
  CallAudioRouteCoordinator({required this.apply, PerformanceMetrics? metrics})
      : _metrics = metrics ?? PerformanceMetrics.instance;

  /// 下游平台路由应用器（生产：`CallBackend.setSpeaker` → `Helper`）。
  final Future<void> Function(bool speaker) apply;
  final PerformanceMetrics _metrics;

  bool _speaker = false;
  bool? _appliedSpeaker;
  bool _userPreference = false;
  bool _externalRouteActive = false;
  CallMediaType _type = CallMediaType.audio;

  /// 当前期望的免提状态（UI 读取）。
  bool get speaker => _speaker;

  /// 已成功下发到平台的状态（未下发过为 null）。
  bool? get appliedSpeaker => _appliedSpeaker;

  /// 用户是否明确选择过路由（选择后自动策略不再生效）。
  bool get hasUserPreference => _userPreference;

  /// 外部音频设备（蓝牙/有线耳机）是否在场。
  bool get externalRouteActive => _externalRouteActive;

  /// 新通话开始：清空上一通的用户选择与应用状态。
  void reset() {
    _speaker = false;
    _appliedSpeaker = null;
    _userPreference = false;
  }

  /// 媒体建立前（`start`/`accept` 之前）先清除上一通遗留的免提状态。
  ///
  /// 语音保持听筒（`false`），视频先置 `false`、接通后再按产品语义开免提；
  /// 但如果用户在本通已显式选择，则以用户选择为准。
  Future<void> applyPreMediaRoute(CallMediaType type) async {
    _type = type;
    _speaker = _userPreference ? _speaker : false;
    await _apply(policy: _speaker);
    if (!_userPreference && type == CallMediaType.video) {
      // 视频免提留给 `preferForConnected`（接通后），此处只负责清场。
      _speaker = false;
    }
  }

  /// 接通后按产品语义应用默认：视频免提、语音听筒。
  Future<void> preferForConnected(CallMediaType type) {
    _type = type;
    return _applyPolicy();
  }

  /// 用户点击「免提」切换。
  Future<void> toggleSpeaker([CallMediaType? type]) {
    if (type != null) _type = type;
    return setSpeaker(!_speaker, markUserPreference: true);
  }

  /// 显式设置路由。
  ///
  /// [markUserPreference] 为 null 时延续当前「是否用户显式选择」的判定
  /// （自动策略用），true 表示这次是用户选择，此后自动策略不再覆盖。
  /// 应用失败时抛出并保留旧的应用状态（由调用方回滚 UI）。
  Future<void> setSpeaker(bool value,
      {CallMediaType? type,
      bool? markUserPreference,
      bool force = false}) async {
    if (type != null) _type = type;
    _speaker = value;
    _userPreference = markUserPreference ?? _userPreference;
    if (force) _appliedSpeaker = null;
    await _apply(policy: value);
  }

  /// 媒体流重建 / ICE restart 后重申当前策略（幂等，不改变用户选择）。
  Future<void> reapply() async {
    _appliedSpeaker = null; // 显式重申：允许重复下发同值
    await _apply(policy: _speaker);
  }

  /// 本地流被 SDK 重建（track 重挂 / ICE restart）：以协调器状态为准。
  void onLocalStreamRecreated() {
    // 策略不变：SDK 不再拥有路由，重建后不需要重新决策。
  }

  /// 外部音频设备连接状态变化（蓝牙 / 有线耳机 / USB）。
  ///
  /// 由**只读**的平台观察者（`PlatformAudioRouteObserver`）驱动；本协调器
  /// 仍然是唯一的 route authority。
  ///
  /// 语义：
  /// - 有外设时自动策略**绝不**下发 `speaker=true`（不抢当前外设）；视频通话
  ///   必须**显式**下发 `speaker=false` 把路由交还给系统；
  /// - 外设拔出后回到策略默认（视频=扬声器、语音=听筒）；
  /// - 用户显式选择（手动免提/听筒）优先于自动策略，插拔都不覆盖它。
  Future<void> setExternalRouteActive(bool active) async {
    if (_externalRouteActive == active) return;
    _externalRouteActive = active;
    // 外设变化会改变「自动默认」的结果，因此必须重新下发一次，
    // 即使算出来的布尔值与上一次相同（平台侧需要一次显式交还）。
    await _applyPolicy(force: true);
  }

  /// 用户未显式选择时才允许自动默认覆盖。
  ///
  /// [force] 用于「策略输入变了但结果值可能相同」的场景（外设插拔）：强制
  /// 重新下发，绕过「同值不重复调用」的缓存。
  Future<void> _applyPolicy({bool force = false}) async {
    if (force) _appliedSpeaker = null;
    await setSpeaker(
      _userPreference ? _speaker : _defaultSpeaker(_type),
      force: force,
    );
  }

  /// 自动默认：视频免提、语音听筒。
  ///
  /// 外部设备（蓝牙/有线耳机）在场时平台已优先选择外部设备，
  /// `speaker=false` 不会把声音抢回听筒，因此语音仍是 `false`；
  /// 关键是这里**绝不**在用户未选择时下发 `speaker=true`。
  bool _defaultSpeaker(CallMediaType type) =>
      type == CallMediaType.video && !_externalRouteActive;

  Future<void> _apply({required bool policy}) async {
    if (_appliedSpeaker == policy) return;
    await apply(policy);
    _appliedSpeaker = policy;
    if (_metrics.enabled) {
      debugPrint('[chatflow/call] platform=${defaultTargetPlatform.name} '
          'requestedRoute=${policy ? 'speaker' : 'earpiece-or-external'} '
          'appliedRoute=${policy ? 'speaker' : 'non-speaker'} '
          'externalDevicePresent=$_externalRouteActive '
          'userPreference=$_userPreference '
          'reason=${_userPreference ? 'user-override' : 'auto-policy'}');
    }
  }
}
