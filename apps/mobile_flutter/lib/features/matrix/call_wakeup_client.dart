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

  Future<void> answerAndConnect(
      {required String roomId,
      required String callId,
      required bool Function() isCurrent,
      required Future<void> Function() connect}) async {
    final claim = await answer(roomId: roomId, callId: callId);
    if (!isCurrent()) return;
    if (claim != CallAnswerDisposition.accepted &&
        claim != CallAnswerDisposition.noWakeRecord) {
      throw StateError('Call answer could not be verified');
    }
    await connect();
  }

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
