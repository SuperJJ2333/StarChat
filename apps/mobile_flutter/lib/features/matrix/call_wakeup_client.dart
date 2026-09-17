import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

enum CallAnswerDisposition { accepted, noWakeRecord, alreadyEnded, unavailable }

/// Routes opaque call metadata only; Matrix continues to carry encrypted SDP.
final class CallWakeupClient {
  CallWakeupClient({
    required Uri baseUrl,
    required String? Function() accessToken,
    http.Client? httpClient,
  })  : baseUrl = baseUrl.replace(
            path: '${baseUrl.path.replaceFirst(RegExp(r'/+$'), '')}/'),
        _sessionToken = accessToken(),
        _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null;

  final Uri baseUrl;
  final String? _sessionToken;
  final String registrationId = List.generate(16,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join();
  static Future<void> _routeWork = Future.value();
  final http.Client _http;
  final bool _ownsHttp;
  Future<void> _registration = Future.value();
  String? _registered;
  DateTime? _registeredAt;
  final _invites = <String, Future<bool>>{};
  bool _stopped = false;

  Future<int> _status(String method, String path,
      [Map<String, Object>? body]) async {
    final token = _sessionToken;
    if (token == null || token.isEmpty || baseUrl.scheme != 'https') return 0;
    try {
      final request = http.Request(method, baseUrl.resolve(path));
      request.followRedirects = false;
      request.headers.addAll({
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json'
      });
      if (method == 'DELETE') {
        request.headers['X-Registration-ID'] = registrationId;
      }
      if (body != null) request.body = jsonEncode(body);
      final response =
          await _http.send(request).timeout(const Duration(seconds: 8));
      // Do not retain or log provider responses, tokens, or call identifiers.
      await response.stream.drain<void>().timeout(const Duration(seconds: 3));
      return response.statusCode;
    } catch (_) {
      return 0;
    }
  }

  Future<bool> _send(String method, String path,
      [Map<String, Object>? body]) async {
    final status = await _status(method, path, body);
    return status >= 200 && status < 300;
  }

  Future<bool> register(Map<String, Object?> tokens) async {
    if (_stopped) return false;
    final voip = tokens['voipToken'];
    final apns = tokens['apnsToken'];
    bool valid(Object? value) =>
        value is String &&
        RegExp(r'^[0-9a-fA-F]{64,200}$').hasMatch(value) &&
        value.length.isEven;
    if (!valid(voip) || (apns != null && !valid(apns))) return false;
    final payload = <String, Object>{
      'registration_id': registrationId,
      'voip_token': voip!,
      if (apns != null) 'apns_token': apns
    };
    final fingerprint = jsonEncode(payload);
    var ok = false;
    _registration = _routeWork.then((_) async {
      if (_stopped) return;
      if (_registered == fingerprint &&
          _registeredAt != null &&
          DateTime.now().difference(_registeredAt!) <
              const Duration(hours: 12)) {
        ok = true;
        return;
      }
      ok = await _send('PUT', 'v1/devices/ios', payload);
      if (ok) {
        _registered = fingerprint;
        _registeredAt = DateTime.now();
      }
    });
    _routeWork = _registration.catchError((_) {});
    await _registration;
    return ok;
  }

  Future<bool> invite(
      {required String roomId,
      required String callId,
      required String recipient,
      required bool video}) {
    if (_stopped) return Future.value(false);
    final key = '$roomId\u0000$callId';
    return _invites.putIfAbsent(key, () {
      final pending = _send('POST', 'v1/calls', {
        'room_id': roomId,
        'call_id': callId,
        'recipient': recipient,
        'video': video
      });
      unawaited(pending.whenComplete(() => _invites.remove(key)));
      return pending;
    });
  }

  Future<CallAnswerDisposition> answer(
      {required String roomId, required String callId}) async {
    final status = await _status(
        'POST', 'v1/calls/answer', {'room_id': roomId, 'call_id': callId});
    if (status >= 200 && status < 300) return CallAnswerDisposition.accepted;
    if (status == 404) return CallAnswerDisposition.noWakeRecord;
    if (status == 409 || status == 403) {
      return CallAnswerDisposition.alreadyEnded;
    }
    return CallAnswerDisposition.unavailable;
  }

  /// 被叫接听（Task G）——wakeup HTTP **不再**是 WebRTC media setup 的同步前置。
  ///
  /// 架构原则：Matrix active [CallSession] 才是媒体通话事实源；本 API 只负责
  /// PushKit/push 唤醒与跨进程 tombstone 协调。
  ///
  /// 流程：
  /// 1. 先确认 [isCurrent]（当前 active Matrix CallSession 与 native action
  ///    的 roomId/callId/generation 完全一致）——
  /// 2. **立即**开始 `connect()`（本地 media + createAnswer + Matrix answer）；
  /// 3. 与此同时 best-effort 并行上报 `/calls/answer`。
  ///
  /// HTTP 返回策略：
  /// - `accepted` / `noWakeRecord`：正常；
  /// - `unavailable`（服务不可用 / 网络超时）：**不阻断**已经验证的
  ///   Matrix 会话接听，只记录诊断；
  /// - `alreadyEnded`（显式 tombstone）：仅当返回时仍是同一个 call 时
  ///   才结束该通话，绝不影响后来新的通话。
  Future<void> answerAndConnect({
    required String roomId,
    required String callId,
    required bool Function() isCurrent,
    required Future<void> Function() connect,
  }) async {
    if (!isCurrent()) return;
    // Best-effort side channel: never awaited on the media critical path.
    unawaited(_reportAnswerSideChannel(
      roomId: roomId,
      callId: callId,
    ));
    // Media answer starts immediately, without waiting for any HTTP round trip.
    await connect();
  }

  Future<void> _reportAnswerSideChannel({
    required String roomId,
    required String callId,
  }) async {
    CallAnswerDisposition claim;
    try {
      claim = await answer(roomId: roomId, callId: callId);
    } catch (_) {
      return; // A failed side channel must never disturb the live call.
    }
    if (claim != CallAnswerDisposition.alreadyEnded) return;
    // Explicit tombstone for exactly this call: end it, but only while the
    // same Matrix call session (roomId + callId + generation) is still current.
    try {
      await onExplicitlyEnded?.call(roomId: roomId, callId: callId);
    } catch (_) {
      // Ending is best effort; a failure must not surface into the answer path.
    }
  }

  /// 显式 tombstone（`alreadyEnded`）时结束**完全匹配**的当前通话。
  ///
  /// 由组合根注入（生产：结束匹配的 active Matrix CallSession）。
  Future<void> Function({required String roomId, required String callId})?
      onExplicitlyEnded;

  Future<bool> end({required String roomId, required String callId}) async {
    await _invites['$roomId\u0000$callId'];
    return _send(
        'POST', 'v1/calls/end', {'room_id': roomId, 'call_id': callId});
  }

  Future<void> unregister() async {
    _stopped = true;
    final cleanup = _routeWork.then((_) async {
      await _send('DELETE', 'v1/devices/ios');
    });
    _routeWork = cleanup.catchError((_) {});
    await cleanup;
    _registered = null;
  }

  void close() {
    _stopped = true;
    if (_ownsHttp) _http.close();
  }
}
