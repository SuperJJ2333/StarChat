import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/app_home.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_recovery_service.dart';
import 'package:liuhetong_mobile/core/outbox/persistent_outbox_manager.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_sync_watchdog.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/media_index.dart';
import 'package:liuhetong_mobile/ui/theme/theme_controller.dart';

import 'core/session_store_test.dart' show MemorySecureKeyValueStore;

// This fixture mounts the real composition root and reads its real secure
// binding. Native filesystem policy/codec and Matrix room transport are doubles;
// it does not claim to exercise Android storage or a real homeserver.
final class _ThemeStore implements ThemePreferenceStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async {}
}

final class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

final class _Client extends Client {
  _Client(this.account)
      : super('synthetic-home-media',
            httpClient: MockClient((_) async => http.Response('{}', 404))) {
    accessToken = 'synthetic-fixture-token';
    homeserver = Uri.parse('https://matrix.test');
  }
  String account;
  @override
  String? get userID => account;
  @override
  String? get deviceID => 'SYNTHETIC';
  @override
  bool get fileEncryptionEnabled => true;
  late final room = _Room(this);
  @override
  Room? getRoomById(String id) => id == room.id ? room : null;
  @override
  Future<MediaConfig> getConfig() async => MediaConfig(mUploadSize: 1000000);
  @override
  Future<void> abortSync() async {}
}

final class _Room extends Room {
  _Room(Client client) : super(id: '!synthetic:test', client: client);
  final sentTypes = <String>[];
  @override
  bool get encrypted => true;
  @override
  Membership get membership => Membership.join;
  @override
  bool get canSendDefaultMessages => true;
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
    sentTypes.add(file.msgType);
    return '\$synthetic-${sentTypes.length}';
  }
}

final class _Target implements SyncWatchdogTarget {
  @override
  Stream<SyncStatusUpdate> get syncStatus => const Stream.empty();
  @override
  Future<void> oneShotSync() async {}
  @override
  Future<void> abortSync() async {}
  @override
  set backgroundSync(bool value) {}
}

