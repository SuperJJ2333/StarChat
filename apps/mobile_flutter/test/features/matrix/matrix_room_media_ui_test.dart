import 'package:liuhetong_mobile/features/matrix/timeline_scroll_anchor.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';
import 'package:liuhetong_mobile/features/matrix/media_message_service.dart';
import 'package:liuhetong_mobile/features/matrix/content_addressed_media.dart';
import 'package:liuhetong_mobile/ui/chat/chat_forward_picker_page.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

final class _ForwardUiPaths extends PathProviderPlatform {
  _ForwardUiPaths(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

final class _RoomClient extends Client {
  _RoomClient({this.group = false}) : super('media-ui');
  final bool group;
  @override
  String? get userID => group ? '@self:matrix.test' : null;
  late final Room testRoom =
      group ? _GroupTestRoom(client: this) : _DirectTestRoom(client: this);

  @override
  Room? getRoomById(String roomId) =>
      roomId == testRoom.id ? testRoom : super.getRoomById(roomId);
}

final class _DirectTestRoom extends Room {
  _DirectTestRoom({required super.client}) : super(id: '!room:matrix.test');

  @override
  bool get isDirectChat => true;

  @override
  String? get directChatMatrixID => '@peer:matrix.test';
}

final class _GroupTimeline extends Fake implements Timeline {
  _GroupTimeline(this.events);
  @override
  final List<Event> events;
  @override
  bool get canRequestHistory => false;
  @override
  bool get isFragmentedTimeline => false;
  @override
  bool get canRequestFuture => false;
  @override
  Future<void> setReadMarker({String? eventId, bool? public}) async {}
  @override
  void cancelSubscriptions() {}
}

final class _GroupTestRoom extends Room {
  _GroupTestRoom({required super.client}) : super(id: '!room:matrix.test');

  List<Event>? overrideEvents;
  @override
  Future<Timeline> getTimeline(
          {void Function(int)? onChange,
          void Function(int)? onRemove,
          void Function(int)? onInsert,
          void Function()? onNewEvent,
          void Function()? onUpdate,
          String? eventContextId}) async =>
      _GroupTimeline(overrideEvents ??
          List.generate(
              40,
              (i) => Event(
                    room: this,
                    eventId: 'history-$i',
                    senderId: '@peer:matrix.test',
                    type: EventTypes.Message,
                    originServerTs: DateTime.utc(2026, 9, 10)
                        .subtract(Duration(minutes: i)),
                    content: {'msgtype': 'm.text', 'body': '历史消息 $i'},
                  )));
}

final class _ForwardUiClient extends Client {
  _ForwardUiClient({required http.Client httpClient})
      : super('forward-ui', httpClient: httpClient);

  @override
  String? get userID => '@self:matrix.test';
  @override
  String? get deviceID => 'DEVICE';
  @override
  String? get accessToken => 'access-token';
  @override
  Uri? get homeserver => Uri.parse('https://matrix.test');
  @override
  bool get fileEncryptionEnabled => true;
  @override
  bool get encryptionEnabled => true;
  @override
  Future<bool> authenticatedMediaSupported() async => true;

  late final _ForwardUiSourceRoom source = _ForwardUiSourceRoom(client: this);
  late final _ForwardTargetRoom target = _ForwardTargetRoom(client: this);

  @override
  List<Room> get rooms => [source, target];
  @override
  Room? getRoomById(String roomId) =>
      rooms.where((room) => room.id == roomId).firstOrNull;
}

final class _ForwardUiSourceRoom extends Room {
  _ForwardUiSourceRoom({required super.client})
      : super(id: '!forward-ui-source:matrix.test');

  List<Event> events = const [];
  void Function()? timelineUpdated;

  @override
  bool get encrypted => true;
  @override
  Membership get membership => Membership.join;
  @override
  bool get canSendDefaultMessages => true;
  @override
  Future<Timeline> getTimeline(
      {void Function(int)? onChange,
      void Function(int)? onRemove,
      void Function(int)? onInsert,
      void Function()? onNewEvent,
      void Function()? onUpdate,
      String? eventContextId}) async {
    timelineUpdated = onUpdate;
    return _GroupTimeline(events);
  }
}

final class _ForwardTargetRoom extends Room {
  _ForwardTargetRoom({required super.client})
      : super(id: '!target:matrix.test');

  final sentTxids = <String?>[];

  @override
  bool get encrypted => true;
  @override
  Membership get membership => Membership.join;
  @override
  bool get canSendDefaultMessages => true;
  @override
  String get name => '转发目标';

  @override
  Future<String?> sendFileEvent(
    MatrixFile file, {
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    int? shrinkImageMaxDimension,
    MatrixImageFile? thumbnail,
    Map<String, dynamic>? extraContent,
    String? threadRootEventId,
    String? threadLastEventId,
  }) async {
    sentTxids.add(txid);
    return r'$forwarded';
  }
}

final class _HeldForwardVideo extends Event {
  _HeldForwardVideo({
    required super.room,
    required MediaEnvelope envelope,
  }) : super(
          type: EventTypes.Message,
          eventId: r'$held-ui-video',
          senderId: '@peer:matrix.test',
          originServerTs: DateTime.utc(2026, 9, 12),
          originalSource: MatrixEvent(
            type: EventTypes.Encrypted,
            content: const {},
            senderId: '@peer:matrix.test',
            eventId: r'$held-ui-video',
            originServerTs: DateTime.utc(2026, 9, 12),
          ),
          content: {
            'msgtype': MessageTypes.Video,
            'body': 'held.mp4',
            'info': {'mimetype': 'video/mp4', 'size': 1},
            'file': {
              'url': 'mxc://old/held-ui-video',
              'v': 'v2',
              'key': {
                'alg': 'A256CTR',
                'ext': true,
                'k': envelope.encrypted.k,
                'key_ops': ['encrypt', 'decrypt'],
                'kty': 'oct',
              },
              'iv': envelope.encrypted.iv,
              'hashes': {'sha256': envelope.encrypted.sha256},
            },
            'chatflow_media': {
              'v': 1,
              'content_sha256': envelope.contentSha256
            },
          },
        );
}

final class _RecordingMediaSender implements RoomPickedMediaSender {
  final calls = <String>[];
  Completer<void>? pendingSend;
  bool disposed = false;
  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  Future<String> sendFile(String roomId) async {
    calls.add('file:$roomId');
    await pendingSend?.future;
    return r'$event';
  }

  @override
  Future<String> sendImage(String roomId) async {
    calls.add('image:$roomId');
    await pendingSend?.future;
    return r'$event';
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('room image action sends through its owned Matrix room lease',
      (tester) async {
    final client = _RoomClient();
    final matrix = MatrixSdkE2eeClient(
      client,
      homeserver: Uri.parse('https://matrix.test'),
    );
    final lease = await matrix.openRoomLease(client.testRoom.id);
    final sender = _RecordingMediaSender();
    MatrixEncryptedMediaGateway? capturedGateway;
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.test'),
      sessionStore: SecureSessionStore(),
      client: MockClient((_) async => http.Response('{}', 404)),
    );

    await tester.pumpWidget(CupertinoApp(
      home: RoomPage(
        api: api,
        roomLease: lease,
        roomName: 'Encrypted room',
        onCreateGroup: () {},
        mediaSenderFactory: (gateway) {
          capturedGateway = gateway;
          return sender;
        },
      ),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-more')));
    await tester.pump();
    await tester.tap(find.text('图片'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(capturedGateway, same(lease));
    expect(sender.calls, ['image:!room:matrix.test']);

    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
  });
  testWidgets(
      'pending video file upload keeps typing, scrolling and menus interactive',
      (tester) async {
    final client = _RoomClient(group: true);
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.test'));
    final lease = await matrix.openRoomLease(client.testRoom.id);
    final pending = Completer<void>();
    final sender = _RecordingMediaSender()..pendingSend = pending;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.test'),
        sessionStore: SecureSessionStore(),
        client: MockClient((_) async => http.Response('{}', 404)));
    await tester.pumpWidget(CupertinoApp(
        home: RoomPage(
            api: api,
            roomLease: lease,
            roomName: 'Upload room',
            onCreateGroup: () {},
            mediaSenderFactory: (_) => sender)));
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-more')));
    await tester.pump();
    await tester.tap(find.text('文件'));
    await tester.pump();
    expect(sender.calls, ['file:!room:matrix.test']);
    expect(pending.isCompleted, isFalse);
    await tester.enterText(find.byType(CupertinoTextField).first, '继续输入');
    await tester.pump();
    expect(find.text('继续输入'), findsOneWidget);
    final timeline = find.byType(AnchoredTimelineList).first;
    final position = tester
        .state<ScrollableState>(find
            .descendant(of: timeline, matching: find.byType(Scrollable))
            .first)
        .position;
    final before = position.pixels;
    await tester.drag(timeline, const Offset(0, 300));
    expect(position.pixels, greaterThan(before));
    await tester.pump();
    await tester.enterText(find.byType(CupertinoTextField).first, '');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-more')));
    await tester.pump();
    expect(find.text('图片'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
    expect(pending.isCompleted, isFalse);
    expect(sender.disposed, isFalse);
    pending.complete();
    await tester.pump();
    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
  testWidgets('room lease cancellation drains an in-flight picked media action',
      (tester) async {
    final client = _RoomClient();
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.test'));
    final lease = await matrix.openRoomLease(client.testRoom.id);
    final pending = Completer<void>();
    final sender = _RecordingMediaSender()..pendingSend = pending;
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.test'),
      sessionStore: SecureSessionStore(),
      client: MockClient((_) async => http.Response('{}', 404)),
    );
    await tester.pumpWidget(CupertinoApp(
        home: RoomPage(
      api: api,
      roomLease: lease,
      roomName: 'Encrypted room',
      onCreateGroup: () {},
      mediaSenderFactory: (_) => sender,
    )));
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-more')));
    await tester.pump();
    await tester.tap(find.text('图片'));
    await tester.pump();
    expect(sender.calls, ['image:!room:matrix.test']);
    var canceled = false;
    final cancellation = lease.cancel().then((_) => canceled = true);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(canceled, isFalse);
    expect(sender.disposed, isFalse);
    pending.complete();
    await tester.pump();
    await cancellation;
    expect(sender.disposed, isTrue);
    expect(canceled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'RoomPage forwards held encrypted media through the owner after its source lease closes',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final previousPaths = PathProviderPlatform.instance;
    final cacheRoot = (await tester.runAsync(() async {
      final artifactRoot = Directory(
          '../../docs/verification/artifacts/2026-09-12/media-interactions/d3-room-page-ui');
      await artifactRoot.create(recursive: true);
      return artifactRoot.createTemp('cache-');
    }))!;
    PathProviderPlatform.instance = _ForwardUiPaths(cacheRoot.absolute.path);
    addTearDown(() async {
      PathProviderPlatform.instance = previousPaths;
      try {
        await cacheRoot.delete(recursive: true);
      } on FileSystemException {
        // The owner/cache can still be closing a stream; this isolated test
        // directory remains under verification artifacts for later cleanup.
      }
    });
    final envelope = (await tester
        .runAsync(() => MediaEnvelope.forBytes(Uint8List.fromList([7]))))!;
    final downloadStarted = Completer<void>();
    final releaseDownload = Completer<http.Response>();
    final client = _ForwardUiClient(
      httpClient: MockClient((request) {
        if (request.url.path.contains('/download/')) {
          if (!downloadStarted.isCompleted) downloadStarted.complete();
          return releaseDownload.future;
        }
        return Future.value(http.Response('{}', 200));
      }),
    );
    final source = client.source;
    final target = client.target;
    source.events = [
      _HeldForwardVideo(room: source, envelope: envelope),
    ];
    final matrix = MatrixSdkE2eeClient(
      client,
      homeserver: Uri.parse('https://matrix.test'),
      readContinuityMetadata: (active) async => MatrixClientContinuityMetadata(
        isLoggedIn: true,
        userId: active.userID,
        deviceId: active.deviceID,
        ed25519Fingerprint: 'fixture',
        databaseGeneration: 'fixture',
      ),
    );
    final lease = await matrix.openRoomLease(source.id);
    expect(
      (await lease.forwardingDestinations()).map((room) => room.id),
      contains(target.id),
    );
    // The production page subscribes to its room timeline before forwarding.
    // Establish the same lease-owned snapshot explicitly so the long-press
    // action freezes the actual SDK Event rather than a widget-only model.
    await lease.openRoomTimeline(onUpdate: () {});
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.test'),
      sessionStore: SecureSessionStore(),
      client: MockClient((_) async => http.Response('{}', 404)),
    );

    await tester.pumpWidget(CupertinoApp(
      home: RoomPage(
        api: api,
        roomLease: lease,
        roomName: 'Source',
        onCreateGroup: () {},
      ),
    ));
    await tester.pump();
    source.timelineUpdated?.call();
    final video = find.byKey(const ValueKey('video-message-\$held-ui-video'));
    for (var frame = 0; frame < 20 && video.evaluate().isEmpty; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(video, findsOneWidget);
    await tester.longPress(video);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tap(find.byKey(const Key('message-action-forward')));
    for (var frame = 0;
        frame < 20 && find.byType(ChatForwardPickerPage).evaluate().isEmpty;
        frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(ChatForwardPickerPage), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    final targetRow =
        find.byKey(const Key('forward-chat-!target:matrix.test')).hitTestable();
    expect(targetRow, findsOneWidget);
    await tester.tap(targetRow);
    final confirmation = find.byKey(const Key('forward-confirm-send'));
    for (var frame = 0;
        frame < 20 && confirmation.hitTestable().evaluate().isEmpty;
        frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(confirmation.hitTestable(), findsOneWidget);
    await tester.tap(confirmation);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (var tick = 0;
        tick < 100 &&
            find
                .byKey(const Key('forward-confirmation-sheet'))
                .evaluate()
                .isNotEmpty;
        tick++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byKey(const Key('forward-confirmation-sheet')), findsNothing,
        reason: 'The picker closes after local owner admission.');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (var tick = 0;
        tick < 100 && find.byType(ChatForwardPickerPage).evaluate().isNotEmpty;
        tick++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byType(ChatForwardPickerPage), findsNothing,
        reason: 'No selection route remains after local owner admission.');
    for (var tick = 0; tick < 100 && !downloadStarted.isCompleted; tick++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(downloadStarted.isCompleted, isTrue,
        reason: 'The accepted owner job must begin its real attachment read.');
    expect(matrix.outgoingWork.itemsForRoom(target.id), hasLength(1));

    await tester.enterText(
        find.byKey(const Key('composer-input')), 'still usable');
    await tester.pump();
    expect(find.text('still usable'), findsOneWidget);

    lease.revokeNow();
    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    releaseDownload.complete(http.Response.bytes(envelope.encrypted.data, 200));
    var drained = false;
    unawaited(matrix.outgoingWork.drain().then((_) => drained = true));
    for (var tick = 0; tick < 100 && !drained; tick++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(drained, isTrue);
    expect(target.sentTxids, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
