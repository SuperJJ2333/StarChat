import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/notification/notification_diagnostics.dart';
import '../../core/notification/notification_preferences.dart';

abstract interface class IosPushPolicyStore {
  Future<String?> read();
  Future<void> write(String value);
}

final class IosPushPolicy {
  IosPushPolicy({this.store, this.timeZoneIdentifier});
  final IosPushPolicyStore? store;
  final Future<String?> Function()? timeZoneIdentifier;
  static const _channel = MethodChannel('chatflow/apns');
  static Future<void> _storageTail = Future.value();
  Future<Map<String, Object>>? _inFlight;
  NotificationPreferenceValues? _desired;

  Future<Map<String, Object>> prepare(
      NotificationPreferenceValues values) async {
    _desired = values;
    if (_inFlight != null) return _inFlight!;
    final flight = _converge();
    _inFlight = flight;
    try {
      return await flight;
    } finally {
      if (identical(_inFlight, flight)) _inFlight = null;
    }
  }

  Future<Map<String, Object>> _converge() async {
    while (true) {
      final values = _desired!;
      String? zone;
      try {
        zone = await (timeZoneIdentifier?.call() ??
                _channel.invokeMethod<String>('getTimeZoneIdentifier'))
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        // Do not fall back to a timezone abbreviation/offset or device clock.
      }
      if (zone == null ||
          zone.length > 128 ||
          !RegExp(r'^[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)*$').hasMatch(zone) ||
          zone == 'localtime' ||
          zone == 'posixrules' ||
          zone.startsWith('posix/') ||
          zone.startsWith('right/') ||
          values.dndStartMinutes < 0 ||
          values.dndStartMinutes >= 1440 ||
          values.dndEndMinutes < 0 ||
          values.dndEndMinutes >= 1440) {
        zone = '';
        NotificationDiagnostics.shared.record(NotificationDiagStage.push,
            'iOS notification policy unavailable; silent pending retry');
      }
      final desired = <String, Object>{
        'v': 1,
        'timezone': zone,
        'dnd_enabled': values.dndEnabled,
        'dnd_start_minutes': values.dndStartMinutes,
        'dnd_end_minutes': values.dndEndMinutes,
      };
      // Serialize the persistent revision across replacement AppHome owners.
      final write = _storageTail.then((_) => _persist(desired));
      _storageTail =
          write.then<void>((_) {}, onError: (Object _, StackTrace __) {});
      final result = await write;
      if (_desired == values) return result;
    }
  }

  Future<Map<String, Object>> _persist(Map<String, Object> desired) async {
    final storage = store ?? const _SharedPreferencesPolicyStore();
    final encoded = await storage.read();
    var revision = 0;
    if (encoded != null) {
      final previous = jsonDecode(encoded);
      if (previous is! Map ||
          previous['revision'] is! int ||
          (previous['revision'] as int) < 1 ||
          (previous['revision'] as int) > 9007199254740991) {
        throw StateError('invalid persisted notification policy');
      }
      revision = previous['revision'] as int;
      if (previous.length == desired.length + 1 &&
          desired.entries
              .every((entry) => previous[entry.key] == entry.value)) {
        return Map.unmodifiable({...desired, 'revision': revision});
      }
    }
    if (revision == 9007199254740991) {
      throw StateError('notification policy revision exhausted');
    }
    final result = {...desired, 'revision': revision + 1};
    await storage.write(jsonEncode(result));
    return Map.unmodifiable(result);
  }
}

final class _SharedPreferencesPolicyStore implements IosPushPolicyStore {
  const _SharedPreferencesPolicyStore();
  static const _key = 'notification.ios_push_policy.v1';
  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(_key);
  @override
  Future<void> write(String value) async {
    if (!await (await SharedPreferences.getInstance()).setString(_key, value)) {
      throw StateError('notification policy persistence unavailable');
    }
  }
}
