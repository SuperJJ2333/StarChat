import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_user_avatar.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';
import 'package:liuhetong_mobile/ui/foundation/avatar_cache.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

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

void main() {
  final originalPaths = PathProviderPlatform.instance;
  setUpAll(() async {
    final root = Directory(
            '../../docs/verification/artifacts/2026-09-24/cold-start-cache/avatar-disk-${DateTime.now().microsecondsSinceEpoch}')
        .absolute;
    await root.create(recursive: true);
    PathProviderPlatform.instance = _AvatarPaths(root.path);
  });
  tearDownAll(() async {
    await AvatarCache.manager.dispose();
    PathProviderPlatform.instance = originalPaths;
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
    await tester.runAsync(() => AvatarCache.manager.putFile(
          url,
          base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='),
          key: AvatarCache.cacheKey(userId: 'alice', avatarUrl: url),
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
  });
}
