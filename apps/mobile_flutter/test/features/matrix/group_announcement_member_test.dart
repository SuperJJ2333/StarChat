import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/features/matrix/group_announcement_service.dart';
import 'package:liuhetong_mobile/features/matrix/group_announcement_page.dart';
import 'package:liuhetong_mobile/features/matrix/group_room_authority.dart';

void main() {
  testWidgets('manager can explicitly clear unreadable current announcement',
      (tester) async {
    final service = _Service()
      ..editable = true
      ..loadFailure = const AnnouncementDecryptionUnavailable();
    await tester.pumpWidget(
        CupertinoApp(home: GroupAnnouncementPage(service: service)));
    await tester.pumpAndSettle();
    expect(find.text('公告无法解密，请联系群管理员重新发布'), findsOneWidget);
    await tester.tap(find.text('重新编写'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续编写'));
    await tester.pumpAndSettle();
    expect(service.saved, isEmpty);
    await tester.tap(find.text('发布'));
    await tester.pumpAndSettle();
    expect(service.saved.single.isEffective, isFalse);
  });

  testWidgets('manager losing authority during confirmation cannot replace',
      (tester) async {
    final service = _Service()
      ..editable = true
      ..loadFailure = const AnnouncementPendingDecryption();
    await tester.pumpWidget(
        CupertinoApp(home: GroupAnnouncementPage(service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新编写'));
    await tester.pumpAndSettle();
    service.editable = false;
    await tester.tap(find.text('继续编写'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoTextField), findsNothing);
    expect(service.saved, isEmpty);
  });

  testWidgets('access denied does not expose replacement even for stale role',
      (tester) async {
    final service = _Service()
      ..editable = true
      ..loadFailure =
          MatrixException(http.Response('{"errcode":"M_FORBIDDEN"}', 403));
    await tester.pumpWidget(
        CupertinoApp(home: GroupAnnouncementPage(service: service)));
    await tester.pumpAndSettle();
    expect(find.text('无权查看群公告'), findsOneWidget);
    expect(find.text('重新编写'), findsNothing);
  });

  testWidgets('manager can explicitly replace unreadable announcement',
      (tester) async {
    final service = _Service()
      ..editable = true
      ..loadFailure = const AnnouncementPendingDecryption();
    await tester.pumpWidget(
        CupertinoApp(home: GroupAnnouncementPage(service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新编写'));
    await tester.pumpAndSettle();
    expect(service.saved, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoTextField), findsNothing);
    await tester.tap(find.text('重新编写'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续编写'));
    await tester.pumpAndSettle();
    expect(service.saved, isEmpty);
    await tester.enterText(find.byType(CupertinoTextField), '新的公告');
    await tester.tap(find.text('发布'));
    await tester.pumpAndSettle();
    expect(service.saved.single.preview, '新的公告');
  });

  testWidgets('member cannot replace unreadable announcement', (tester) async {
    final service = _Service()
      ..loadFailure = const AnnouncementPendingDecryption();
    await tester.pumpWidget(
        CupertinoApp(home: GroupAnnouncementPage(service: service)));
    await tester.pumpAndSettle();
    expect(find.text('重新编写'), findsNothing);
  });

  testWidgets(
      'old document requests republish but remains readable after key arrival',
      (tester) async {
    final room = _Room()..keyPending = true;
    await tester.pumpWidget(CupertinoApp(
        home: GroupAnnouncementPage(
            service: MatrixGroupAnnouncementService(room))));
    await tester.pumpAndSettle();
    expect(find.text('公告格式异常，暂无法显示'), findsNothing);
    expect(find.text('公告无法解密，请联系群管理员重新发布'), findsOneWidget);
    room.keyPending = false;
    room.onSessionKeyReceived.add('recovered-session');
    await tester.pumpAndSettle();
    expect(find.text('成员可读'), findsOneWidget);
  });
  test('room session keys notify announcement listeners without room sync',
      () async {
    final room = _Room();
    final changed = MatrixGroupAnnouncementService(room).changes.first;
    room.onSessionKeyReceived.add('recovered-session');
    await changed.timeout(const Duration(seconds: 1));
  });
  testWidgets(
      'image key recovery reloads image without losing surrounding text',
      (tester) async {
    final service = _Service()
      ..pending = Future.value(const GroupAnnouncement([
        AnnouncementBlock.text('before'),
        AnnouncementBlock.image(r'$image'),
        AnnouncementBlock.text('after')
      ]))
      ..imageFailure = const AnnouncementPendingDecryption();
    await tester.pumpWidget(
        CupertinoApp(home: GroupAnnouncementPage(service: service)));
    await tester.pumpAndSettle();
    expect(find.text('before'), findsOneWidget);
    expect(find.text('图片加载失败，点击重试'), findsOneWidget);
    service.imageFailure = null;
    service.updates.add(null);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('after'), findsOneWidget);
  });
  for (final failure in [
    TimeoutException('timeout'),
    http.ClientException('offline'),
    MatrixException(http.Response('{"errcode":"M_UNKNOWN"}', 503))
  ]) {
    testWidgets('recoverable transport failure retries: $failure',
        (tester) async {
      final service = _Service()..loadFailure = failure;
      await tester.pumpWidget(
          CupertinoApp(home: GroupAnnouncementPage(service: service)));
      await tester.pumpAndSettle();
      expect(find.text('公告加载失败，请重试'), findsOneWidget);
      service.loadFailure = null;
      await tester.tap(find.text('公告加载失败，请重试'));
      await tester.pumpAndSettle();
      expect(find.text('暂无群公告'), findsOneWidget);
    });
  }
  for (final failure in [
    StateError('仅群成员可查看公告'),
    const FormatException('bad'),
    StateError('unexpected')
  ]) {
    testWidgets('non-network load failure is not a retry button: $failure',
        (tester) async {
      final service = _Service()..loadFailure = failure;
      await tester.pumpWidget(
          CupertinoApp(home: GroupAnnouncementPage(service: service)));
      await tester.pumpAndSettle();
      expect(find.text('公告加载失败，请重试'), findsNothing);
      expect(find.text('暂无群公告'), findsNothing);
      expect(find.byType(CupertinoButton), findsNothing);
      expect(
          find.textContaining(failure is FormatException
              ? '格式'
              : failure is StateError && failure.message == '仅群成员可查看公告'
                  ? '仅群成员'
                  : '暂不可用'),
          findsOneWidget);
      service.loadFailure = null;
      service.updates.add(null);
      await tester.pumpAndSettle();
      expect(find.text('暂无群公告'), findsOneWidget);
    });
  }
  for (final fail in [false, true]) {
    testWidgets(
        'old save completion cannot affect replacement service fail=$fail',
        (tester) async {
      final save = Completer<void>();
      final first = _Service()
        ..editable = true
        ..pendingSave = save.future;
      final current = ValueNotifier<GroupAnnouncementService>(first);
      await tester.pumpWidget(CupertinoApp(
          home: Builder(
              builder: (context) => CupertinoButton(
                  child: const Text('open'),
                  onPressed: () => Navigator.push(
                      context,
                      CupertinoPageRoute<void>(
                          builder: (_) =>
                              ValueListenableBuilder<GroupAnnouncementService>(
                                  valueListenable: current,
                                  builder: (_, service, __) =>
                                      GroupAnnouncementPage(
                                          service: service))))))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pump();
      await tester.tap(find.text('发布'));
      await tester.pump();
      current.value = _Service();
      await tester.pumpAndSettle();
      if (fail) {
        save.completeError(StateError('old failure'));
      } else {
        save.complete();
      }
      await tester.pumpAndSettle();
      expect(find.text('暂无群公告'), findsOneWidget);
      expect(find.textContaining('发布失败'), findsNothing);
    });
  }
  for (final stage in ['picker', 'length', 'bytes']) {
    testWidgets('old image $stage completion cannot affect replacement service',
        (tester) async {
      final gate = Completer<void>();
      final first = _Service()..editable = true;
      final current = ValueNotifier<GroupAnnouncementService>(first);
      final file = _DelayedFile(stage, gate.future);
      await tester.pumpWidget(CupertinoApp(
          home: ValueListenableBuilder<GroupAnnouncementService>(
              valueListenable: current,
              builder: (_, service, __) => GroupAnnouncementPage(
                  service: service,
                  pickImage: () async {
                    if (stage == 'picker') await gate.future;
                    return file;
                  }))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('group-announcement-add-image')));
      await tester.pump();
      current.value = _Service();
      await tester.pumpAndSettle();
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.text('暂无群公告'), findsOneWidget);
      expect(find.textContaining('图片读取失败'), findsNothing);
    });
  }
  testWidgets('member sees heading body publisher and publication date',
      (tester) async {
    final room = _Room();
    room.setState(Event(
        type: EventTypes.RoomMember,
        content: {'membership': 'join', 'displayname': '群主小林'},
        senderId: '@owner:test',
        room: room,
        eventId: r'$member',
        stateKey: '@owner:test',
        originServerTs: DateTime(2026)));
    await tester.pumpWidget(CupertinoApp(
        home: GroupAnnouncementPage(
            service: MatrixGroupAnnouncementService(room))));
    await tester.pumpAndSettle();
    expect(find.text('群公告'), findsOneWidget);
    expect(find.text('成员可读'), findsOneWidget);
    expect(find.textContaining('群主小林'), findsOneWidget);
    expect(find.textContaining('2026-01-01'), findsOneWidget);
    expect(find.text('编辑'), findsNothing);
  });
  test('ordinary member decrypts cached ciphertext without write authority',
      () async {
    final room = _Room();
    final service = MatrixGroupAnnouncementService(room);
    expect(service.canEdit, isFalse);
    expect((await service.load()).preview, '成员可读');
    expect(room.decryptions, 1);
    await expectLater(
        service.save(const GroupAnnouncement([])), throwsStateError);
  });
  test('departed member cannot read cached announcement', () async {
    final room = _Room()..membership = Membership.leave;
    room.setState(Event(
        type: groupAnnouncementStateType,
        content: {},
        senderId: '@owner:test',
        room: room,
        eventId: r'$clear',
        stateKey: '',
        originServerTs: DateTime(2027)));
    await expectLater(
        MatrixGroupAnnouncementService(room).load(), throwsStateError);
    expect(room.decryptions, 0);
  });
  testWidgets('member load failure retries and empty is a normal state',
      (tester) async {
    final service = _Service()..failure = true;
    await tester.pumpWidget(
        CupertinoApp(home: GroupAnnouncementPage(service: service)));
    await tester.pumpAndSettle();
    expect(find.text('公告加载失败，请重试'), findsOneWidget);
    service.failure = false;
    await tester.tap(find.text('公告加载失败，请重试'));
    await tester.pumpAndSettle();
    expect(find.text('暂无群公告'), findsOneWidget);
    expect(find.text('编辑'), findsNothing);
  });
  testWidgets('account switch clears old content and ignores old pending load',
      (tester) async {
    final first = _Service();
    final pending = Completer<GroupAnnouncement>();
    first.pending = pending.future;
    final second = _Service();
    await tester
        .pumpWidget(CupertinoApp(home: GroupAnnouncementPage(service: first)));
    await tester.pump();
    await tester
        .pumpWidget(CupertinoApp(home: GroupAnnouncementPage(service: second)));
    await tester.pump();
    pending.complete(
        const GroupAnnouncement([AnnouncementBlock.text('old account')]));
    await tester.pumpAndSettle();
    expect(find.text('old account'), findsNothing);
    expect(find.text('暂无群公告'), findsOneWidget);
  });
  testWidgets('role revocation during editing removes draft controls',
      (tester) async {
    final service = _Service()..editable = true;
    await tester.pumpWidget(
        CupertinoApp(home: GroupAnnouncementPage(service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pump();
    service.editable = false;
    service.updates.add(null);
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoTextField), findsNothing);
    expect(find.text('发布'), findsNothing);
    expect(find.byKey(const Key('group-announcement-add-image')), findsNothing);
  });
  testWidgets('banner clears account content when service changes',
      (tester) async {
    final first = _Service()
      ..pending = Future.value(
          const GroupAnnouncement([AnnouncementBlock.text('old account')]));
    await tester.pumpWidget(
        CupertinoApp(home: GroupAnnouncementBanner(service: first)));
    await tester.pumpAndSettle();
    expect(find.text('old account'), findsOneWidget);
    await tester.pumpWidget(
        CupertinoApp(home: GroupAnnouncementBanner(service: _Service())));
    await tester.pumpAndSettle();
    expect(find.text('old account'), findsNothing);
  });
}

class _Client extends Client {
  _Client() : super('member-announcement');
  @override
  String? get userID => '@member:test';
  late final crypto = _Encryption(this);
  @override
  Encryption? get encryption => crypto;
  @override
  bool get encryptionEnabled => true;
}

class _Encryption extends Encryption {
  _Encryption(Client client) : super(client: client);
  @override
  Event decryptRoomEventSync(String roomId, Event event) {
    final room = event.room as _Room;
    room.decryptions++;
    if (room.keyPending) {
      return Event(
          type: EventTypes.Encrypted,
          content: {
            'msgtype': MessageTypes.BadEncrypted,
            'can_request_session': true,
          },
          senderId: event.senderId,
          room: room,
          eventId: event.eventId,
          originServerTs: event.originServerTs,
          originalSource: event);
    }
    return Event(
        type: EventTypes.Message,
        content: const GroupAnnouncement([AnnouncementBlock.text('成员可读')])
            .toContent(),
        senderId: event.senderId,
        room: event.room,
        eventId: event.eventId,
        originServerTs: event.originServerTs,
        originalSource: event);
  }
}

class _Room extends Room {
  _Room() : super(id: '!room:test', client: _Client()) {
    setState(Event(
        type: groupAnnouncementStateType,
        content: {'event_id': r'$doc'},
        senderId: '@owner:test',
        room: this,
        eventId: r'$reference',
        stateKey: '',
        originServerTs: DateTime(2026)));
  }
  int decryptions = 0;
  bool keyPending = false;
  @override
  Future<Event?> getEventById(String eventID) async => Event(
      type: EventTypes.Encrypted,
      content: {
        'ciphertext': 'cached',
        'algorithm': AlgorithmTypes.megolmV1AesSha2,
        'session_id': 'session',
        'sender_key': 'sender'
      },
      senderId: '@owner:test',
      room: this,
      eventId: eventID,
      originServerTs: DateTime(2026));
}

class _Service implements GroupAnnouncementService {
  final saved = <GroupAnnouncement>[];
  final updates = StreamController<void>.broadcast();
  bool editable = false;
  bool failure = false;
  Object? loadFailure;
  Object? imageFailure;
  Future<GroupAnnouncement>? pending;
  Future<void>? pendingSave;
  @override
  bool get canEdit => editable;
  @override
  Stream<void> get changes => updates.stream;
  @override
  Future<GroupAnnouncement> load() async {
    if (failure) throw const SocketException('offline');
    if (loadFailure != null) throw loadFailure!;
    return pending ?? const GroupAnnouncement([]);
  }

  @override
  Future<void> save(GroupAnnouncement announcement) async {
    saved.add(announcement);
    await pendingSave;
  }

  @override
  Future<Uint8List> loadImage(String eventId) async {
    if (imageFailure != null) throw imageFailure!;
    return base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==');
  }

  @override
  Future<String> uploadImage(Uint8List bytes, String name) async => r'$image';
}

class _DelayedFile extends XFile {
  _DelayedFile(this.stage, this.gate) : super('draft.png');
  final String stage;
  final Future<void> gate;
  @override
  Future<int> length() async {
    if (stage == 'length') await gate;
    return 70;
  }

  @override
  Future<Uint8List> readAsBytes() async {
    if (stage == 'bytes') await gate;
    return base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==');
  }
}
