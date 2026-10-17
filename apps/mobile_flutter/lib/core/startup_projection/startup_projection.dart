import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../performance_metrics.dart';

enum StartupProjectionPhase {
  cacheAdmissionHit,
  cacheAdmissionMiss,
  fullPreflightBegin,
  identityPreflightComplete,
  localProjectionReady,
  fullSdkReady,
  firstProjectionContentFrame,
  projectionCommitSuccess,
  projectionCommitFailure,
}

enum StartupProjectionReason {
  markerAbsent,
  admissionRejected,
  payloadRejected,
  recheckRejected,
  identityUnavailable,
  captureFailed,
  commitRejected,
}

void markStartupProjection(StartupProjectionPhase phase, Stopwatch? clock,
    {int? bytes, int? rooms, int? events, StartupProjectionReason? reason}) {
  if (!PerformanceMetrics.instance.enabled || clock == null) return;
  debugPrint(
      '[chatflow/startup] phase=${phase.name} origin=main_entry elapsed_ms=${clock.elapsedMilliseconds}'
      '${reason == null ? '' : ' reason=${reason.name}'}${bytes == null ? '' : ' bytes=$bytes'}${rooms == null ? '' : ' rooms=$rooms'}'
      '${events == null ? '' : ' events=$events'}');
}

// Include the 43-byte installation marker in the aggregate 4 MiB quota.
const startupProjectionMaxEnvelope = (4 * 1024 * 1024 - 43) ~/ 2;
const startupProjectionMaxRooms = 40;
const startupProjectionMaxEvents = 40;

String projectionString(Object? value, int limit) {
  if (value is! String || utf8.encode(value).length > limit) {
    throw const FormatException('Invalid projection string');
  }
  return value;
}

Uint8List projectionKey(String value) {
  if (value.length > 128 ||
      !RegExp(r'^[A-Za-z0-9_-]+={0,2}$').hasMatch(value)) {
    throw const FormatException('Invalid projection key');
  }
  final bytes = base64Url.decode(base64Url.normalize(value));
  if (bytes.length != 32) throw const FormatException('Invalid projection key');
  return bytes;
}

String projectionEpoch(Object? value) {
  final text = projectionString(value, 43);
  if (text.length != 43 ||
      !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(text) ||
      base64Url.encode(projectionKey(text)).replaceAll('=', '') != text) {
    throw const FormatException('Invalid projection epoch');
  }
  return text;
}

/// This capability contains only checked local identity, never login authority.
final class StartupProjectionAdmission {
  StartupProjectionAdmission(
      {required this.scope,
      required this.homeserver,
      required this.userId,
      required this.deviceId,
      required this.fingerprint,
      required this.databaseGeneration,
      required this.installationId,
      required this.epoch,
      required this.databaseKey,
      required this.registrationKey,
      this.digest,
      this.length}) {
    for (final scalar in [
      scope,
      homeserver,
      userId,
      deviceId,
      fingerprint,
      databaseGeneration
    ]) {
      projectionString(scalar, 2048);
    }
    projectionEpoch(installationId);
    projectionEpoch(epoch);
    projectionKey(databaseKey);
  }
  final String scope,
      homeserver,
      userId,
      deviceId,
      fingerprint,
      databaseGeneration,
      installationId,
      epoch,
      databaseKey,
      registrationKey;
  final String? digest;
  final int? length;
  List<int> get context => utf8.encode(jsonEncode([
        'ChatFlow/startup-projection',
        1,
        scope,
        homeserver,
        userId,
        deviceId,
        fingerprint,
        databaseGeneration,
        installationId,
        epoch,
      ]));
  bool sameIdentity(StartupProjectionAdmission other) =>
      jsonEncode(context) == jsonEncode(other.context) &&
      databaseKey == other.databaseKey;
}

