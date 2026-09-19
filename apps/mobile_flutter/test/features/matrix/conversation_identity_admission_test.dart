import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_identity_admission.dart';
import 'package:liuhetong_mobile/features/matrix/duplicate_room_registry.dart';
import 'direct_room_identity_integration_test.dart';

void main() {
  late IdentityFlowClient client;
  late DuplicateRoomRegistry registry;
  late IdentityFlowRoom room;
  void state(String type, Map<String, dynamic> content) => room.setState(Event(
      room: room,
      type: type,
      content: content,
      stateKey: '',
      senderId: '@me:test',
      eventId: 'state-$type',
      originServerTs: DateTime.utc(2026, 9, 19)));
  String? identity() => admitConversationIdentity(room, '@me:test', registry);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    client = IdentityFlowClient();
    registry = DuplicateRoomRegistry();
    room = IdentityFlowRoom(
        client: client,
        id: '!room:test',
        membership: Membership.join,
        summary: RoomSummary.fromJson(
            {'m.joined_member_count': 2, 'm.invited_member_count': 0}));
  });
  test('a name and two members cannot turn an unknown room into a group or DM',
      () {
    state(EventTypes.RoomName, {'name': '同一个好友'});
    room.partial = false;
    expect(identity(), isNull);
  });
  test('ambiguous m.direct never chooses first map entry', () {
    client.directory['@peer:test'] = ['!room:test'];
    client.directory['@other:test'] = ['!room:test'];
    expect(identity(), isNull);
  });
  test('malformed or self m.direct identity stays pending', () {
    for (final peer in ['', 'bad', '@me:test', '@bad peer:test']) {
      client.directory
        ..clear()
        ..[peer] = ['!room:test'];
      expect(identity(), isNull);
    }
  });
  test('explicit direct metadata works before lazy member hydration', () {
    state(conversationKindStateType, {
      'kind': 'direct',
      'participants': ['@me:test', '@peer:test']
    });
    expect(room.partial, isTrue);
    expect(identity(), '@peer:test');
  });
  test('malformed direct metadata cannot fall through to group', () {
    state(conversationKindStateType, {
      'kind': 'direct',
      'participants': ['@other:test', '@peer:test']
    });
    state('com.changliao.group.settings', {});
    expect(identity(), isNull);
  });
  test('reservation with incomplete membership stays pending', () {
    state('com.chatflow.direct_reservation', {'reservation_id': 'id'});
    expect(identity(), isNull);
  });
  test('reservation with an unexpected third member stays pending', () {
    state('com.chatflow.direct_reservation', {'reservation_id': 'id'});
    room.partial = false;
    room.setState(Event(
        room: room,
        type: EventTypes.RoomMember,
        stateKey: '@other:test',
        senderId: '@other:test',
        eventId: 'member-other',
        originServerTs: DateTime.utc(2026, 9, 19),
        content: {'membership': 'join'}));
    expect(identity(), isNull);
  });
  test('legacy app power-level keys establish group identity', () {
    state(EventTypes.RoomPowerLevels, {
      'events': {
        'com.changliao.group.settings': 50,
        'com.changliao.group.announcement': 50
      }
    });
    expect(identity(), 'group');
  });
  test('explicit group remains a group independent of name and member count',
      () {
    state(conversationKindStateType, {'kind': 'group'});
    expect(identity(), 'group');
  });
  test(
      'local identity is durable account-scoped and never elects a send destination',
      () async {
    await registry.rememberLocalIdentities(
        '@me:test', {'!room:test': '@peer:test', '!group:test': 'group'});
    expect(registry.primaryRoomIdForPeer('@me:test', '@peer:test'), isNull);
    final restarted = DuplicateRoomRegistry();
    await restarted.ensureLoaded('@me:test');
    await restarted.ensureLoaded('@other:test');
    expect(restarted.peerIdForRoom('@me:test', '!room:test'), '@peer:test');
    expect(restarted.isKnownGroup('@me:test', '!group:test'), isTrue);
    expect(restarted.peerIdForRoom('@other:test', '!room:test'), isNull);
    expect(restarted.isKnownGroup('@other:test', '!group:test'), isFalse);
    expect(restarted.primaryRoomIdForPeer('@me:test', '@peer:test'), isNull);
  });
  test('revisioned authority takes precedence without cache rolling it back',
      () async {
    await registry
        .rememberLocalIdentities('@me:test', {'!room:test': '@peer:test'});
    await registry.rememberPrimary('@me:test', '@peer:test', '!new:test',
        revision: 3);
    await registry.record(
        accountId: '@me:test',
        peerId: '@peer:test',
        primaryRoomId: '!new:test',
        duplicateRoomId: '!room:test',
        revision: 3);
    await registry.rememberLocalIdentities('@me:test', {'!room:test': 'group'});
    expect(identity(), '@peer:test');
    expect(
        registry.primaryRoomIdForPeer('@me:test', '@peer:test'), '!new:test');
    expect(registry.revisionForPeer('@me:test', '@peer:test'), 3);
  });
  test('retained local hint cannot conceal contradictory current directory',
      () async {
    await registry
        .rememberLocalIdentities('@me:test', {'!room:test': '@peer:test'});
    client.directory['@other:test'] = ['!room:test'];
    expect(identity(), isNull);
    client.directory['@peer:test'] = ['!room:test'];
    expect(identity(), isNull);
    client.directory.clear();
    expect(identity(), '@peer:test',
        reason: 'missing network metadata is not contradictory evidence');
  });

  test('authoritative reassociation replaces stale local history peer',
      () async {
    await registry
        .rememberLocalIdentities('@me:test', {'!room:test': '@peer:test'});
    await registry.rememberPrimary('@me:test', '@other:test', '!room:test',
        revision: 4);
    expect(registry.localDirectPeers('@me:test')['!room:test'], '@other:test');
  });
  test('legacy complete multiparty state proves group without a modern marker',
      () {
    final legacy = IdentityFlowRoom(
        client: client,
        id: '!legacy:test',
        membership: Membership.join,
        summary: RoomSummary.fromJson(
            {'m.joined_member_count': 3, 'm.invited_member_count': 0}));
    legacy.partial = false;
    legacy.setState(Event(
        room: legacy,
        type: EventTypes.RoomMember,
        stateKey: '@third:test',
        senderId: '@third:test',
        eventId: 'third',
        originServerTs: DateTime.utc(2026, 9, 19),
        content: {'membership': 'join'}));
    expect(admitConversationIdentity(legacy, '@me:test', registry), 'group');
    legacy.setState(Event(
        room: legacy,
        type: 'com.chatflow.direct_reservation',
        stateKey: '',
        senderId: '@me:test',
        eventId: 'dm',
        originServerTs: DateTime.utc(2026, 9, 19),
        content: {'reservation_id': 'dm'}));
    expect(admitConversationIdentity(legacy, '@me:test', registry), isNull,
        reason: 'a malformed known DM cannot be reclassified by member count');
  });
  test(
      'summary alone cannot classify a group without complete local membership',
      () {
    final incomplete = IdentityFlowRoom(
        client: client,
        id: '!legacy:test',
        membership: Membership.join,
        summary: RoomSummary.fromJson(
            {'m.joined_member_count': 3, 'm.invited_member_count': 0}));
    incomplete.partial = false;
    expect(admitConversationIdentity(incomplete, '@me:test', registry), isNull);
  });
}
