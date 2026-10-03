import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../core/notification/notification_preferences.dart';

/// Device-private association/policy adapter. No decrypted content crosses it.
/// Room observations arrive from the existing preference reconciliation pass;
/// unchanged rooms do no hashing, disk work or platform call.
final class NativeMessagePolicy {
  NativeMessagePolicy({bool? enabled})
      : enabled = enabled ??
            (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);
  static final shared = NativeMessagePolicy();
  static const channel = MethodChannel('chatflow/native_messages');
  final bool enabled;
  final Map<String, bool> _rooms = {};
  final Map<String, String> _roomByKey = {};
  String? _account, _scope;
  int _revision = 0, _epoch = 0;
  bool _ready = false;
  NotificationPreferenceValues? _desired;
  Future<void> _writes = Future.value();
  Future<void> Function()? onRegistrationChanged;
  Future<void> Function()? onTapAvailable;
  void _notifyRegistration() {
    final callback = onRegistrationChanged;
    if (callback != null) unawaited(callback().catchError((Object _) {}));
  }

  bool hasRoomObservation(String account, String roomId, bool muted) =>
      _account == account &&
      (_rooms[roomId] == muted ||
          (!_rooms.containsKey(roomId) && _rooms.length >= 2048));
  Map<String, Object>? get registration => !_ready || _scope == null
      ? null
      : {
          'chatflow_push_v': 1,
          'chatflow_push_scope': _scope!,
          'chatflow_push_revision': _revision,
        };
  String key(String value) =>
      sha256.convert(utf8.encode('$_scope\u0000$value')).toString();

  Future<void> _serialize(Future<void> Function() operation) {
    final task = _writes.then((_) => operation());
    _writes = task.catchError((Object _) {});
    return task;
  }

  Future<void> observeRoom(String account, String roomId, bool muted) async {
    if (!enabled) return;
    if (_account != account) {
      if (_scope != null) {
        return; // Account transition belongs to authenticated prepare/revoke.
      }
      _account = account;
      _rooms.clear();
      _roomByKey.clear();
    }
    if (_rooms[roomId] == muted ||
        (!_rooms.containsKey(roomId) && _rooms.length >= 2048)) {
      return;
    }
    _rooms[roomId] = muted;
    if (!_ready || _scope == null) return;
    final epoch = _epoch;
    await _serialize(() async {
      if (epoch != _epoch || !_ready) return;
      final roomKey = key(roomId);
      try {
        final ok = await channel.invokeMethod<bool>('room', {
          'scope': _scope,
          'revision': ++_revision,
          'room_key': roomKey,
          'muted': muted,
        });
        if (epoch != _epoch) return;
        if (ok != true) {
          _ready = false;
          await channel.invokeMethod<void>('invalidate', {'scope': _scope});
          throw StateError('无法保存通知设置');
        }
        _roomByKey[roomKey] = roomId;
        _notifyRegistration();
      } catch (_) {
        if (epoch == _epoch) {
          _ready = false;
          try {
            await channel.invokeMethod<void>('invalidate', {'scope': _scope});
          } catch (_) {
            // Native room persistence already invalidates on failure. Retain
            // the original error and pending desired snapshot for retry.
          }
        }
        rethrow;
      }
    });
  }

