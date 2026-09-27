import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_home_page.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_user_avatar.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/ui/theme/theme_controller.dart';
import 'package:liuhetong_mobile/ui/foundation/avatar_cache.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory cacheDirectory;
  late PathProviderPlatform originalPaths;
  late _HeldPaths paths;
  late BusinessApiClient api;
  late List<String> requests;

  setUpAll(() async {
    originalPaths = PathProviderPlatform.instance;
    cacheDirectory = Directory(
            '../../docs/verification/artifacts/2026-09-24/cold-start-cache/identity-avatar-${DateTime.now().microsecondsSinceEpoch}')
        .absolute;
    await cacheDirectory.create(recursive: true);
    final cachePaths = _HeldPaths(cacheDirectory.path)..release();
    PathProviderPlatform.instance = cachePaths;
    // Initialize image-cache IO outside the widget fake-async zone. These tests
    // assert profile URL projection; avatar disk bytes have a separate suite.
    await AvatarCache.manager.getFileFromCache('identity-fixture');
  });
  tearDownAll(() async {
    await AvatarCache.manager.dispose();
    PathProviderPlatform.instance = originalPaths;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PathProviderPlatform.instance = paths = _HeldPaths(cacheDirectory.path);
    requests = [];
    api = BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: SecureSessionStore(_MemoryStore()),
      client: MockClient((request) {
        requests.add(request.url.path);
        return Completer<http.Response>().future;
      }),
    );
    final store =
        SharedPreferencesProfileStore(await SharedPreferences.getInstance());
    for (final account in ['alice', 'bob']) {
      await store.write(
          'matrix:@$account:test',
          ProfileSnapshot(
            profile: ProfileData(
                username: account,
                nickname: account,
                maskedEmail: '',
                fallbackSeed: account),
            contacts: [
              ContactSummary(
                  userId: 'peer',
                  username: 'peer',
                  matrixUserId: '@peer:test',
                  nickname: 'Cached $account nickname',
                  remark: 'Cached $account remark',
                  avatarUrl: 'https://cdn.example/$account.png')
            ],
          ));
    }
  });

  testWidgets(
      'cold preview restores persisted remark and avatar without business requests',
      (tester) async {
    final matrix = _matrix('alice');
    await tester.pumpWidget(_home(api, matrix));
    paths.release();
    await tester.pump();
    await tester.pump();
    expect(find.text('Cached alice remark'), findsOneWidget);
    expect(
        tester
            .widget<MatrixUserAvatar>(find.byType(MatrixUserAvatar))
            .fallbackAvatarUrl,
        'https://cdn.example/alice.png');
    expect(requests, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('preview shows empty state only after its first local snapshot',
      (tester) async {
    final snapshot = Completer<MatrixConversationSnapshot>();
    await tester.pumpWidget(
        _home(api, _matrix('alice'), snapshotLoader: () => snapshot.future));
    expect(find.text('暂无消息'), findsNothing,
        reason: 'disk identity hydration has not finished');
    paths.release();
    await tester.pump();
    expect(find.text('暂无消息'), findsNothing,
        reason: 'the first local room snapshot is still pending');
    snapshot.complete(MatrixConversationSnapshot(
        vaultRoomId: null, reminderRoomId: null, rooms: []));
    await tester.pump();
    await tester.pump();
    expect(find.text('暂无消息'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('authenticated cold preview does not warm support badges',
      (tester) async {
    final sessions = SecureSessionStore(_MemoryStore());
    await sessions.saveSession(
        accessToken: 'fixture-access',
        refreshToken: 'fixture-refresh',
        matrixUserId: '@alice:test');
    final authenticatedApi = BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: sessions,
      client: MockClient((request) {
        requests.add(request.url.path);
        return Completer<http.Response>().future;
      }),
    );
    await tester.pumpWidget(_home(authenticatedApi, _matrix('alice')));
    paths.release();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Cached alice remark'), findsOneWidget);
    expect(requests, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('account switch ignores a delayed old disk load', (tester) async {
    await tester.pumpWidget(_home(api, _matrix('alice')));
    await tester.pumpWidget(_home(api, _matrix('bob')));
    paths.release();
    await tester.pump();
    await tester.pump();
    expect(find.text('Cached bob remark'), findsOneWidget);
    expect(find.text('Cached alice remark'), findsNothing);
    expect(
        tester
            .widget<MatrixUserAvatar>(find.byType(MatrixUserAvatar))
            .fallbackAvatarUrl,
        'https://cdn.example/bob.png');
    expect(requests, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'disposing during disk restore does not publish or request network',
      (tester) async {
    await tester.pumpWidget(_home(api, _matrix('alice')));
    await tester.pumpWidget(const SizedBox.shrink());
    paths.release();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(requests, isEmpty);
  });

  testWidgets(
      'injected identity repository stays caller owned and skips disk loading',
      (tester) async {
    final repository = ProfileRepository(api);
    await repository.applyUpdatedContact(ContactSummary(
        userId: 'peer',
        username: 'peer',
        matrixUserId: '@peer:test',
        remark: 'Injected remark'));
    await tester
        .pumpWidget(_home(api, _matrix('alice'), identities: repository));
    await tester.pump();
    expect(find.text('Injected remark'), findsOneWidget);
    expect(paths.calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(() => repository.addListener(() {}), returnsNormally);
    repository.dispose();
  });

  testWidgets('injected repository replaces a pending disk load',
      (tester) async {
    final matrix = _matrix('alice');
    await tester.pumpWidget(_home(api, matrix));
    final repository = ProfileRepository(api);
    await repository.applyUpdatedContact(const ContactSummary(
        userId: 'peer',
        username: 'peer',
        matrixUserId: '@peer:test',
        remark: 'Replacement remark'));
    await tester.pumpWidget(_home(api, matrix, identities: repository));
    paths.release();
    await tester.pump();
    await tester.pump();
    expect(find.text('Replacement remark'), findsOneWidget);
    expect(find.text('Cached alice remark'), findsNothing);
    expect(requests, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(() => repository.addListener(() {}), returnsNormally);
    repository.dispose();
  });
}

Widget _home(BusinessApiClient api, MatrixSdkE2eeClient matrix,
        {ProfileRepository? identities,
        Future<MatrixConversationSnapshot> Function()? snapshotLoader}) =>
    CupertinoApp(
      home: MatrixHomePage(
        api: api,
        matrix: matrix,
        themeController: ThemeController(store: _ThemeStore()),
        onCreateGroup: () {},
        previewOnly: true,
        identityCache: identities,
        snapshotLoader: snapshotLoader ??
            () async => MatrixConversationSnapshot(
                    vaultRoomId: null,
                    reminderRoomId: null,
                    rooms: [
                      MatrixConversationRoomSnapshot(
                          id: '!direct:test',
                          displayName: 'Public peer',
                          avatar: null,
                          isDirect: true,
                          directPeerId: '@peer:test',
                          members: const [],
                          lastEvent: null,
                          preference: const ConversationPreference(),
                          notificationCount: 0,
                          notificationsEnabled: true,
                          name: 'Public peer',
                          isJoined: true)
                    ]),
      ),
    );

MatrixSdkE2eeClient _matrix(String account) =>
    MatrixSdkE2eeClient(_Client(account),
        homeserver: Uri.parse('https://matrix.example'));

final class _Client extends Client {
  _Client(this.account) : super('cold-preview-$account');
  final String account;
  @override
  String get userID => '@$account:test';
}

final class _HeldPaths extends PathProviderPlatform {
  _HeldPaths(this.path);
  final String path;
  Completer<String?>? pending;
  bool released = false;
  int calls = 0;
  @override
  Future<String?> getApplicationSupportPath() {
    calls++;
    if (released) return Future.value(path);
    return (pending ??= Completer<String?>()).future;
  }

  @override
  Future<String> getTemporaryPath() async => path;
  @override
  Future<String> getApplicationDocumentsPath() async => path;

  void release() {
    released = true;
    pending?.complete(null); // Exercise the persistent fallback store.
  }
}

final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

final class _ThemeStore implements ThemePreferenceStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async {}
}
