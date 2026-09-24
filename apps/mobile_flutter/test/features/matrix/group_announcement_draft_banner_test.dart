import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/group_announcement_service.dart';
import 'package:liuhetong_mobile/features/matrix/group_announcement_page.dart';
import 'package:liuhetong_mobile/features/matrix/group_room_authority.dart';

void main() {
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

class _Client extends Client {
  _Client() : super('announcement-review');
  late _Room room;
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
  String? get userID => '@owner:test';
  @override
  bool get encryptionEnabled => encryptionAvailable;
  @override
  Future<String> setRoomStateWithKey(String roomId, String eventType,
      String stateKey, Map<String, Object?> body) async {
    published = body;
    return r'$reference';
  }
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
  }
  final operations = <String>[];
  MatrixFile? uploadedFile;
  Map<String, dynamic>? uploadedExtra;
  bool failSend = false;
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
    return r'$document';
  }
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
