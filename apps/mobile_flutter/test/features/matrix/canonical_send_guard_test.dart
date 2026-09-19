import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/duplicate_room_registry.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/logical_conversation_timeline.dart';

class _Client extends Client {
  _Client() : super('canonical-guard');
  final roomsById = <String, Room>{};
  @override
  String? get userID => '@me:test';
  @override
  Room? getRoomById(String id) => roomsById[id];
  @override
  bool get fileEncryptionEnabled => true;
}

class _Timeline extends Fake implements Timeline {
  @override
  final events = <Event>[];
  int cancellations = 0;
  @override
  void cancelSubscriptions() {
    cancellations++;
  }

  final readIds = <String?>[];
  @override
  Future<void> setReadMarker({String? eventId, bool? public}) async {
    readIds.add(eventId);
  }
}

class _Room extends Room {
  _Room(Client client, String id, {this.peer}) : super(id: id, client: client);
  final String? peer;
  bool encryptedValue = true;
  Membership membershipValue = Membership.join;
  bool sendAllowed = true;
  int sends = 0;
  bool failTimeline = false;
  final timeline = _Timeline();
  @override
  bool get encrypted => encryptedValue;
  @override
  Membership get membership => membershipValue;
  @override
  bool get canSendDefaultMessages => sendAllowed;
  @override
  String? get directChatMatrixID => peer;
  @override
  bool get isDirectChat => peer != null;
  @override
  Future<Timeline> getTimeline(
      {void Function(int)? onChange,
      void Function(int)? onRemove,
      void Function(int)? onInsert,
      void Function()? onNewEvent,
      void Function()? onUpdate,
      String? eventContextId}) async {
    if (failTimeline) throw StateError('timeline unavailable');
    return timeline;
  }

