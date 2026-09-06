import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:matrix/matrix.dart';
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
    await tester.tap(find.text('添加图片'));
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
    await tester.tap(find.text('添加图片'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(tester.widget<Image>(find.byType(Image)).image, isA<ResizeImage>());
    expect(room.operations, isEmpty);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    expect(room.operations, isEmpty);
  });
  test('publishing uploads local draft images before the encrypted document',
      () async {
    final room = _Room();
    await MatrixGroupAnnouncementService(room).save(GroupAnnouncement([
      AnnouncementBlock.text('hello'),
      AnnouncementBlock.localImage(png, 'draft.png')
    ]));
    expect(room.operations, ['image', 'document']);
    expect(room.sent!['blocks'], [
      {'type': 'text', 'value': 'hello'},
      {'type': 'image', 'value': r'$image'}
    ]);
    expect((room.client as _Client).published, {'event_id': r'$document'});
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
}

class _Client extends Client {
  _Client() : super('announcement-review');
  Map<String, Object?>? published;
  @override
  String? get userID => '@owner:test';
  @override
  bool get encryptionEnabled => true;
  @override
  Future<String> setRoomStateWithKey(String roomId, String eventType,
      String stateKey, Map<String, Object?> body) async {
    published = body;
    return r'$reference';
  }
}

class _Room extends Room {
  _Room() : super(id: '!room:test', client: _Client()) {
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
