import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:liuhetong_mobile/core/startup_projection/startup_projection.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_user_avatar.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';
import 'package:liuhetong_mobile/ui/foundation/avatar_cache.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RealHttp extends HttpOverrides {}

class _AvatarPaths extends PathProviderPlatform {
  _AvatarPaths(this.path);
  final String path;
  @override
  Future<String> getTemporaryPath() async => path;
  @override
  Future<String> getApplicationSupportPath() async => path;
}

class _ColdClient extends Client {
  _ColdClient(String name) : super(name) {
    homeserver = Uri.parse('https://$name.example');
    accessToken = '$name-token';
  }

  @override
  String? get userID => '@alice:example';
  final discovery = Completer<bool>();
  int discoveryCalls = 0;
  @override
  Future<bool> authenticatedMediaSupported() {
    discoveryCalls++;
    return discovery.future;
  }
}

Widget _avatar(AvatarMediaCapability media) => CupertinoApp(
      home: MatrixUserAvatar(
        avatarMedia: media,
        nickname: 'Alice',
        fallbackSeed: 'alice',
        matrixAvatarUri: Uri.parse('mxc://media.example/avatar'),
      ),
    );

Future<MatrixClientContinuityMetadata> _continuity(Client client) async =>
    MatrixClientContinuityMetadata(
      isLoggedIn: false,
      userId: client.userID,
      deviceId: client.deviceID,
      ed25519Fingerprint: null,
      databaseGeneration: 'avatar-fixture',
    );