  @override
  Future<String?> sendEvent(Map<String, dynamic> content,
      {String type = EventTypes.Message,
      String? txid,
      Event? inReplyTo,
      String? editEventId,
      String? threadRootEventId,
      String? threadLastEventId}) async {
    sends++;
    return r'$sent';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('production gate rejects unsafe room state despite business approval',
      () async {
    final client = _Client();
    final room = _Room(client, '!room:test', peer: '@peer:test');
    client.roomsById[room.id] = room;
    final owner =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    owner.authorizeRoomSend = (_, __, ___) async => true;
    room.setState(User('@me:test', membership: 'join', room: room));
    room.setState(User('@peer:test', membership: 'join', room: room));
    room.summary = RoomSummary.fromJson(
        {'m.joined_member_count': 2, 'm.invited_member_count': 0});
    final lease = await owner.openRoomLease(room.id);
    await lease.sendMessageContent({'body': 'allowed'}, txid: 'allowed');
    expect(room.sends, 1);
    room.membershipValue = Membership.leave;
    await expectLater(lease.sendMessageContent({'body': 'left'}, txid: 'left'),
        throwsStateError);
    room.membershipValue = Membership.join;
    room.encryptedValue = false;
    await expectLater(
        lease.sendMessageContent({'body': 'plain'}, txid: 'plain'),
        throwsStateError);
    room.encryptedValue = true;
    room.sendAllowed = false;
    await expectLater(
        lease.sendMessageContent({'body': 'denied'}, txid: 'denied'),
        throwsStateError);
    room.sendAllowed = true;
    room.summary = RoomSummary.fromJson(
        {'m.joined_member_count': 3, 'm.invited_member_count': 0});
    await expectLater(
        lease.sendMessageContent({'body': 'incomplete'}, txid: 'incomplete'),
        throwsStateError);
    room.summary = RoomSummary.fromJson(
        {'m.joined_member_count': 2, 'm.invited_member_count': 1});
    room.setState(User('@extra:test', membership: 'invite', room: room));
    await expectLater(
        lease.sendMessageContent({'body': 'extra'}, txid: 'extra'),
        throwsStateError);
    expect(room.sends, 1);
    expect(lease.roomInfo.id, room.id);
    await lease.cancel();
  });

  test(
      'denied owner and lease sends never reach SDK transport; reads remain available',
      () async {
    final client = _Client();
    final room = _Room(client, '!old:test', peer: '@peer:test');
    client.roomsById[room.id] = room;
    final owner =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    var checks = 0;
    owner.authorizeRoomSend = (account, roomId, peer) async {
      checks++;
      return false;
    };
    final lease = await owner.openRoomLease(room.id);
    expect(lease.roomInfo.id, room.id);
    expect(checks, 0);
    final timeline = await lease.openRoomTimeline(onUpdate: () {});
    final actions = <Future<dynamic> Function()>[
      () => owner.sendEncryptedText(room.id, 'text'),
      () => lease.sendMessageContent({'body': 'text'}, txid: 'tx'),
      () => lease.send(room.id, {'body': 'nudge'}),
      () => timeline.sendText('text'),
      () => timeline.sendTextWithTransaction('text', 'tx'),
      () => timeline.retry('missing'),
      () => owner.sendFriendAccepted(room.id, '@peer:test', 'peer'),
      () => lease.sendEncryptedAttachment(
          bytes: Uint8List(1), name: 'a', mimeType: 'application/octet-stream'),
      () => owner.sendEncryptedMedia(room.id, [1], 'application/octet-stream'),
      () => lease.forwardEncryptedText(room.id, room.id, 'forward'),
      () => timeline.sendTransferReference('transfer', '1', null),
      () => timeline.sendRedPacketReference('packet', 'hello'),
    ];
    for (final action in actions) {
      await expectLater(action(), throwsStateError);
    }
    expect(checks, actions.length);
    expect(room.sends, 0);
    expect(lease.roomInfo.id, room.id);
    timeline.dispose();
    await lease.cancel();
  });

  test(
      'historical room without m.direct supplies registry peer to authorization',
      () async {
    final registry = DuplicateRoomRegistry();
    await registry.record(
        accountId: '@me:test',
        peerId: '@peer:test',
        primaryRoomId: '!new:test',
        duplicateRoomId: '!old:test');
    final client = _Client();
    client.roomsById['!old:test'] = _Room(client, '!old:test');
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'), duplicateRooms: registry);
    String? observed;
    owner.authorizeRoomSend = (account, roomId, peer) async {
      observed = peer;
      return false;
    };
    expect(await owner.authorizeSendToRoom('!old:test'), isFalse);
    expect(observed, '@peer:test');
  });

  test('lease revoked while authorization waits cannot send', () async {
    final client = _Client();
    final room = _Room(client, '!room:test');
    client.roomsById[room.id] = room;
    final owner =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    final permission = Completer<bool>();
    owner.authorizeRoomSend = (_, __, ___) => permission.future;
    final lease = await owner.openRoomLease(room.id);
    final sending = lease.sendMessageContent({'body': 'text'}, txid: 'tx');
    final expected = expectLater(sending, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    lease.revokeNow();
    permission.complete(true);
    await expected;
    expect(room.sends, 0);
    await lease.cancel();
  });

  test('single source retains logical wrapper for later history', () async {
    final client = _Client();
    final room = _Room(client, '!room:test', peer: '@peer:test');
    client.roomsById[room.id] = room;
    final owner =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    final lease = await owner.openRoomLease(room.id);
    final timeline = await lease.openLogicalRoomTimeline(onUpdate: () {});
    expect(timeline, isA<LogicalConversationTimelineCapability>());
    timeline.dispose();
    await lease.cancel();
  });

  test('initial history attachment failure disposes already opened primary',
      () async {
    final registry = DuplicateRoomRegistry();
    await registry.record(
        accountId: '@me:test',
        peerId: '@peer:test',
        primaryRoomId: '!new:test',
        duplicateRoomId: '!old:test');
    final client = _Client();
    final primary = _Room(client, '!new:test', peer: '@peer:test');
    client.roomsById[primary.id] = primary;
    client.roomsById['!old:test'] = _Room(client, '!old:test')
      ..failTimeline = true;
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'), duplicateRooms: registry);
    final lease = await owner.openRoomLease(primary.id);
    await expectLater(
        lease.openLogicalRoomTimeline(onUpdate: () {}), throwsStateError);
    expect(primary.timeline.cancellations, 1);
    await lease.cancel();
  });

  test('visible receipt does not move backwards while browsing older messages',
      () async {
    final client = _Client();
    final room = _Room(client, '!room:test');
    client.roomsById[room.id] = room;
    for (final day in [2, 1]) {
      room.timeline.events.add(Event(
          room: room,
          eventId: '\$event-$day',
          senderId: '@peer:test',
          type: EventTypes.Message,
          content: {'msgtype': 'm.text', 'body': 'text'},
          originServerTs: DateTime(2026, 1, day)));
    }
    final owner =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    final lease = await owner.openRoomLease(room.id);
    final timeline = await lease.openRoomTimeline(onUpdate: () {});
    final receipts = timeline as RoomVisibleReadCapability;
    await receipts.markReadVisible([r'$event-2']);
    await receipts.markReadVisible([r'$event-1']);
    expect(room.timeline.readIds, [r'$event-2']);
    timeline.dispose();
    await lease.cancel();
  });

  test('reopen anchor attaches history discovered after the initial singleton',
      () async {
    final registry = DuplicateRoomRegistry();
    final client = _Client();
    final primary = _Room(client, '!new:test', peer: '@peer:test');
    client.roomsById[primary.id] = primary;
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'), duplicateRooms: registry);
    final lease = await owner.openRoomLease(primary.id);
    final timeline = await lease.openLogicalRoomTimeline(onUpdate: () {});
    client.roomsById['!old:test'] = _Room(client, '!old:test');
    await registry.record(
        accountId: '@me:test',
        peerId: '@peer:test',
        primaryRoomId: primary.id,
        duplicateRoomId: '!old:test');
    await lease.hintLogicalEventSource(r'$cold-anchor', '!old:test');
    expect(lease.leaseForEvent(r'$cold-anchor').roomId, '!old:test');
    expect(owner.logicalConversationKeySync(primary.id),
        owner.logicalConversationKeySync('!old:test'));
    timeline.dispose();
    await lease.cancel();
  });
}