/// Typed display data only: no attachment secrets or financial authority.
final class StartupProjectionEvent {
  const StartupProjectionEvent(
      {required this.id,
      required this.sender,
      required this.body,
      required this.timestamp,
      required this.senderName,
      this.kind = 'm.text',
      this.media = const {}});
  final String id, sender, body, senderName, kind;
  final int timestamp;
  final Map<String, Object> media;
  static const kinds = {
    'm.text',
    'm.notice',
    'm.emote',
    'm.image',
    'm.video',
    'm.audio',
    'm.file',
    'm.sticker',
    'com.changliao.red_packet',
    'com.changliao.transfer',
    'com.changliao.call',
    'com.changliao.friend_accepted',
    'com.changliao.red_packet.claimed'
  };
  Map<String, dynamic> get displayContent => {
        'msgtype': kind,
        'body': body,
        if (media.isNotEmpty)
          'info': {
            if (media['mime'] != null) 'mimetype': media['mime'],
            if (media['width'] != null) 'w': media['width'],
            if (media['height'] != null) 'h': media['height'],
            if (media['size'] != null) 'size': media['size'],
            if (media['duration'] != null) 'duration': media['duration'],
          }
      };
  Map<String, Object> toJson() => {
        'id': id,
        'sender': sender,
        'body': body,
        'timestamp': timestamp,
        'senderName': senderName,
        'kind': kind,
        'media': media
      };
  factory StartupProjectionEvent.fromJson(Object? value) {
    final map = _record(
        value,
        {'id', 'sender', 'body', 'timestamp', 'senderName', 'kind', 'media'},
        65536);
    if (map['timestamp'] is! int || !kinds.contains(map['kind'])) {
      throw const FormatException('Invalid event kind or time');
    }
    final raw = map['media'];
    if (raw is! Map ||
        raw.length > 5 ||
        !raw.keys
            .every({'mime', 'width', 'height', 'size', 'duration'}.contains)) {
      throw const FormatException('Invalid media display metadata');
    }
    final media = <String, Object>{};
    for (final entry in raw.entries) {
      if (entry.key == 'mime') {
        media['mime'] = projectionString(entry.value, 256);
      } else {
        if (entry.value is! int ||
            entry.value < 0 ||
            entry.value > 9007199254740991) {
          throw const FormatException('Invalid media dimension');
        }
        media[entry.key as String] = entry.value as int;
      }
    }
    return StartupProjectionEvent(
        id: projectionString(map['id'], 2048),
        sender: projectionString(map['sender'], 2048),
        body: projectionString(map['body'], 60000),
        timestamp: map['timestamp'] as int,
        senderName: projectionString(map['senderName'], 4096),
        kind: map['kind'] as String,
        media: Map.unmodifiable(media));
  }
}

final class StartupProjectionMember {
  const StartupProjectionMember(
      {required this.id, required this.name, this.avatar});
  final String id, name;
  final String? avatar;
  Map<String, Object?> toJson() => {'id': id, 'name': name, 'avatar': avatar};
  factory StartupProjectionMember.fromJson(Object? value) {
    final record = _record(value, {'id', 'name', 'avatar'}, 1536);
    final avatar = record['avatar'] == null
        ? null
        : projectionString(record['avatar'], 1024);
    if (avatar != null &&
        !['mxc', 'https', 'http'].contains(Uri.tryParse(avatar)?.scheme)) {
      throw const FormatException('Invalid avatar URI');
    }
    return StartupProjectionMember(
        id: projectionString(record['id'], 256),
        name: projectionString(record['name'], 256),
        avatar: avatar);
  }
}

