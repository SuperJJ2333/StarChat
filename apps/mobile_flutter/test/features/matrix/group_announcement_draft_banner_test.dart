import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart' hide Visibility;
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/group_announcement_service.dart';
import 'package:liuhetong_mobile/features/matrix/group_announcement_page.dart';
import 'package:liuhetong_mobile/features/matrix/group_room_authority.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';

void main() {
  testWidgets('unrelated sync does not cancel unreadable rewrite confirmation',
      (tester) async {
    final room = _Room();
    _unreadable(room, r'$old');
    await tester.pumpWidget(CupertinoApp(
        home: GroupAnnouncementPage(
            service: MatrixGroupAnnouncementService(room))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新编写'));
    await tester.pumpAndSettle();
    room.onSessionKeyReceived.add('unrelated-session');
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续编写'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoTextField), findsOneWidget);
    expect(room.operations, isEmpty);
  });
  testWidgets('changed reference cancels unreadable rewrite confirmation',
      (tester) async {
    final room = _Room();
    _unreadable(room, r'$old');
    await tester.pumpWidget(CupertinoApp(
        home: GroupAnnouncementPage(
            service: MatrixGroupAnnouncementService(room))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新编写'));
    await tester.pumpAndSettle();
    room.reference({'event_id': r'$new'});
    await tester.tap(find.text('继续编写'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoTextField), findsNothing);
    expect(room.operations, isEmpty);
  });
  testWidgets('rewriting uses new encrypted document without reading old text',
      (tester) async {
    final room = _Room();
    _unreadable(room, r'$old');
    await tester.pumpWidget(CupertinoApp(
        home: GroupAnnouncementPage(
            service: MatrixGroupAnnouncementService(room))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新编写'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续编写'));
    await tester.pumpAndSettle();
    (room.client as _Client).encryptionAvailable = true;
    await tester.enterText(find.byType(CupertinoTextField), '新的加密公告');
    await tester.tap(find.text('发布'));
    await tester.pumpAndSettle();
    expect(room.operations, ['document']);
    expect(room.sent!['blocks'], [
      {'type': 'text', 'value': '新的加密公告'}
    ]);
    expect((room.client as _Client).published, {'event_id': r'$document'});
  });
  testWidgets('missing referenced event exposes explicit administrator repair',
      (tester) async {
    final room = _Room()..reference({'event_id': r'$missing'});
    await tester.pumpWidget(CupertinoApp(
        home: GroupAnnouncementPage(
            service: MatrixGroupAnnouncementService(room))));
    await tester.pumpAndSettle();
    expect(find.text('重新编写'), findsOneWidget);
    expect(find.byKey(const Key('group-announcement-delete')), findsOneWidget);
    expect(room.operations, isEmpty);
    expect((room.client as _Client).published, isNull);
  });
  test(
      'clearing only the public reference does not require old encryption keys',
      () async {
    final room = _Room()..reference({'event_id': r'$missing'});
    (room.client as _Client).encryptionAvailable = false;
    await MatrixGroupAnnouncementService(room)
        .save(const GroupAnnouncement([]));
    expect((room.client as _Client).published, isEmpty);
    expect(room.operations, isEmpty);
  });
  test('actual announcement state power level rejects lower-level managers',
      () async {
    final room = _Room();
    room.setState(Event(
        type: EventTypes.RoomPowerLevels,
        content: {
          'users': {'@owner:test': 50},
          'events': {groupAnnouncementStateType: 100},
        },
        senderId: '@owner:test',
        room: room,
        eventId: r'$power',
        stateKey: '',
        originServerTs: DateTime(2026)));
    final service = MatrixGroupAnnouncementService(room);
    expect(service.canEdit, isFalse);
    await expectLater(
        service.save(const GroupAnnouncement([])), throwsStateError);
    expect((room.client as _Client).published, isNull);
  });
  testWidgets('delete requires confirmation and preserves unreadable history',
      (tester) async {
    final room = _Room()..reference({'event_id': r'$missing'});
    (room.client as _Client).encryptionAvailable = false;
    await tester.pumpWidget(CupertinoApp(
        home: GroupAnnouncementPage(
            service: MatrixGroupAnnouncementService(room))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-announcement-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((room.client as _Client).published, isNull);
    await tester.tap(find.byKey(const Key('group-announcement-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect((room.client as _Client).published, isEmpty);
    expect(room.operations, isEmpty);
  });
  for (final change in ['account', 'permission', 'reference']) {
    testWidgets('$change change prevents confirmed deletion', (tester) async {
      final room = _Room()..reference({'event_id': r'$missing'});
      await tester.pumpWidget(CupertinoApp(
          home: GroupAnnouncementPage(
              service: MatrixGroupAnnouncementService(room))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('group-announcement-delete')));
      await tester.pumpAndSettle();
      if (change == 'account') {
        (room.client as _Client).accountId = '@other:test';
      } else if (change == 'permission') {
        room.membership = Membership.leave;
      } else {
        room.reference({'event_id': r'$new'});
      }
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect((room.client as _Client).published, isNull);
      expect(room.operations, isEmpty);
    });
  }
  test('ordinary joined member cannot clear a missing reference', () async {
    final room = _Room()..reference({'event_id': r'$missing'});
    (room.client as _Client).accountId = '@member:test';
    final service = MatrixGroupAnnouncementService(room);
    expect(service.canEdit, isFalse);
    await expectLater(
        service.save(const GroupAnnouncement([])), throwsStateError);
    expect((room.client as _Client).published, isNull);
  });
  testWidgets('sender-integrity failure never exposes unreadable repair',
      (tester) async {
    final room = _Room()..reference({'event_id': r'$wrong-sender'});
    room.pending = Future.value(Event(
        type: EventTypes.Message,
        content: const GroupAnnouncement([AnnouncementBlock.text('invalid')])
            .toContent(),
        senderId: '@other:test',
        room: room,
        eventId: r'$wrong-sender',
        originServerTs: DateTime(2026)));
    await tester.pumpWidget(CupertinoApp(
        home: GroupAnnouncementPage(
            service: MatrixGroupAnnouncementService(room))));
    await tester.pumpAndSettle();
    expect(find.text('重新编写'), findsNothing);
    expect(find.byKey(const Key('group-announcement-delete')), findsNothing);
  });
  testWidgets('live state change without sync prevents draft publication',
      (tester) async {
    final room = _Room();
    await tester.pumpWidget(CupertinoApp(
        home: GroupAnnouncementPage(
            service: MatrixGroupAnnouncementService(room))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pump();
    await tester.enterText(find.byType(CupertinoTextField), 'old draft');
    room.reference({'event_id': r'$new'});
    await tester.tap(find.text('发布'));
    await tester.pumpAndSettle();
    expect(room.operations, isEmpty);
    expect((room.client as _Client).published, isNull);
    expect(find.text('公告或权限已变更，请重新打开后编辑'), findsOneWidget);
  });
  for (final change in ['account', 'permission', 'reference']) {
    test(
        'a $change change during encrypted send cannot overwrite the reference',
        () async {
      final room = _Room();
      room.setState(Event(
          type: EventTypes.RoomPowerLevels,
          content: {
            'users': {'@owner:test': 100, '@other:test': 100},
            'events': {
              groupAnnouncementStateType: 50,
              groupSettingsStateType: 50
            },
          },
          senderId: '@owner:test',
          room: room,
          eventId: r'$power',
          stateKey: '',
          originServerTs: DateTime(2026)));
      room.onSend = () {
        if (change == 'account') {
          (room.client as _Client).accountId = '@other:test';
        } else if (change == 'permission') {
          room.membership = Membership.leave;
        } else {
          room.reference({'event_id': r'$new'});
        }
      };
      await expectLater(
          MatrixGroupAnnouncementService(room).save(
              const GroupAnnouncement([AnnouncementBlock.text('new text')])),
          throwsStateError);
      expect(room.operations, ['document']);
      expect((room.client as _Client).published, isNull);
    });
  }
  testWidgets('real lease dismissal persists by account room and publication',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final room = _Room();
    final client = room.client as _Client;
    MatrixSdkE2eeClient accountOwner() => MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.invalid'),
        readContinuityMetadata: (client) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: false,
                userId: client.userID,
                deviceId: client.deviceID,
                ed25519Fingerprint: null,
                databaseGeneration: 'announcement-lease-fixture'));
    var owner = accountOwner();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.invalid'),
        sessionStore: SecureSessionStore(_LocalSecureStore()),
        client: MockClient((_) async => http.Response('{}', 404)));
    void publish(String id) {
      room.reference({'event_id': id});
      room.pending = Future.value(Event(
          type: EventTypes.Message,
          content: const GroupAnnouncement([AnnouncementBlock.text('lease公告')])
              .toContent(),
          senderId: '@owner:test',
          room: room,
          eventId: id,
          originServerTs: DateTime(2026)));
    }

    Future<MatrixRoomLease> open() async {
      final lease = await owner.openRoomLease(room.id);
      await tester.pumpWidget(CupertinoApp(
          home: RoomPage(
              api: api,
              roomLease: lease,
              roomName: '公告房间',
              onCreateGroup: () {})));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      return lease;
    }

    Future<void> close(MatrixRoomLease lease) async {
      // Fully unmount the Navigator/page before awaiting its owner drain.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final cancellation = lease.cancel();
      await tester.pump();
      await cancellation;
    }

    publish(r'$first');
    var lease = await open();
    expect(find.text('lease公告'), findsOneWidget);
    await tester.tap(find.byKey(const Key('group-announcement-dismiss')));
    await tester.pumpAndSettle();
    await close(lease);
    lease = await open();
    expect(find.text('lease公告'), findsNothing);
    final preferences = await SharedPreferences.getInstance();
    expect(
        preferences.getString('group_announcement_dismissed_v1:${jsonEncode([
              '@owner:test',
              room.id
            ])}'),
        r'$first');
    final banner = tester
        .widget<GroupAnnouncementBanner>(find.byType(GroupAnnouncementBanner));
    expect(banner.dismissalScope,
        jsonEncode([lease.roomInfo.currentUserId, lease.roomInfo.id]));
    expect(banner.service, isA<GroupAnnouncementReferenceSource>());
    expect(
        (banner.service as GroupAnnouncementReferenceSource)
            .announcementReferenceIdentity,
        MatrixGroupAnnouncementService(room).announcementReferenceIdentity);
    await close(lease);
    // Simulate a process restart: retain only persisted preferences, rebuilding
    // the preference cache, Matrix owner, room lease and page state.
    SharedPreferences.setMockInitialValues({
      for (final key in preferences.getKeys()) key: preferences.get(key)!,
    });
    owner = accountOwner();
    lease = await open();
    expect(find.text('lease公告'), findsNothing);
    await close(lease);
    publish(r'$second');
    lease = await open();
    expect(find.text('lease公告'), findsOneWidget);
    await close(lease);
    client.accountId = '@second:test';
    owner = accountOwner();
    publish(r'$first');
    lease = await open();
    expect(find.text('lease公告'), findsOneWidget);
    await close(lease);
  }, timeout: const Timeout(Duration(seconds: 30)));
  test('a revoked real lease cannot publish an announcement reference',
      () async {
    SharedPreferences.setMockInitialValues({});
    final room = _Room();
    final owner = MatrixSdkE2eeClient(room.client,
        homeserver: Uri.parse('https://matrix.invalid'),
        readContinuityMetadata: (client) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: false,
                userId: client.userID,
                deviceId: client.deviceID,
                ed25519Fingerprint: null,
                databaseGeneration: 'announcement-revoked-fixture'));
    final lease = await owner.openRoomLease(room.id);
    final service = lease.openAnnouncementService();
    room.onSend = lease.cancel;
    Object? failure;
    try {
      await service.save(const GroupAnnouncement(
          [AnnouncementBlock.text('private document')]));
    } catch (error) {
      failure = error;
    }
    expect(room.operations, ['document']);
    expect((room.client as _Client).published, isNull);
    expect(failure, isA<StateError>());
    expect(service.canEdit, isFalse);
  }, timeout: const Timeout(Duration(seconds: 30)));
  test('oversized GIF canvas is rejected before upload or image decoding',
      () async {
    final room = _Room();
    final gif =
        Uint8List.fromList([71, 73, 70, 56, 57, 97, 255, 255, 255, 255]);
    await expectLater(
        MatrixGroupAnnouncementService(room).save(GroupAnnouncement(
            [AnnouncementBlock.localImage(gif, 'unsafe.gif')])),
        throwsFormatException);
    expect(room.operations, isEmpty);
  });
  final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==');
  test('save rejects more than 100 blocks before publishing anything',
      () async {
    final room = _Room();
    await expectLater(
        MatrixGroupAnnouncementService(room).save(GroupAnnouncement(
            List.generate(101, (_) => const AnnouncementBlock.text('text')))),
        throwsFormatException);
    expect(room.operations, isEmpty);
  });
  testWidgets('oversized selected image is rejected before reading bytes',
      (tester) async {
    final file = _OversizedFile();
    await tester.pumpWidget(CupertinoApp(
        home: GroupAnnouncementPage(
            service: MatrixGroupAnnouncementService(_Room()),
            pickImage: () async => file)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('group-announcement-add-image')));
    await tester.pumpAndSettle();
    expect(file.reads, 0);
    expect(find.textContaining('20MB'), findsOneWidget);
  });
  testWidgets(
      'publish error retries saved draft rather than reloading old document',
      (tester) async {
    final room = _Room()..failSend = true;
    await tester.pumpWidget(CupertinoApp(
        home: GroupAnnouncementPage(
            service: MatrixGroupAnnouncementService(room))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pump();
    await tester.enterText(find.byType(CupertinoTextField), 'keep this draft');
    await tester.tap(find.text('发布'));
    await tester.pumpAndSettle();
    room.failSend = false;
    await tester.tap(find.textContaining('发布失败'));
    await tester.pumpAndSettle();
    expect(room.operations, ['document', 'document']);
    expect(room.sent!['blocks'], [
      {'type': 'text', 'value': 'keep this draft'}
    ]);
  });
  testWidgets(
      'selecting then cancelling announcement image sends no room events',
      (tester) async {
    final room = _Room();
    await tester.pumpWidget(CupertinoApp(
        home: GroupAnnouncementPage(
            service: MatrixGroupAnnouncementService(room),
            pickImage: () async => XFile.fromData(png, name: 'draft.png'))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('group-announcement-add-image')));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(tester.widget<Image>(find.byType(Image)).image, isA<ResizeImage>());
    expect(room.operations, isEmpty);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    expect(room.operations, isEmpty);
  });
  test('announcement attachments enter the encrypted room media sender',
      () async {
    final room = _Room();
    await MatrixGroupAnnouncementService(room).uploadImage(png, 'draft.png');
    expect(room.uploadedFile?.preEncrypted, isNotNull);
    expect(room.uploadedExtra?['chatflow_media'], isNotNull);
    expect((room.client as _Client).uploadedBytes, isNull);
    expect((room.client as _Client).imageContent, isNull);
  });
  test('missing room encryption stops document and attachment publication',
      () async {
    final room = _Room();
    (room.client as _Client).encryptionAvailable = false;
    await expectLater(
        MatrixGroupAnnouncementService(room).save(GroupAnnouncement([
          AnnouncementBlock.text('私密正文'),
          AnnouncementBlock.localImage(png, 'draft.png')
        ])),
        throwsStateError);
    expect(room.operations, isEmpty);
    expect(room.uploadedFile, isNull);
    expect((room.client as _Client).uploadedBytes, isNull);
    expect((room.client as _Client).published, isNull);
  });
  test('legacy topic uses its state event ID even when text is reissued',
      () async {
    final room = _Room();
    void topic(String id) => room.setState(Event(
          type: EventTypes.RoomTopic,
          content: {'topic': '同样的公告'},
          senderId: '@owner:test',
          room: room,
          eventId: id,
          stateKey: '',
          originServerTs: DateTime(2026, 9, 24),
        ));
    topic(r'$topic-one');
    expect((await MatrixGroupAnnouncementService(room).load()).publicationId,
        r'$topic-one');
    topic(r'$topic-two');
    expect((await MatrixGroupAnnouncementService(room).load()).publicationId,
        r'$topic-two');
  });
  test('publishing encrypts local images before the room document', () async {
    final room = _Room();
    await MatrixGroupAnnouncementService(room).save(GroupAnnouncement([
      AnnouncementBlock.text('hello'),
      AnnouncementBlock.localImage(png, 'draft.png')
    ]));
    expect(room.operations, ['image', 'document']);
    expect(room.uploadedFile?.preEncrypted, isNotNull);
    expect((room.client as _Client).uploadedBytes, isNull);
    expect(room.sent!['blocks'], [
      {'type': 'text', 'value': 'hello'},
      {'type': 'image', 'value': r'$image'}
    ]);
    expect((room.client as _Client).published, {'event_id': r'$document'});
    // Reopen from the published state reference and SDK-decrypted history,
    // without retaining the editor's in-memory local image bytes.
    room.reference({'event_id': r'$document'});
    room.pending = Future.value(Event(
      type: EventTypes.Message,
      content: Map<String, dynamic>.from(room.sent!),
      senderId: '@owner:test',
      room: room,
      eventId: r'$document',
      originServerTs: DateTime(2026),
      originalSource: Event(
          type: EventTypes.Encrypted,
          content: {},
          senderId: '@owner:test',
          room: room,
          eventId: r'$document',
          originServerTs: DateTime(2026)),
    ));
    final reopened = await MatrixGroupAnnouncementService(room).load();
    expect(reopened.publicationId, r'$document');
    expect(reopened.blocks.map((block) => block.value), ['hello', r'$image']);
    expect(reopened.blocks.last.isImage, isTrue);
    expect(reopened.blocks.last.localBytes, isNull);
  });
  testWidgets('cleared banner cannot be resurrected by an older delayed load',
      (tester) async {
    final room = _Room();
    final delayed = Completer<Event?>();
    room.pending = delayed.future;
    room.reference({'event_id': r'$old'});
    await tester.pumpWidget(CupertinoApp(
        home: GroupAnnouncementBanner(
            service: MatrixGroupAnnouncementService(room))));
    await tester.pump();
    room.reference({});
    room.client.onSync.add(SyncUpdate(
        nextBatch: 'next',
        rooms: RoomsUpdate(join: {room.id: JoinedRoomUpdate()})));
    await tester.pump();
    delayed.complete(Event(
        type: EventTypes.Message,
        content: GroupAnnouncement([AnnouncementBlock.text('old announcement')])
            .toContent(),
        senderId: '@owner:test',
        room: room,
        eventId: r'$old',
        originServerTs: DateTime(2026),
        originalSource: MatrixEvent(
            type: EventTypes.Encrypted,
            content: {},
            senderId: '@owner:test',
            eventId: r'$old',
            originServerTs: DateTime(2026))));
    await tester.pumpAndSettle();
    expect(find.text('old announcement'), findsNothing);
    expect(find.byIcon(CupertinoIcons.speaker_2), findsNothing);
  });

  testWidgets(
      'dismissal survives a new Matrix service and resets for a new event',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final room = _Room();
    Event announcement(String id, String text) => Event(
          type: EventTypes.Message,
          content:
              GroupAnnouncement([AnnouncementBlock.text(text)]).toContent(),
          senderId: '@owner:test',
          room: room,
          eventId: id,
          originServerTs: DateTime(2026, 9, 24),
        );
    room.reference({'event_id': r'$first'});
    room.pending = Future.value(announcement(r'$first', '本次公告'));
    await tester.pumpWidget(CupertinoApp(
        home: GroupAnnouncementBanner(
            service: MatrixGroupAnnouncementService(room))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-announcement-dismiss')));
    await tester.pumpAndSettle();
    expect(find.text('本次公告'), findsNothing);

    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    await tester.pumpWidget(CupertinoApp(
        home: GroupAnnouncementBanner(
            service: MatrixGroupAnnouncementService(room))));
    await tester.pumpAndSettle();
    expect(find.text('本次公告'), findsNothing);
    room.reference({'event_id': r'$second'});
    room.pending = Future.value(announcement(r'$second', '本次公告'));
    (room.client as _Client).onSync.add(SyncUpdate(
        nextBatch: 'next',
        rooms: RoomsUpdate(join: {room.id: JoinedRoomUpdate()})));
    await tester.pumpAndSettle();
    expect(find.text('本次公告'), findsOneWidget);
  });
}

void _unreadable(_Room room, String id) {
  (room.client as _Client).encryptionAvailable = false;
  room.reference({'event_id': id});
  room.pending = Future.value(Event(
      type: EventTypes.Encrypted,
      content: {
        'algorithm': 'm.megolm.v1.aes-sha2',
        'ciphertext': 'unreadable'
      },
      senderId: '@owner:test',
      room: room,
      eventId: id,
      originServerTs: DateTime(2026)));
}

class _Client extends Client {
  _Client() : super('announcement-review');
  late _Room room;
  String accountId = '@owner:test';
  bool encryptionAvailable = true;
  Uint8List? uploadedBytes;
  Map<String, Object?>? imageContent;
  @override
  Future<Uri> uploadContent(Uint8List file,
      {String? filename, String? contentType}) async {
    uploadedBytes = file;
    return Uri.parse('mxc://test/image');
  }

  @override
  Future<String> sendMessage(String roomId, String eventType, String txnId,
      Map<String, Object?> body) async {
    fail('announcement must not use the raw plaintext sendMessage gateway');
  }

  Map<String, Object?>? published;
  @override
  String? get userID => accountId;
  @override
  Room? getRoomById(String id) => id == room.id ? room : null;
  @override
  Future<String> createGroupChat({
    String? groupName,
    bool? enableEncryption,
    List<String>? invite,
    CreateRoomPreset preset = CreateRoomPreset.privateChat,
    List<StateEvent>? initialState,
    Visibility? visibility,
    HistoryVisibility? historyVisibility,
    bool waitForSync = true,
    bool groupCall = false,
    bool federated = true,
    Map<String, dynamic>? powerLevelContentOverride,
  }) async =>
      throw StateError('Fixture does not create optional emoji vaults');
  @override
  bool get encryptionEnabled => encryptionAvailable;
  @override
  Future<String> setRoomStateWithKey(String roomId, String eventType,
      String stateKey, Map<String, Object?> body) async {
    published = body;
    return r'$reference';
  }
}

class _LocalSecureStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Room extends Room {
  _Room() : super(id: '!room:test', client: _Client()) {
    (client as _Client).room = this;
    setState(Event(
        type: EventTypes.RoomCreate,
        content: {},
        senderId: '@owner:test',
        room: this,
        eventId: r'$create',
        stateKey: '',
        originServerTs: DateTime(2026)));
    for (final id in ['@owner:test', '@second:test', '@member:test']) {
      setState(User(id, membership: 'join', room: this));
    }
  }
  final operations = <String>[];
  MatrixFile? uploadedFile;
  Map<String, dynamic>? uploadedExtra;
  bool failSend = false;
  FutureOr<void> Function()? onSend;
  Map<String, dynamic>? sent;
  Future<Event?>? pending;
  int revision = 0;
  void reference(Map<String, dynamic> content) => setState(Event(
      type: groupAnnouncementStateType,
      content: content,
      senderId: '@owner:test',
      room: this,
      eventId: '\$reference${revision++}',
      stateKey: '',
      originServerTs: DateTime(2026).add(Duration(seconds: revision))));
  @override
  bool get encrypted => true;
  @override
  Future<List<User>> requestParticipants([
    List<Membership> membershipFilter = const [
      Membership.join,
      Membership.invite,
      Membership.knock,
    ],
    bool suppressWarning = false,
    bool cache = true,
  ]) async =>
      getParticipants(membershipFilter);
  @override
  Future<Timeline> getTimeline({
    void Function(int)? onChange,
    void Function(int)? onRemove,
    void Function(int)? onInsert,
    void Function()? onNewEvent,
    void Function()? onUpdate,
    String? eventContextId,
  }) async =>
      _AnnouncementTimeline();
  @override
  Future<Event?> getEventById(String eventID) => pending ?? Future.value(null);
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
    uploadedExtra = extraContent;
    operations.add('image');
    return r'$image';
  }

  @override
  Future<String?> sendEvent(Map<String, dynamic> content,
      {String type = EventTypes.Message,
      String? txid,
      Event? inReplyTo,
      String? editEventId,
      String? threadRootEventId,
      String? threadLastEventId}) async {
    operations.add('document');
    if (failSend) throw StateError('offline');
    sent = content;
    await onSend?.call();
    return r'$document';
  }
}

class _AnnouncementTimeline extends Fake implements Timeline {
  @override
  final events = <Event>[];
  @override
  bool get canRequestHistory => false;
  @override
  bool get canRequestFuture => false;
  @override
  bool get isFragmentedTimeline => false;
  @override
  Future<void> setReadMarker({String? eventId, bool? public}) async {}
  @override
  void cancelSubscriptions() {}
}

class _OversizedFile extends XFile {
  _OversizedFile() : super('oversized.png');
  int reads = 0;
  @override
  Future<int> length() async => 20 * 1024 * 1024 + 1;
  @override
  Future<Uint8List> readAsBytes() async {
    reads++;
    return Uint8List(0);
  }
}
