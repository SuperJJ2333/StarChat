import 'dart:io';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/group_room_authority.dart';
import 'package:liuhetong_mobile/features/matrix/group_announcement_service.dart';

void main() {
  final previousPaths = PathProviderPlatform.instance;
  setUpAll(() async {
    final parent = Directory(
            '../../docs/verification/artifacts/2026-09-24/announcement-public/image-cache')
        .absolute;
    await parent.create(recursive: true);
    final root = await parent.createTemp('test-');
    PathProviderPlatform.instance = _Paths(root.path);
  });
  tearDownAll(() => PathProviderPlatform.instance = previousPaths);
  test('publishing retained plaintext image creates an encrypted attachment',
      () async {
    final room = _PublishingRoom();
    room.document = _ImageEvent(room, legacy: false);
    final client = room.client as _PublishingClient;
    await MatrixGroupAnnouncementService(room).save(
        const GroupAnnouncement([AnnouncementBlock.image(r'$public-image')]));
    expect(client.uploaded, isNull);
    expect(room.uploadedFile?.preEncrypted, isNotNull);
    expect(room.sent!['blocks'], [
      {'type': 'image', 'value': r'$encrypted-image'}
    ]);
    expect(client.published, {'event_id': r'$encrypted-document'});
  });
  test(
      'missing retained image key preserves reference and explains reselection',
      () async {
    final room = _PublishingRoom();
    room.document = Event(
        room: room,
        type: EventTypes.Encrypted,
        content: {'ciphertext': 'unavailable'},
        senderId: '@owner:test',
        eventId: r'$missing-image',
        originServerTs: DateTime(2026));
    final client = room.client as _PublishingClient;
    client.published = {'event_id': r'$old-document'};
    await expectLater(
        MatrixGroupAnnouncementService(room).save(const GroupAnnouncement(
            [AnnouncementBlock.image(r'$missing-image')])),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'action', contains('删除或重新选择'))));
    expect(client.published, {'event_id': r'$old-document'});
    expect(room.sent, isNull);
    expect(client.uploaded, isNull);
  });
  for (final legacy in [false, true]) {
    test('loads ${legacy ? 'legacy encrypted' : 'public'} announcement image',
        () async {
      final room = _AnnouncementRoom();
      room.document = _ImageEvent(room, legacy: legacy);
      expect(
          await MatrixGroupAnnouncementService(room)
              .loadImage(room.document!.eventId),
          [1, 2, 3]);
    });
  }
  test('ordinary plaintext image cannot be treated as announcement image',
      () async {
    final room = _AnnouncementRoom();
    room.document = _ImageEvent(room, legacy: false, marked: false);
    await expectLater(
        MatrixGroupAnnouncementService(room).loadImage(r'$unmarked'),
        throwsStateError);
  });
  test('malformed document and untrusted image URLs remain rejected', () {
    for (final content in <Map<String, dynamic>>[
      {'msgtype': 'm.image', 'body': 'image'},
      {'msgtype': groupAnnouncementMessageType, 'blocks': 'invalid'},
      {'msgtype': groupAnnouncementMessageType, 'blocks': List.filled(101, {})},
    ]) {
      expect(
          () => GroupAnnouncement.fromContent(content), throwsFormatException);
    }
    final document = GroupAnnouncement.fromContent({
      'msgtype': groupAnnouncementMessageType,
      'blocks': [
        {'type': 'image', 'value': 'https://untrusted.test/image'},
        {'type': 'text', 'value': 'safe text'}
      ],
    });
    expect(document.blocks.length, 1);
    expect(document.preview, 'safe text');
  });
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
  test('save uses the encrypted room document gateway', () async {
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
        {'event_id': r'$encrypted-document'});
  });
  test('failed encrypted send never replaces current published reference',
      () async {
    final room = _PublishingRoom();
    room.fail = true;
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
  test('reads plaintext document referenced by room state', () async {
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
    expect((await MatrixGroupAnnouncementService(room).load()).preview,
        'plaintext');
  });
  test('ordinary member cannot publish announcement', () async {
    final room = _AnnouncementRoom();
    room.setState(Event(
        type: EventTypes.RoomCreate,
        content: {},
        senderId: '@other-owner:test',
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
  Uint8List? uploaded;
  @override
  Future<Uri> uploadContent(Uint8List file,
      {String? filename, String? contentType}) async {
    uploaded = file;
    fail('announcement must not upload unencrypted media directly');
  }

  @override
  Future<String> sendMessage(String roomId, String eventType, String txnId,
      Map<String, Object?> body) async {
    fail('announcement must not send a plaintext Matrix message directly');
  }

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
  _PublishingRoom() : super(id: '!room:test', client: _PublishingClient()) {
    setState(Event(
        room: this,
        type: EventTypes.RoomCreate,
        content: {},
        senderId: '@owner:test',
        eventId: r'$create',
        stateKey: '',
        originServerTs: DateTime(2026)));
  }
  Event? document;
  MatrixFile? uploadedFile;
  Map<String, dynamic>? sent;
  bool fail = false;
  @override
  Future<Event?> getEventById(String eventID) async => document;
  @override
  bool get encrypted => true;

  @override
  Future<String?> sendFileEvent(MatrixFile file,
      {String? txid,
      Event? inReplyTo,
      String? editEventId,
      int? shrinkImageMaxDimension,
      MatrixImageFile? thumbnail,
      Map<String, dynamic>? extraContent,
      String? threadRootEventId,
      String? threadLastEventId}) async {
    uploadedFile = file;
    return r'$encrypted-image';
  }

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
    return r'$encrypted-document';
  }
}

class _ImageEvent extends Event {
  _ImageEvent(Room room, {required bool legacy, bool marked = true})
      : super(
            room: room,
            type: EventTypes.Message,
            senderId: '@owner:test',
            eventId: legacy ? r'$legacy-image' : r'$public-image',
            originServerTs: DateTime(2026),
            content: {
              'msgtype': MessageTypes.Image,
              'body': 'image.png',
              'url': 'mxc://test/image',
              if (marked) 'com.changliao.group.announcement.image': true
            },
            originalSource: legacy
                ? MatrixEvent(
                    type: EventTypes.Encrypted,
                    content: {},
                    senderId: '@owner:test',
                    eventId: r'$legacy-image',
                    originServerTs: DateTime(2026))
                : null);
  @override
  Future<MatrixFile> downloadAndDecryptAttachment(
          {bool getThumbnail = false,
          Future<Uint8List> Function(Uri)? downloadCallback,
          bool fromLocalStoreOnly = false}) async =>
      MatrixFile(bytes: Uint8List.fromList([1, 2, 3]), name: 'image.png');
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}