final class StartupProjectionRoom {
  StartupProjectionRoom(
      {required this.id,
      required this.name,
      required this.direct,
      required this.peer,
      required this.unread,
      required this.pinned,
      required this.muted,
      required this.canSend,
      required this.activity,
      required this.events,
      this.coverage = 'partial',
      this.avatar,
      this.members = const [],
      this.preview,
      this.encrypted = false,
      this.membership = 'join'}) {
    if (events.length > startupProjectionMaxEvents || members.length > 9) {
      throw const FormatException('Too many events');
    }
  }
  final String id, name, coverage, membership;
  final bool encrypted;
  final String? peer, avatar;
  final List<StartupProjectionMember> members;
  final bool direct, pinned, muted, canSend;
  final int unread, activity;
  final List<StartupProjectionEvent> events;
  final StartupProjectionEvent? preview;
  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'direct': direct,
        'peer': peer,
        'unread': unread,
        'pinned': pinned,
        'muted': muted,
        'canSend': canSend,
        'encrypted': encrypted,
        'membership': membership,
        'activity': activity,
        'coverage': coverage,
        'avatar': avatar,
        'members': members.map((member) => member.toJson()).toList(),
        'preview': preview?.toJson(),
        'events': events.map((e) => e.toJson()).toList()
      };
  factory StartupProjectionRoom.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid room');
    }
    final metadata = Map<String, dynamic>.of(value)..remove('events');
    _record(
        metadata,
        {
          'id',
          'name',
          'direct',
          'peer',
          'unread',
          'pinned',
          'muted',
          'canSend',
          'encrypted',
          'membership',
          'activity',
          'coverage',
          'avatar',
          if (metadata.containsKey('members')) 'members',
          'preview'
        },
        16384);
    if (value.keys.length != metadata.length + 1 ||
        (value.containsKey('members') &&
            (value['members'] is! List ||
                (value['members'] as List).length > 9)) ||
        value['events'] is! List ||
        (value['events'] as List).length > 40 ||
        !['partial', 'empty', 'complete_cached'].contains(value['coverage'])) {
      throw const FormatException('Invalid room head');
    }
    for (final key in ['direct', 'pinned', 'muted', 'canSend', 'encrypted']) {
      if (value[key] is! bool) throw const FormatException('Invalid room flag');
    }
    if (!['join', 'invite', 'leave', 'ban', 'knock']
            .contains(value['membership']) ||
        value['unread'] is! int ||
        (value['unread'] as int) < 0 ||
        value['activity'] is! int) {
      throw const FormatException('Invalid room count');
    }
    return StartupProjectionRoom(
        id: projectionString(value['id'], 2048),
        name: projectionString(value['name'], 4096),
        direct: value['direct'] as bool,
        peer: value['peer'] == null
            ? null
            : projectionString(value['peer'], 2048),
        avatar: value['avatar'] == null
            ? null
            : projectionString(value['avatar'], 2048),
        members: List.unmodifiable(((value['members'] ?? []) as List)
            .map(StartupProjectionMember.fromJson)),
        unread: value['unread'] as int,
        pinned: value['pinned'] as bool,
        muted: value['muted'] as bool,
        encrypted: value['encrypted'] as bool,
        membership: value['membership'] as String,
        canSend: value['canSend'] as bool,
        activity: value['activity'] as int,
        coverage: value['coverage'] as String,
        preview: value['preview'] == null
            ? null
            : StartupProjectionEvent.fromJson(value['preview']),
        events: List.unmodifiable(
            (value['events'] as List).map(StartupProjectionEvent.fromJson)));
  }
}

Map<String, dynamic> _record(Object? value, Set<String> keys, int limit) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains) ||
      utf8.encode(jsonEncode(value)).length > limit) {
    throw const FormatException('Invalid projection record');
  }
  return value;
}

final class StartupProjection {
  StartupProjection(List<StartupProjectionRoom> rooms)
      : rooms = List.unmodifiable(rooms) {
    if (rooms.length > 40 ||
        rooms.map((r) => r.id).toSet().length != rooms.length) {
      throw const FormatException('Invalid projection rooms');
    }
  }
  final List<StartupProjectionRoom> rooms;
  List<int> encode() => utf8.encode(jsonEncode({
        'version': 1,
        'kind': 'valid',
        'rooms': rooms.map((r) => r.toJson()).toList()
      }));
  factory StartupProjection.decode(List<int> bytes) {
    if (bytes.length > startupProjectionMaxEnvelope - 38) {
      throw const FormatException('Projection too large');
    }
    final map = _record(jsonDecode(utf8.decode(bytes)),
        {'version', 'kind', 'rooms'}, startupProjectionMaxEnvelope);
    if (map['version'] != 1 ||
        map['kind'] != 'valid' ||
        map['rooms'] is! List ||
        (map['rooms'] as List).length > 40) {
      throw const FormatException('Invalid projection payload');
    }
    return StartupProjection(
        (map['rooms'] as List).map(StartupProjectionRoom.fromJson).toList());
  }
}
