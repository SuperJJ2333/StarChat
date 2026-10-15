import 'dart:async';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:liuhetong_mobile/features/matrix/image_picker_page.dart';
import 'package:liuhetong_mobile/features/matrix/room_image_preview_cache.dart';
import '../media/media_test_fixtures.dart';
import 'package:liuhetong_mobile/ui/chat/contain_image_bubble.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_video_message.dart';
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

var _fixtureSequence = 0;

class _Client extends Client {
  final fixtureId = ++_fixtureSequence;
  _Client()
      : super('synthetic-camera-entry',
            httpClient: MockClient((_) async => http.Response(
                '{"errcode":"M_NOT_FOUND","error":"synthetic"}', 404))) {
    homeserver = Uri.parse('https://matrix.test');
  }
  @override
  String? get userID => '@self-$fixtureId:test';
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

final class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

Future<void> _tick(WidgetTester tester, [int count = 20]) async {
  for (var i = 0; i < count; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 10));
  }
}

Future<T> _io<T>(WidgetTester tester, Future<T> Function() action) async {
  var done = false;
  T? result;
  Object? failure;
  await tester.runAsync(() async {
    unawaited(action().then((value) {
      result = value;
      done = true;
    }, onError: (Object error) {
      failure = error;
      done = true;
    }));
  });
  for (var i = 0; i < 100 && !done; i++) {
    await _tick(tester, 1);
  }
  expect(done, isTrue,
      reason: 'I/O must settle while widget microtasks advance');
  if (failure != null) throw failure!;
  return result as T;
}

