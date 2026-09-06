import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/group_room_authority.dart';
import 'package:liuhetong_mobile/features/matrix/group_announcement_service.dart';

void main() {
  test('legacy topic remains readable when no announcement reference exists',
      () async {
    final room = _AnnouncementRoom();
    room.setState(Event(
        type: EventTypes.RoomTopic,
        content: {'topic': '旧群公告'},
        senderId: '@owner:test',
        room: room,
        eventId: r'$topic',
        stateKey: '',
        originServerTs: DateTime(2026)));
    expect((await MatrixGroupAnnouncementService(room).load()).preview, '旧群公告');
  });
  test('explicitly cleared reference never resurrects a legacy topic',
      () async {
    final room = _AnnouncementRoom();
    room.setState(Event(
        type: EventTypes.RoomTopic,
        content: {'topic': '旧群公告'},
        senderId: '@owner:test',
        room: room,
        eventId: r'$topic',
        stateKey: '',
        originServerTs: DateTime(2026)));
    room.setState(Event(
        type: groupAnnouncementStateType,
        content: {},
        senderId: '@owner:test',
        room: room,
        eventId: r'$clear',
        stateKey: '',
        originServerTs: DateTime(2026)));
    expect((await MatrixGroupAnnouncementService(room).load()).isEffective,
        isFalse);
  });
  test('save publishes only opaque reference after encrypted message pipeline',
      () async {
    final room = _PublishingRoom();
    room.setState(Event(
        type: EventTypes.RoomPowerLevels,
        content: {
          'users': {'@owner:test': 100},
          'events': {
            EventTypes.RoomPowerLevels: 100,
            groupAnnouncementStateType: 50,
            groupSettingsStateType: 50
          }
        },
        senderId: '@owner:test',
        room: room,
        eventId: r'$pl',
        stateKey: '',
        originServerTs: DateTime(2026)));
    await MatrixGroupAnnouncementService(room)
        .save(GroupAnnouncement([AnnouncementBlock.text('私密公告')]));
    expect(room.sent?['blocks'], [
      {'type': 'text', 'value': '私密公告'}
    ]);
    expect((room.client as _PublishingClient).published,
        {'event_id': r'$encrypted'});
  });
  test('failed encrypted send never replaces current published reference',
      () async {
    final room = _PublishingRoom()..fail = true;
    room.setState(Event(
        type: EventTypes.RoomPowerLevels,
        content: {
          'users': {'@owner:test': 100},
          'events': {
            EventTypes.RoomPowerLevels: 100,
            groupAnnouncementStateType: 50,
            groupSettingsStateType: 50
          }
        },
        senderId: '@owner:test',
        room: room,
        eventId: r'$pl',
        stateKey: '',
        originServerTs: DateTime(2026)));
    await expectLater(
        MatrixGroupAnnouncementService(room)
            .save(GroupAnnouncement([AnnouncementBlock.text('私密公告')])),
        throwsStateError);
    expect((room.client as _PublishingClient).published, isNull);
  });
  test('rejects plaintext document referenced by room state', () async {
    final room = _AnnouncementRoom();
    room.document = Event(
        type: EventTypes.Message,
        content: GroupAnnouncement([AnnouncementBlock.text('plaintext')])
            .toContent(),
        senderId: '@owner:test',
        room: room,
        eventId: r'$doc',
        originServerTs: DateTime(2026));
    room.setState(Event(
        type: groupAnnouncementStateType,
        content: {'event_id': r'$doc'},
        senderId: '@owner:test',
        room: room,
        eventId: r'$reference',
        stateKey: '',
        originServerTs: DateTime(2026)));
    await expectLater(
        MatrixGroupAnnouncementService(room).load(), throwsStateError);
  });
  test('unencrypted room cannot publish announcement', () async {
    final room = _AnnouncementRoom();
    room.setState(Event(
        type: EventTypes.RoomCreate,
        content: {},
        senderId: '@owner:test',
        room: room,
        eventId: r'$create',
        stateKey: '',
        originServerTs: DateTime(2026)));
    await expectLater(
        MatrixGroupAnnouncementService(room)
            .save(GroupAnnouncement([AnnouncementBlock.text('secret')])),
        throwsStateError);
  });
  test('effective announcement includes image-only and hides whitespace', () {
    expect(
        GroupAnnouncement([AnnouncementBlock.text('  ')]).isEffective, isFalse);
    expect(
        GroupAnnouncement([AnnouncementBlock.image(r'$encrypted-image')])
            .isEffective,
        isTrue);
  });
  test('mixed document roundtrip preserves block order', () {
    final document = GroupAnnouncement([
      AnnouncementBlock.text('第一段'),
      AnnouncementBlock.image(r'$image'),
      AnnouncementBlock.text('第二段')
    ]);
    final loaded = GroupAnnouncement.fromContent(document.toContent());
    expect(loaded.blocks.map((b) => b.value), ['第一段', r'$image', '第二段']);
    expect(loaded.preview, '第一段');
  });
}

class _AnnouncementClient extends Client {
  _AnnouncementClient() : super('announcement-test');
  @override
  String? get userID => '@owner:test';
}

class _AnnouncementRoom extends Room {
  _AnnouncementRoom() : super(id: '!room:test', client: _AnnouncementClient());
  Event? document;
  @override
  Future<Event?> getEventById(String eventID) async => document;
}

class _PublishingClient extends _AnnouncementClient {
  Map<String, Object?>? published;
  @override
  bool get encryptionEnabled => true;
  @override
  Future<String> setRoomStateWithKey(String roomId, String eventType,
      String stateKey, Map<String, Object?> body) async {
    published = body;
    return r'$reference';
  }
}

class _PublishingRoom extends Room {
  _PublishingRoom() : super(id: '!room:test', client: _PublishingClient());
  Map<String, dynamic>? sent;
  bool fail = false;
  @override
  bool get encrypted => true;
  @override
  Future<String?> sendEvent(Map<String, dynamic> content,
      {String type = EventTypes.Message,
      String? txid,
      Event? inReplyTo,
      String? editEventId,
      String? threadRootEventId,
      String? threadLastEventId}) async {
    if (fail) throw StateError('send failed');
    sent = content;
    return r'$encrypted';
  }
}