Future<T> _finishIo<T>(WidgetTester tester, Future<T> future) async {
  var settled = false;
  final result = future.whenComplete(() => settled = true);
  for (var i = 0; i < 200 && !settled; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(settled, isTrue,
      reason: 'avatar cache I/O must settle across both zones');
  return result;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final originalPaths = PathProviderPlatform.instance;
  final originalHttp = HttpOverrides.current;
  setUpAll(() async {
    final root = Directory(
            '../../docs/verification/artifacts/2026-10-17/startup-local-projection/fixtures/avatar-disk-${DateTime.now().microsecondsSinceEpoch}')
        .absolute;
    await root.create(recursive: true);
    PathProviderPlatform.instance = _AvatarPaths(root.path);
    HttpOverrides.global = _RealHttp();
    // Initialize the shared cache runtime outside any widget's FakeAsync zone.
    // The tested avatar keys are still populated by the real UserAvatar request.
    await AvatarCache.manager.putFile(
        'https://synthetic.test/runtime-init', base64Decode('AQ=='),
        key: 'synthetic-runtime-init');
  });
  tearDownAll(() async {
    await AvatarCache.manager.dispose();
    PathProviderPlatform.instance = originalPaths;
    HttpOverrides.global = originalHttp;
  });

  testWidgets(
      'verified avatar warms real disk then new local owner reads without network',
      (tester) async {
    final server = (await tester
        .runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0)))!;
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='));
      await request.response.close();
    });
    final host = Uri.parse('http://127.0.0.1:${server.port}');
    final client = _ColdClient('warm-real')..homeserver = host;
    client.discovery.complete(true);
    final full = MatrixSdkE2eeClient(client,
        homeserver: host, readContinuityMetadata: _continuity);
    const raw = '!group:example';
    final identity = full.avatarCacheIdentity(raw)!;
    final uri = Uri.parse('mxc://media.example/real-warm');
    Widget avatar(AvatarMediaCapability owner,
            {Uri? matrixUri, String? fallback}) =>
        CupertinoApp(
            home: MatrixUserAvatar(
                avatarMedia: owner,
                nickname: 'Group',
                fallbackSeed: raw,
                matrixAvatarUri: matrixUri,
                fallbackAvatarUrl: fallback));
    Future<void> paint() async {
      for (var i = 0; i < 60; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)));
        await tester.pump();
        if (tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null)) {
          return;
        }
      }
      fail('expected disk image to paint');
    }

    final held = Completer<void>();
    final localClient = Client('local-avatar');
    localClient.seedStartupRooms([], held.future);
    final epoch = base64Url.encode(List.filled(32, 1)).replaceAll('=', '');
    final local = MatrixSdkE2eeClient(localClient,
        homeserver: host,
        startupProjection: StartupProjection([]),
        startupAdmission: StartupProjectionAdmission(
            scope: '',
            homeserver: host.toString(),
            userId: '@alice:example',
            deviceId: 'SYNTHETIC',
            fingerprint: 'synthetic',
            databaseGeneration: 'synthetic',
            installationId: epoch,
            epoch: epoch,
            databaseKey: base64Url.encode(List.filled(32, 2)),
            registrationKey: 'synthetic'));
    try {
      await tester.pumpWidget(avatar(full, matrixUri: uri));
      await paint();
      expect(requests, 1);
      expect(tester.widget<UserAvatar>(find.byType(UserAvatar)).avatarCacheKey,
          identity);
      await tester.pumpWidget(const SizedBox());
      AvatarCache.clearRetainedForAccount('matrix:@alice:example');
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      expect(local.avatarCacheIdentity(raw), identity);
      expect(local.avatarCacheIdentity(identity), identity);
      expect(local.avatarCacheIdentity('identity:other:user'), isNull);
      expect(local.avatarCacheIdentity('identity:memory:user'), isNull);
      await tester.pumpWidget(avatar(local, matrixUri: uri));
      await paint();
      expect(
          tester.widget<UserAvatar>(find.byType(UserAvatar)).localImageProvider,
          isA<FileImage>());
      expect(requests, 1);
      expect(localClient.isLogged(), isFalse);
      expect(localClient.database, isNull);
      final resolved = full.resolveAvatarImmediately(avatarUri: uri, size: 48)!;
      await tester.pumpWidget(avatar(local, fallback: resolved.url));
      await paint();
      expect(requests, 1);
      await tester.pumpWidget(avatar(local));
      await tester.pump();
      expect(
          tester.widget<UserAvatar>(find.byType(UserAvatar)).localImageProvider,
          isNull);
      expect(find.byType(RawImage), findsNothing);
      File? retained;
      var readDone = false;
      final read =
          AvatarCache.readCachedFile(userId: identity, avatarUrl: resolved.url)
              .then((file) {
        retained = file;
        readDone = true;
      });
      for (var i = 0; i < 100 && !readDone; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(readDone, isTrue);
      await read;
      expect(retained, isNotNull,
          reason: 'local display never evicts or refreshes');
    } finally {
      await tester.pumpWidget(const SizedBox());
      held.complete();
      await tester.pump();
      var disposed = false;
      final closing = Future.wait([localClient.dispose(), client.dispose()])
          .then((_) => disposed = true);
      for (var i = 0; i < 100 && !disposed; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      await tester.runAsync(
          () => server.close(force: true).timeout(const Duration(seconds: 3)));
      expect(disposed, isTrue, reason: 'both avatar owners must drain');
      await closing;
      await tester.pump(const Duration(seconds: 20));
    }
  });

  test('suspension blocks immediate and pending avatar credentials', () async {
    final client = _ColdClient('cold-suspended');
    final owner = MatrixSdkE2eeClient(client,
        readContinuityMetadata: _continuity,
        homeserver: client.homeserver!,
        suspendClient: (_) async {});
    final pending = owner.resolveAvatar(
        avatarUri: Uri.parse('mxc://media.example/avatar'), size: 48);
    final rejected = expectLater(pending, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect(client.discoveryCalls, 1);
    final suspended = owner.suspend();
    expect(
        () => owner.resolveAvatarImmediately(
            avatarUri: Uri.parse('mxc://media.example/avatar'), size: 48),
        throwsStateError);
    client.discovery.complete(true);
    await rejected;
    await suspended;
  });

  test('released room lease cannot publish an in-flight avatar', () async {
    final client = _ColdClient('cold-release');
    final owner = MatrixSdkE2eeClient(client,
        readContinuityMetadata: _continuity, homeserver: client.homeserver!);
    client.rooms.add(Room(id: '!room:example', client: client));
    final lease = await owner.openRoomLease('!room:example');
    final pending = lease.resolveAvatar(
        avatarUri: Uri.parse('mxc://media.example/avatar'), size: 48);
    final rejected = expectLater(pending, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    await lease.cancel();
    expect(
        () => lease.resolveAvatarImmediately(
            avatarUri: Uri.parse('mxc://media.example/avatar'), size: 48),
        throwsStateError);
    client.discovery.complete(true);
    await rejected;
  });

  test('token rotation drops obsolete async headers', () async {
    final client = _ColdClient('cold-rotation');
    final owner = MatrixSdkE2eeClient(client,
        readContinuityMetadata: _continuity, homeserver: client.homeserver!);
    final pending = owner.resolveAvatar(
        avatarUri: Uri.parse('mxc://media.example/avatar'), size: 48);
    final rejected = expectLater(pending, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    client.accessToken = 'rotated-token';
    client.discovery.complete(true);
    await rejected;
    expect(
        owner
            .resolveAvatarImmediately(
                avatarUri: Uri.parse('mxc://media.example/avatar'), size: 48)!
            .headers,
        {'authorization': 'Bearer rotated-token'});
  });

  testWidgets('cold avatar paints disk bytes with discovery still pending',
      (tester) async {
    final client = _ColdClient('cold-disk');
    final owner = MatrixSdkE2eeClient(client,
        readContinuityMetadata: _continuity, homeserver: client.homeserver!);
    const url =
        'https://cold-disk.example/_matrix/client/v1/media/thumbnail/media.example/avatar?width=96&height=96&method=crop&animated=false';
    await _finishIo(
        tester,
        AvatarCache.manager.putFile(
          url,
          base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='),
          key: AvatarCache.cacheKey(
              userId: owner.avatarCacheIdentity('alice')!, avatarUrl: url),
          fileExtension: 'png',
        ));
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await tester.pumpWidget(_avatar(owner));
    var painted = false;
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      painted = tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((image) => image.image != null);
      if (painted) break;
    }
    expect(client.discovery.isCompleted, isFalse);
    expect(painted, isTrue);
    client.discovery.complete(true);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('cold business avatar reuses disk bytes after URL is re-signed',
      (tester) async {
    const firstUrl =
        'https://media.example.test/profile/avatar/content/token-one?expires_in=300&v=stable';
    const renewedUrl =
        'https://media.example.test/profile/avatar/content/token-two?expires_in=300&v=stable';
    const accountKey = 'account-a:alice';
    await _finishIo(
        tester,
        AvatarCache.manager.putFile(
          firstUrl,
          base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='),
          key: AvatarCache.cacheKey(userId: accountKey, avatarUrl: firstUrl),
          fileExtension: 'png',
        ));
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();

    await tester.pumpWidget(const CupertinoApp(
      home: UserAvatar(
        nickname: 'Alice',
        fallbackSeed: accountKey,
        avatarUrl: renewedUrl,
      ),
    ));
    var painted = false;
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      painted = tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((image) => image.image != null);
      if (painted) break;
    }
    expect(AvatarCache.cacheKey(userId: accountKey, avatarUrl: renewedUrl),
        AvatarCache.cacheKey(userId: accountKey, avatarUrl: firstUrl));
    expect(painted, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 20));
  });

  for (final roomLease in [false, true]) {
    testWidgets(
        'cold ${roomLease ? "room" : "account"} avatar publishes cache URL before discovery',
        (tester) async {
      final client = _ColdClient(roomLease ? 'cold-room' : 'cold-account');
      final owner = MatrixSdkE2eeClient(client,
          readContinuityMetadata: _continuity, homeserver: client.homeserver!);
      client.rooms.add(Room(id: '!room:example', client: client));
      final AvatarMediaCapability media =
          roomLease ? await owner.openRoomLease('!room:example') : owner;
      await tester.pumpWidget(_avatar(media));
      final first = tester.widget<UserAvatar>(find.byType(UserAvatar));
      expect(client.discoveryCalls, 1);
      expect(first.avatarUrl, contains('/_matrix/client/v1/media/thumbnail/'));
      expect(first.avatarUrl, isNot(contains(client.accessToken!)));
      expect(first.avatarHeaders,
          {'authorization': 'Bearer ${client.accessToken}'});
      client.discovery.complete(false);
      await tester.pump();
      await tester.pump();
      final legacy = tester.widget<UserAvatar>(find.byType(UserAvatar));
      expect(legacy.avatarUrl, contains('/_matrix/media/v3/thumbnail/'));
      expect(legacy.avatarHeaders, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'switching capability discards late discovery and old credentials',
      (tester) async {
    final old = _ColdClient('cold-old');
    final fresh = _ColdClient('cold-new');
    final oldOwner = MatrixSdkE2eeClient(old,
        readContinuityMetadata: _continuity, homeserver: old.homeserver!);
    final freshOwner = MatrixSdkE2eeClient(fresh,
        readContinuityMetadata: _continuity, homeserver: fresh.homeserver!);
    await tester.pumpWidget(_avatar(oldOwner));
    await tester.pumpWidget(_avatar(freshOwner));
    old.discovery.complete(true);
    await tester.pump();
    final current = tester.widget<UserAvatar>(find.byType(UserAvatar));
    expect(current.avatarUrl, contains('cold-new.example'));
    expect(current.avatarHeaders, {'authorization': 'Bearer cold-new-token'});
    fresh.discovery.complete(true);
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 20));
  });
}