Future<T> settle<T>(WidgetTester tester, Future<T> operation) async {
  var done = false;
  operation.then<void>((_) => done = true,
      onError: (Object _, StackTrace __) => done = true);
  final deadline = Stopwatch()..start();
  while (!done && deadline.elapsed < const Duration(seconds: 10)) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(done, isTrue, reason: 'real IO and Flutter microtasks must settle');
  return operation;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channels = <String>{};

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    MediaOutboxRecoveryService.shared = null;
    sqfliteFfiInit();
    // Select the real desktop SQLite worker before the production factory is
    // opened. Windows has no packaged Android/iOS SQLCipher library; its native
    // selection is covered by separate device gates, not this composition test.
    final desktop = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await desktop.close();
    final fixtures = await Directory(
            '../../docs/verification/artifacts/2026-10-12/media-send-startup/fixtures')
        .create(recursive: true);
    root = await fixtures.createTemp('home-');
    await File('${root.path}/selected.mp4').writeAsBytes([1, 2, 3, 4]);
    PathProviderPlatform.instance = _Paths(root.absolute.path);
    for (final name in [
      'native_call',
      'chatflow/call',
      'chatflow/native_messages',
      'FlutterWebRTC.Event',
      'xyz.luan/audioplayers.global/events',
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers',
      'com.llfbandit.record/messages',
      'video_compress',
      'chatflow/media_storage',
    ]) {
      channels.add(name);
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        if (name == 'xyz.luan/audioplayers' && call.method == 'create') {
          final event =
              'xyz.luan/audioplayers/events/${(call.arguments as Map)['playerId']}';
          channels.add(event);
          messenger.setMockMethodCallHandler(
              MethodChannel(event), (_) async => null);
        }
        if (name == 'chatflow/media_storage') {
          return {
            'path': root.absolute.path,
            'availableBytes': 1 << 30,
            'protected': true,
            'backupExcluded': true,
          };
        }
        if (name == 'video_compress' && call.method == 'compressVideo') {
          final output = await File('${root.path}/transcoded.mp4')
              .writeAsBytes([9, 8, 7, 6]);
          return jsonEncode({
            'path': output.path,
            'duration': 500,
            'width': 1,
            'height': 1,
          });
        }
        if (name == 'chatflow/native_messages') return true;
        return null;
      });
    }
  });
  tearDown(() async {
    for (final name in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
    channels.clear();
    MediaOutboxRecoveryService.shared = null;
    // AppHome also owns process-wide optional metadata stores. Keep this
    // synthetic diagnostic fixture under verification until the test worker
    // exits rather than deleting a directory with their open Windows handles.
  });

  Future<(MatrixSdkE2eeClient, _Client)> mount(WidgetTester tester,
      {MemorySecureKeyValueStore? storage}) async {
    final secure = SecureSessionStore(storage ?? MemorySecureKeyValueStore());
    await secure.saveMatrixBinding(MatrixLocalBinding(
        version: 2,
        matrixUserId: '@synthetic:test',
        deviceId: 'SYNTHETIC',
        homeserver: 'https://matrix.test',
        databaseGeneration: 'synthetic-generation',
        ed25519Fingerprint: 'synthetic-fingerprint'));
    final client = _Client('@synthetic:test');
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.test'),
        secureSessionStore: secure,
        suspendClient: (_) async {},
        readContinuityMetadata: (active) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: true,
                userId: active.userID,
                deviceId: active.deviceID,
                ed25519Fingerprint: 'synthetic-fingerprint',
                databaseGeneration: 'synthetic-generation'));
    await tester.pumpWidget(CupertinoApp(
        home: AppHome(
            api: BusinessApiClient(
                baseUri: Uri.parse('https://business.test'),
                sessionStore: secure,
                client: MockClient((_) async => http.Response('{}', 404))),
            matrix: matrix,
            onLogout: () async {},
            themeController: ThemeController(store: _ThemeStore()),
            syncWatchdogFactory: (_) =>
                MatrixSyncWatchdog(target: _Target()))));
    await tester.pump();
    await tester.pump();
    return (matrix, client);
  }

  Future<void> unmount(WidgetTester tester, _Client client) async {
    final service = MediaOutboxRecoveryService.shared;
    final textStore = PersistentOutboxManager.shared?.store;
    final dynamic state = tester.state(find.byType(AppHome));
    final MatrixManagedResource resource = state.matrixResources;
    var closed = false;
    final closing = resource.cancel().then((_) => closed = true);
    for (var i = 0; i < 30 && !closed; i++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    expect(closed, isTrue, reason: 'the mounted resource must drain');
    await closing;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    if (service != null) await settle(tester, service.close());
    if (textStore != null) await settle(tester, textStore.close());
    await settle(tester, MediaIndex.shared.close());
    MediaIndex.overrideShared(null);
    await settle(tester, MediaCache.closeQuotaIndexes());
    await settle(tester, client.dispose());
    await tester.pump();
  }

  testWidgets('AppHome binds durable media to its opened startup generation',
      (tester) async {
    final (matrix, client) = await mount(tester);
    try {
      final service = MediaOutboxRecoveryService.shared;
      expect(service, isNotNull,
          reason: 'a valid secure binding must install the production sender');
      expect(service!.active, isTrue);
      expect(service.store.owner.accountId, matrix.userId);
    } finally {
      await unmount(tester, client);
    }
  });

  for (final video in [false, true]) {
    testWidgets(
        'AppHome production binding admits ${video ? 'gallery video' : 'prepared image'}',
        (tester) async {
      final (matrix, client) = await mount(tester);
      try {
        final selected = File('${root.path}/selected.mp4');
        final sending = video
            ? matrix.enqueueVideoFile(
                jobId: 'synthetic-video',
                video: MatrixOutgoingVideoFile(
                    id: 'synthetic-video',
                    source: selected,
                    filename: 'selected.mp4',
                    body: '[视频]',
                    deleteSourceWhenDone: false),
                targetRoomIds: [client.room.id])
            : matrix.enqueuePreparedMedia(
                jobId: 'synthetic-image',
                media: MatrixOutgoingPreparedMedia(
                    id: 'synthetic-image',
                    bytes: base64Decode(
                        'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'),
                    mimeType: 'image/gif',
                    filename: 'selected.gif',
                    body: '[图片]'),
                targetRoomIds: [client.room.id]);
        final job = await settle(tester, sending);
        expect(job.source!.id, startsWith('durable:'));
        await settle(tester, matrix.outgoingWork.drain());
        expect(client.room.sentTypes, [video ? 'm.video' : 'm.image']);
      } finally {
        await unmount(tester, client);
      }
    });
  }

  testWidgets('a delayed secure binding joins the current opened generation',
      (tester) async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final storage = MemorySecureKeyValueStore()
      ..beforeRead = (key) async {
        if (key == 'liuhetong.matrix_local_binding.v1') {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        }
      };
    final (_, client) = await mount(tester, storage: storage);
    try {
      expect(entered.isCompleted, isTrue);
      expect(MediaOutboxRecoveryService.shared, isNull);
      release.complete();
      await tester.pump();
      await tester.pump();
      expect(MediaOutboxRecoveryService.shared, isNotNull);
      expect(MediaOutboxRecoveryService.shared!.active, isTrue);
    } finally {
      if (!release.isCompleted) release.complete();
      await unmount(tester, client);
    }
  });

  testWidgets(
      'a secure binding resolving after disposal cannot install a sender',
      (tester) async {
    final release = Completer<void>();
    final storage = MemorySecureKeyValueStore()
      ..beforeRead = (key) async {
        if (key == 'liuhetong.matrix_local_binding.v1') await release.future;
      };
    final (_, client) = await mount(tester, storage: storage);
    expect(MediaOutboxRecoveryService.shared, isNull);
    await unmount(tester, client);
    release.complete();
    await tester.pump();
    await tester.pump();
    expect(MediaOutboxRecoveryService.shared, isNull);
  });

  testWidgets('a delayed binding cannot cross an account identity change',
      (tester) async {
    final release = Completer<void>();
    final storage = MemorySecureKeyValueStore()
      ..beforeRead = (key) async {
        if (key == 'liuhetong.matrix_local_binding.v1') await release.future;
      };
    final (_, client) = await mount(tester, storage: storage);
    try {
      client.account = '@other:test';
      release.complete();
      await tester.pump();
      await tester.pump();
      expect(MediaOutboxRecoveryService.shared, isNull);
    } finally {
      if (!release.isCompleted) release.complete();
      await unmount(tester, client);
    }
  });

  testWidgets('an installed sender becomes inactive after account change',
      (tester) async {
    final (matrix, client) = await mount(tester);
    try {
      expect(MediaOutboxRecoveryService.shared, isNotNull,
          reason: 'the account guard needs the production sender installed');
      final service = MediaOutboxRecoveryService.shared!;
      expect(service.active, isTrue);
      client.account = '@other:test';
      expect(service.active, isFalse);
      expect(service.store.owner.accountId, '@synthetic:test');
      expect(
          () => matrix.enqueuePreparedMedia(
              jobId: 'changed-account',
              media: MatrixOutgoingPreparedMedia(
                  id: 'changed-account',
                  bytes: [1, 2, 3],
                  mimeType: 'image/png',
                  filename: 'synthetic.png',
                  body: '[图片]'),
              targetRoomIds: [client.room.id]),
          throwsA(predicate((error) =>
              error is StateError &&
              error.message == 'E2EE_LIFECYCLE_ACCESS_REVOKED')));
      expect(client.room.sentTypes, isEmpty);
    } finally {
      await unmount(tester, client);
    }
  });
}