  Future<void> prepare(
      String account, NotificationPreferenceValues values) async {
    if (!enabled) return;
    if (_account != account) {
      _rooms.clear();
      _roomByKey.clear();
      _account = account;
    }
    final epoch = ++_epoch;
    _ready = false;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'tapAvailable') await onTapAvailable?.call();
    });
    final state = await channel.invokeMapMethod<String, Object?>('bind', {
      'account': sha256.convert(utf8.encode(account)).toString(),
    });
    if (epoch != _epoch) return;
    final scope = state?['scope'];
    if (scope is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(scope)) {
      throw StateError('无法初始化通知');
    }
    _scope = scope;
    _revision = (state?['revision'] as num?)?.toInt() ?? 0;
    await updatePreferences(values);
  }

  Future<void> updatePreferences(NotificationPreferenceValues values) async {
    _desired = values;
    if (!enabled || _scope == null) return;
    final epoch = _epoch;
    final requestedRevision = ++_revision;
    _ready = false;
    // Queue invalidation before any slow preference storage/network operation.
    await channel.invokeMethod<void>(
        'invalidate', {'scope': _scope, 'revision': requestedRevision});
    if (epoch != _epoch) return;
    await _serialize(() async {
      if (epoch != _epoch || requestedRevision != _revision) return;
      final rooms = <String, bool>{};
      _roomByKey.clear();
      for (final entry in _rooms.entries) {
        final roomKey = key(entry.key);
        rooms[roomKey] = entry.value;
        _roomByKey[roomKey] = entry.key;
      }
      final ok = await channel.invokeMethod<bool>('install', {
        'scope': _scope,
        'revision': requestedRevision,
        'enabled': values.messageNotificationEnabled,
        'sound': values.soundEnabled,
        'vibration': values.vibrationEnabled,
        'dnd': values.dndEnabled,
        'start': values.dndStartMinutes,
        'end': values.dndEndMinutes,
        'rooms': rooms,
      });
      if (epoch != _epoch || requestedRevision != _revision) return;
      if (ok != true) throw StateError('无法保存通知设置');
      _ready = true;
      _notifyRegistration();
    });
  }

  Future<void> retryPending() async {
    if (enabled && !_ready && _scope != null && _desired != null) {
      await updatePreferences(_desired!);
    }
  }

  Future<bool?> claim(String roomId, String eventId) async {
    if (!enabled || _scope == null) return null;
    if (!_ready) return false;
    final epoch = _epoch;
    final accepted = await channel.invokeMethod<bool>('claim', {
      'scope': _scope,
      'room_key': key(roomId),
      'event_key': key(eventId),
    });
    return epoch == _epoch && _ready && accepted == true;
  }

  Future<bool?> handleBackground(String roomId, String eventId,
      {required bool show,
      required bool silent,
      required String title,
      required String body}) async {
    if (!enabled || _scope == null) return null;
    if (!_ready) return false;
    return channel.invokeMethod<bool>('resolve', {
      'scope': _scope,
      'room_key': key(roomId),
      'event_key': key(eventId),
      'show': show,
      'silent': silent,
      'title': title,
      'body': body,
    });
  }

  Future<void> complete(String eventId) async {
    if (_scope == null || !_ready) return;
    await channel.invokeMethod<void>(
        'complete', {'scope': _scope, 'event_key': key(eventId)});
  }

  Future<bool> beginForeground(String eventId) async {
    if (!_ready || _scope == null) return false;
    final epoch = _epoch;
    final ok = await channel.invokeMethod<bool>(
        'beginForeground', {'scope': _scope, 'event_key': key(eventId)});
    return epoch == _epoch && _ready && ok == true;
  }

  Future<void> finishForeground(String eventId, {required bool handled}) async {
    if (!_ready || _scope == null) return;
    await channel.invokeMethod<void>('finishForeground',
        {'scope': _scope, 'event_key': key(eventId), 'handled': handled});
  }

  Future<void> suspend() async {
    _ready = false;
    if (_scope != null) {
      await channel.invokeMethod<void>('invalidate', {'scope': _scope});
    }
  }

  Future<void> cancelRoom(String roomId) async {
    if (_scope == null) return;
    await channel.invokeMethod<void>(
        'cancelRoom', {'scope': _scope, 'room_key': key(roomId)});
  }

  Future<void> routePendingTap(Future<void> Function(String) open) async {
    if (!_ready) return;
    final epoch = _epoch;
    final tap = await channel
        .invokeMapMethod<String, Object?>('takeTap', {'scope': _scope});
    if (epoch != _epoch || !_ready || tap?['scope'] != _scope) return;
    final roomId = _roomByKey[tap?['room_key']];
    if (roomId == null) {
      return; // Explicit tap has already opened home; never guess a room.
    }
    if (await channel.invokeMethod<bool>('validate', {'scope': _scope}) !=
            true ||
        epoch != _epoch ||
        !_ready) {
      return;
    }
    await open(roomId);
  }

  Future<void> revoke() async {
    ++_epoch;
    _ready = false;
    _desired = null;
    _scope = null;
    _account = null;
    _rooms.clear();
    _roomByKey.clear();
    onRegistrationChanged = null;
    onTapAvailable = null;
    if (enabled) await channel.invokeMethod<void>('revoke');
  }
}