final class _Harness {
  late Directory root;
  late SqliteMediaOutboxStore store;
  late MediaOutboxRecoveryService service;
  late MatrixSdkE2eeClient matrix;
  late MatrixRoomLease lease;
  late BusinessApiClient api;
  final client = _Client();
  final ack = Completer<String>();
  final sent = <String>[];
  final paths = PathProviderPlatform.instance;
  bool current = true;
  bool failAdmission = false;
  int admissionsToReject = 0;
  Future<void> start(WidgetTester tester, {bool restored = false}) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.record/messages'),
            (_) async => null);
    await tester.runAsync(() async {
      sqfliteFfiInit();
      final fixtures = Directory('../../docs/verification/t3').absolute;
      await fixtures.create(recursive: true);
      final created = await fixtures.createTemp('p');
      root = Directory(await created.resolveSymbolicLinks());
      PathProviderPlatform.instance = _Paths(root.path);
      store = SqliteMediaOutboxStore(
          owner: MediaOutboxOwner(
              accountId: client.userID!,
              homeserver: 'https://matrix.test',
              generation: 'db'),
          factory: databaseFactoryFfiNoIsolate,
          directory: () async => root,
          availableBytes: () async {
            if (failAdmission || admissionsToReject > 0) {
              if (admissionsToReject > 0) admissionsToReject--;
              throw const MediaOutboxException('storage-unavailable');
            }
            return 1 << 30;
          },
          seal: (_, __) async {});
      if (restored) {
        await store.persistBytes(
            txid: 'restored-image',
            roomId: '!camera:test',
            bytes: Uint8List.fromList([1]),
            mimeType: 'image/jpeg',
            filename: 'image');
        await store.setStage('restored-image', MediaOutboxStage.failed,
            failure: 'source-missing');
      }
    });
    service = MediaOutboxRecoveryService(
        store: store,
        isCurrentOwner: () => current,
        authorize: (_) async => true,
        send: (task, source) async {
          sent.add(task.txid);
          await ack.future;
          return 'event-${task.txid}';
        });
    MediaOutboxRecoveryService.shared = service;
    matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.test'),
        suspendClient: (_) async {});
    matrix.bindDurableMediaOutbox(service);
    lease = await matrix.openRoomLease(client.room.id);
    api = BusinessApiClient(
        baseUri: Uri.parse('https://business.test'),
        sessionStore: SecureSessionStore(),
        client: MockClient((_) async => http.Response('{}', 404)));
    await show(tester);
  }

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(CupertinoApp(
        home: RoomPage(
            api: api,
            roomLease: lease,
            roomName: 'Gallery',
            onCreateGroup: () {})));
    await _tick(tester);
  }

  Future<void> select(WidgetTester tester, List<GalleryPhoto> photos) async {
    await tester.tap(find.byKey(const Key('composer-more')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-more-image')));
    await _tick(tester, 5);
    final picker = find.byType(ImagePickerPage);
    expect(picker, findsOneWidget);
    Navigator.of(tester.element(picker))
        .pop((photos: photos, original: false, flash: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> close(WidgetTester tester) async {
    if (!ack.isCompleted) ack.complete(r'$event');
    await _tick(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await _tick(tester);
    MediaOutboxRecoveryService.shared = null;
    var suspended = false;
    await tester.runAsync(() async {
      unawaited(matrix.suspend().then((_) => suspended = true));
    });
    for (var i = 0; i < 500 && !suspended; i++) {
      await _tick(tester, 1);
    }
    expect(suspended, isTrue);
    service.dispose();
    var closed = false;
    await tester.runAsync(() async {
      unawaited(() async {
        await store.close();
        await client.dispose();
        await root.delete(recursive: true);
        closed = true;
      }());
    });
    for (var i = 0; i < 100 && !closed; i++) {
      await _tick(tester, 1);
    }
    expect(closed, isTrue);
    PathProviderPlatform.instance = paths;
    RoomImagePreviewCache.clearSessionMemory();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.record/messages'), null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('restored durable image is an actionable timeline row',
      (tester) async {
    final h = _Harness();
    await h.start(tester, restored: true);
    expect(find.byKey(const ValueKey('image-restored-image')), findsOneWidget);
    expect(find.textContaining('请重新选择'), findsOneWidget);
    expect(find.text('取消此附件'), findsOneWidget);
    expect(find.text('待发附件 1'), findsNothing);
    await tester.tap(find.text('取消此附件'));
    await _tick(tester);
    expect((await _io(tester, () => h.store.byTxid('restored-image')))!.stage,
        MediaOutboxStage.canceled);
    expect(find.byKey(const ValueKey('image-restored-image')), findsNothing);
    await h.close(tester);
  });

  testWidgets(
      'all image previews paint before delayed originals; cancellation cannot resurrect a send',
      (tester) async {
    final h = _Harness();
    await h.start(tester);
    final original = Completer<Uint8List>();
    final preview = mediaTestPng();
    final photos = [
      for (var i = 0; i < 3; i++)
        GalleryPhoto(
            id: 'image-$i',
            thumbnail: preview,
            originalBytes: () => original.future,
            compressedBytes: () => original.future)
    ];
    await h.select(tester, photos);
    final bubbles = tester
        .widgetList<ContainImageBubble>(find.byType(ContainImageBubble))
        .toList();
    expect(bubbles, hasLength(3));
    expect(bubbles.map((b) => b.initialBytes),
        everyElement(orderedEquals(preview)));
    expect(h.sent, isEmpty);
    await _tick(tester);
    final tasks = (await _io(tester, h.store.pending));
    expect(tasks, hasLength(3));
    expect(tasks.map((t) => t.stage), everyElement(MediaOutboxStage.preparing));
    await _io(tester, () => h.service.cancel(tasks.first.txid));
    original.complete(preview);
    await _tick(tester, 40);
    expect(h.sent, isNot(contains(tasks.first.txid)));
    expect(find.byKey(ValueKey('image-${tasks.first.txid}')), findsNothing);
    await h.close(tester);
  });

  for (final lateFailure in [false, true]) {
    testWidgets(
        'gallery video poster paints while cloud source waits and original resolves once; late failure=$lateFailure',
        (tester) async {
      final h = _Harness();
      await h.start(tester);
      final originals = List.generate(3, (_) => Completer<File?>());
      var reads = 0;
      var activeResolvers = 0;
      var peakResolvers = 0;
      final preview = mediaTestPng();
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final photos = [
        for (var i = 0; i < 3; i++)
          GalleryPhoto(
              id: 'video-$i',
              thumbnail: preview,
              isVideo: true,
              mimeType: 'video/mp4',
              originalBytes: () async => Uint8List(0),
              compressedBytes: () async => Uint8List(0),
              localVideoFile: () async {
                reads++;
                activeResolvers++;
                if (activeResolvers > peakResolvers) {
                  peakResolvers = activeResolvers;
                }
                try {
                  return await originals[i].future;
                } finally {
                  activeResolvers--;
                }
              })
      ];
      await h.select(tester, photos);
      expect(find.byType(VideoMessageCard), findsNWidgets(3));
      expect(
          tester
              .widgetList<VideoMessageCard>(find.byType(VideoMessageCard))
              .map((v) => v.initialPosterBytes),
          everyElement(orderedEquals(preview)));
      await _tick(tester);
      expect(reads, 2,
          reason: 'only two preparations resolve originals concurrently');
      final tasks = (await _io(tester, h.store.pending));
      expect(tasks, hasLength(3));
      expect(
          tasks.map((t) => t.stage), everyElement(MediaOutboxStage.preparing));
      final source = await tester.runAsync(
          () => File('${h.root.path}/synthetic.mp4').writeAsBytes([1, 2, 3]));
      originals[1].complete(source);
      originals[2].complete(source);
      await _tick(tester, 30);
      expect(activeResolvers, 1);
      expect(h.sent, isEmpty);
      await _io(tester, () => h.service.cancel(tasks.first.txid));
      h.ack.complete('ack');
      await _tick(tester, 40);
      expect(h.sent, isNot(contains(tasks.first.txid)));
      expect(h.sent, unorderedEquals(tasks.skip(1).map((task) => task.txid)));
      expect(reads, 3);
      expect(activeResolvers, 1,
          reason: 'logical cancellation must not release physical preparation');
      expect(peakResolvers, 2);
      if (lateFailure) {
        originals[0]
            .completeError(StateError('synthetic canceled cloud source'));
      } else {
        originals[0].complete(source);
      }
      await _tick(tester, 30);
      expect(activeResolvers, 0);
      final canceled =
          (await _io(tester, () => h.store.byTxid(tasks.first.txid)))!;
      expect(canceled.stage, MediaOutboxStage.canceled);
      expect(canceled.digest, isNull);
      expect(canceled.length, 0);
      expect(h.sent, unorderedEquals(tasks.skip(1).map((task) => task.txid)));
      expect(
          await tester.runAsync(() async =>
              (await h.root.list(recursive: true).toList())
                  .whereType<File>()
                  .where((file) => file.path.endsWith('.part'))
                  .length),
          0);
      await h.close(tester);
    });
  }

  testWidgets(
      'retired account settles logical video admission without releasing its live resolver',
      (tester) async {
    final h = _Harness();
    await h.start(tester);
    final original = Completer<File?>();
    var resolving = false;
    var settled = false;
    final request = MatrixOutgoingVideoFileRequest(
        jobId: 'retired-source',
        targetRoomIds: [h.client.room.id],
        video: MatrixOutgoingVideoFile(
            id: 'retired-source',
            deleteSourceWhenDone: false,
            filename: 'video.mp4',
            body: '[视频消息]',
            resolveSource: () async {
              resolving = true;
              try {
                return await original.future;
              } finally {
                resolving = false;
              }
            }));
    unawaited(h.lease.enqueueVideoFiles(requests: [request]).then<void>(
        (_) => settled = true,
        onError: (Object _) => settled = true));
    await _tick(tester);
    expect(resolving, isTrue);
    final task = (await _io(tester, h.store.pending)).single;
    h.current = false;
    h.service.suspend();
    await _tick(tester);
    expect(settled, isTrue);
    expect(resolving, isTrue);
    expect(h.sent, isEmpty);
    final source = await tester.runAsync(
        () => File('${h.root.path}/retired.mp4').writeAsBytes([1, 2, 3]));
    original.complete(source);
    await _tick(tester);
    final retired = (await _io(tester, () => h.store.byTxid(task.txid)))!;
    expect(retired.stage, MediaOutboxStage.failed);
    expect(retired.digest, isNull);
    expect(retired.failure, 'owner-unavailable');
    expect(resolving, isFalse);
    expect(h.sent, isEmpty);
    await h.close(tester);
  });
  testWidgets(
      'missing cloud thumbnail is semantic and account retirement rejects late preview and original',
      (tester) async {
    final h = _Harness();
    await h.start(tester);
    final original = Completer<Uint8List>();
    final thumbnail = Completer<Uint8List?>();
    await h.select(tester, [
      GalleryPhoto(
          id: 'cloud',
          thumbnail: Uint8List(0),
          loadThumbnail: () => thumbnail.future,
          originalBytes: () => original.future,
          compressedBytes: () => original.future)
    ]);
    await _tick(tester);
    expect(find.byType(ContainImageBubble), findsOneWidget);
    expect(find.text('正在获取附件'), findsWidgets);
    expect(
        tester
            .widget<ContainImageBubble>(find.byType(ContainImageBubble))
            .initialBytes,
        isNull);
    h.current = false;
    h.service.suspend();
    MediaOutboxRecoveryService.shared = null;
    thumbnail.complete(mediaTestPng());
    original.complete(mediaTestPng());
    await _tick(tester, 30);
    expect(find.byType(ContainImageBubble), findsNothing);
    expect(h.sent, isEmpty);
    await h.close(tester);
  });

  testWidgets(
      'route disposal keeps accepted preparation and reentry restores encrypted preview',
      (tester) async {
    final h = _Harness();
    await h.start(tester);
    final original = Completer<Uint8List>();
    final preview = mediaTestPng();
    await h.select(tester, [
      GalleryPhoto(
          id: 'navigate',
          thumbnail: preview,
          originalBytes: () => original.future,
          compressedBytes: () => original.future)
    ]);
    await _tick(tester, 30);
    final task = (await _io(tester, h.store.pending)).single;

    await tester.pumpWidget(const SizedBox.shrink());
    await _tick(tester);
    original.complete(preview);
    await _tick(tester, 30);
    expect(h.sent, [task.txid]);
    expect((await _io(tester, () => h.store.byTxid(task.txid)))!.stage,
        MediaOutboxStage.sending);
    RoomImagePreviewCache.clearSessionMemory();
    h.lease = await _io(tester, () => h.matrix.openRoomLease(h.client.room.id));
    await h.show(tester);
    expect(find.byKey(ValueKey('image-${task.txid}')), findsOneWidget);
    final bubble =
        tester.widget<ContainImageBubble>(find.byType(ContainImageBubble));
    expect(await _io(tester, bubble.loadCached!), orderedEquals(preview));
    h.ack.complete('ack');
    await _tick(tester, 30);
    expect(find.byKey(ValueKey('image-${task.txid}')), findsOneWidget);
    expect(
        tester
            .widget<ContainImageBubble>(find.byType(ContainImageBubble))
            .initialBytes,
        orderedEquals(preview));
    await h.close(tester);
  });

  testWidgets('pre-insertion failure exposes working reselect and cancel',
      (tester) async {
    final h = _Harness();
    await h.start(tester);
    h.failAdmission = true;
    final preview = mediaTestPng();
    await h.select(tester, [
      GalleryPhoto(
          id: 'rejected',
          thumbnail: preview,
          originalBytes: () async => preview,
          compressedBytes: () async => preview)
    ]);
    await _tick(tester);
    expect(await _io(tester, h.store.pending), isEmpty);
    expect(find.text('重新选择附件'), findsOneWidget);
    expect(find.text('取消此附件'), findsOneWidget);
    await tester.tap(find.text('重新选择附件'));
    await _tick(tester);
    expect(find.byType(ImagePickerPage), findsOneWidget);
    Navigator.of(tester.element(find.byType(ImagePickerPage))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('取消此附件'));
    await _tick(tester);
    expect(find.byType(ContainImageBubble), findsNothing);
    expect(h.sent, isEmpty);
    await h.close(tester);
  });

  testWidgets(
      'task phase updates and submitted cancel remain truthful without message changes',
      (tester) async {
    final h = _Harness();
    await h.start(tester);
    final original = Completer<Uint8List>();
    await h.select(tester, [
      GalleryPhoto(
          id: 'phases',
          thumbnail: mediaTestPng(),
          originalBytes: () => original.future,
          compressedBytes: () => original.future)
    ]);
    await _tick(tester);
    final task = (await _io(tester, h.store.pending)).single;
    expect(find.text('正在获取附件'), findsOneWidget);
    await _io(
        tester, () => h.store.setStage(task.txid, MediaOutboxStage.queued));
    await _tick(tester);
    expect(find.text('等待上传'), findsOneWidget);
    await _io(
        tester, () => h.store.setStage(task.txid, MediaOutboxStage.sending));
    await _tick(tester);
    expect(find.text('正在上传并等待确认'), findsOneWidget);
    await tester.tap(find.text('取消此附件'));
    await _tick(tester);
    expect(find.text('已停止后续重试；已经提交的消息仍可能送达'), findsOneWidget);
    original.complete(mediaTestPng());
    await _tick(tester);
    expect(h.sent, isEmpty);
    await h.close(tester);
  });

  testWidgets('late selected thumbnail repaints while original remains blocked',
      (tester) async {
    final h = _Harness();
    await h.start(tester);
    final original = Completer<Uint8List>();
    final thumbnail = Completer<Uint8List?>();
    await h.select(tester, [
      GalleryPhoto(
          id: 'late-preview',
          thumbnail: Uint8List(0),
          loadThumbnail: () => thumbnail.future,
          originalBytes: () => original.future,
          compressedBytes: () => original.future)
    ]);
    await _tick(tester);
    expect(
        tester
            .widget<ContainImageBubble>(find.byType(ContainImageBubble))
            .initialBytes,
        isNull);
    thumbnail.complete(mediaTestPng());
    await _tick(tester);
    expect(
        tester
            .widget<ContainImageBubble>(find.byType(ContainImageBubble))
            .initialBytes,
        orderedEquals(mediaTestPng()));
    expect(h.sent, isEmpty);
    final task = (await _io(tester, h.store.pending)).single;
    await _io(tester, () => h.service.cancel(task.txid));
    original.complete(mediaTestPng());
    await h.close(tester);
  });

  testWidgets(
      'one video rejected before insertion stays actionable while siblings send',
      (tester) async {
    final h = _Harness();
    await h.start(tester);
    h.admissionsToReject = 1;
    final source = await tester.runAsync(
        () => File('${h.root.path}/accepted.mp4').writeAsBytes([1, 2, 3]));
    final original = Completer<File?>();
    var reads = 0;
    await h.select(tester, [
      for (var i = 0; i < 3; i++)
        GalleryPhoto(
            id: 'partial-admission-$i',
            thumbnail: mediaTestPng(),
            isVideo: true,
            mimeType: 'video/mp4',
            originalBytes: () async => Uint8List(0),
            compressedBytes: () async => Uint8List(0),
            localVideoFile: () {
              reads++;
              return original.future;
            })
    ]);
    await _tick(tester);
    final accepted = await _io(tester, h.store.pending);
    expect(accepted, hasLength(2));
    expect(reads, 2);
    original.complete(source);
    h.ack.complete('ack');
    await _tick(tester, 50);
    expect(h.sent, unorderedEquals(accepted.map((task) => task.txid)));
    expect(find.text('重新选择附件'), findsOneWidget);
    expect(find.text('取消此附件'), findsOneWidget);
    await tester.ensureVisible(find.text('取消此附件'));
    await tester.tap(find.text('取消此附件'));
    await _tick(tester);
    expect(find.text('重新选择附件'), findsNothing);
    expect(h.sent, hasLength(2));
    await h.close(tester);
  });

  testWidgets('one missing video original does not reject its valid siblings',
      (tester) async {
    final h = _Harness();
    await h.start(tester);
    final source = await tester.runAsync(
        () => File('${h.root.path}/valid.mp4').writeAsBytes([1, 2, 3]));
    final originals = List.generate(3, (_) => Completer<File?>());
    await h.select(tester, [
      for (var i = 0; i < 3; i++)
        GalleryPhoto(
            id: 'independent-$i',
            thumbnail: mediaTestPng(),
            isVideo: true,
            mimeType: 'video/mp4',
            originalBytes: () async => Uint8List(0),
            compressedBytes: () async => Uint8List(0),
            localVideoFile: () => originals[i].future)
    ]);
    await _tick(tester);
    final tasks = await _io(tester, h.store.pending);
    expect(tasks, hasLength(3));
    originals[0].complete(null);
    originals[1].complete(source);
    originals[2].complete(source);
    h.ack.complete('ack');
    await _tick(tester, 50);
    final recovered = await _io(tester,
        () => Future.wait(tasks.map((task) => h.store.byTxid(task.txid))));
    final failed = recovered
        .where((task) => task!.stage == MediaOutboxStage.failed)
        .toList();
    expect(failed, hasLength(1));
    expect(failed.single!.failure, isNot('admission-rejected'));
    expect(
        h.sent,
        unorderedEquals(recovered
            .where((task) => task!.stage == MediaOutboxStage.sent)
            .map((task) => task!.txid)));
    expect(h.sent, hasLength(2));
    expect(find.text('重试此附件'), findsOneWidget);
    await h.close(tester);
  });
}
