import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_recovery_service.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';

class _Client extends Client {
  _Client() : super('synthetic-camera-entry');
  @override
  String? get userID => '@self:test';
  late final room = _Room(this);
  @override
  Room? getRoomById(String id) => room;
}

class _Room extends Room {
  _Room(Client client) : super(id: '!camera:test', client: client);
  @override
  bool get isDirectChat => false;
  @override
  bool get canSendDefaultMessages => true;
  @override
  Membership get membership => Membership.join;
  @override
  Future<Timeline> getTimeline(
          {void Function(int)? onChange,
          void Function(int)? onRemove,
          void Function(int)? onInsert,
          void Function()? onNewEvent,
          void Function()? onUpdate,
          String? eventContextId}) async =>
      _Timeline();
}

class _Timeline extends Fake implements Timeline {
  @override
  List<Event> get events => [];
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'real RoomPage camera entry persists a separate source before sender admission',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late Directory root;
    late File original;
    late SqliteMediaOutboxStore store;
    await tester.runAsync(() async {
      sqfliteFfiInit();
      root = await Directory.systemTemp.createTemp('media-camera-entry-');
      original = await File('${root.path}/camera.jpg').writeAsBytes([1, 2, 3]);
      store = SqliteMediaOutboxStore(
          owner: const MediaOutboxOwner(
              accountId: '@self:test',
              homeserver: 'https://matrix.test',
              generation: 'db'),
          directory: () async => root,
          availableBytes: () async => 1 << 30,
          seal: (_, __) async {});
    });
    final entered = Completer<void>();
    final ack = Completer<String>();
    final service = MediaOutboxRecoveryService(
        store: store,
        isCurrentOwner: () => true,
        authorize: (_) async => true,
        send: (task, source) async {
          expect(
              (await store.byTxid(task.txid))!.stage, MediaOutboxStage.sending);
          expect(source.path, isNot(original.path));
          expect(await source.readAsBytes(), [1, 2, 3]);
          entered.complete();
          return ack.future;
        });
    MediaOutboxRecoveryService.shared = service;
    const camera = MethodChannel('plugins.flutter.io/image_picker');
    const recorder = MethodChannel('com.llfbandit.record/messages');
    messenger.setMockMethodCallHandler(camera, (_) async => original.path);
    messenger.setMockMethodCallHandler(recorder, (_) async => null);
    final client = _Client();
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.test'),
        suspendClient: (_) async {});
    final lease = await matrix.openRoomLease(client.room.id);
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.test'),
        sessionStore: SecureSessionStore(),
        client: MockClient((_) async => http.Response('{}', 404)));
    await tester.pumpWidget(CupertinoApp(
        home: RoomPage(
            api: api,
            roomLease: lease,
            roomName: 'Camera',
            onCreateGroup: () {})));
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-more')));
    await tester.pump();
    // Platform resolver and SQLite execute in the real async zone; pump only
    // drives the widget projection. Never await real I/O in FakeAsync.
    await tester.runAsync(() => tester.tap(find.text('拍摄')));
    await tester.pump();
    for (var i = 0; i < 100 && !entered.isCompleted; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(entered.isCompleted, isTrue);
    debugPrint('camera-fixture: sender entered');
    await tester.runAsync(() async {
      await original.delete();
    });
    await tester.pumpWidget(const SizedBox.shrink());
    debugPrint('camera-fixture: page disposed');
    ack.complete(r'$camera-sent');
    await tester.pump();
    for (var i = 0; i < 100; i++) {
      final pending = await tester.runAsync(() => store.pending());
      if (pending!.isEmpty) break;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(await tester.runAsync(() => store.pending()), isEmpty);
    debugPrint('camera-fixture: ACK persisted');
    MediaOutboxRecoveryService.shared = null;
    service.dispose();
    var closed = false;
    await tester.runAsync(() async {
      unawaited(service.close().then((_) => closed = true));
    });
    for (var i = 0; i < 100 && !closed; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(closed, isTrue);
    await tester.runAsync(() async {
      await root.delete(recursive: true);
    });
    messenger.setMockMethodCallHandler(camera, null);
    messenger.setMockMethodCallHandler(recorder, null);
    var suspended = false;
    await tester.runAsync(() async {
      unawaited(matrix.suspend().then((_) => suspended = true));
    });
    for (var i = 0; i < 100 && !suspended; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(suspended, isTrue);
    await tester.runAsync(client.dispose);
    debugPrint('camera-fixture: client closed');
  });
}
