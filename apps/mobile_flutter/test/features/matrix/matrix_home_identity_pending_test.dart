import 'package:liuhetong_mobile/core/network_state_manager.dart';
import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_home_page.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/ui/theme/theme_controller.dart';
import 'package:matrix/matrix.dart';

void main() {
  testWidgets('retry reacts to restored connectivity, not online weak noise',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final network = NetworkStateManager();
    NetworkStateManager.shared = network;
    final client = _HeldSyncClient('@self:matrix.example');
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'));
    var calls = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: SecureSessionStore(_MemoryStore()),
        client: MockClient((request) async {
          if (request.url.path.contains('/associations')) calls++;
          return http.Response('{}', 503);
        }));
    final identities = _identities();
    await identities.preload();
    try {
      await tester.pumpWidget(_home(
          matrix: matrix,
          api: api,
          identityCache: identities,
          previewOnly: false,
          snapshotLoader: () async => _snapshot('local', pending: 1)));
      await tester.pumpAndSettle();
      expect(calls, 1);
      network.report(
          serverReachable: true, lastRoundTrip: const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(calls, 1, reason: 'weak is still usable, preserve retry backoff');
      network.report(
          serverReachable: true,
          lastRoundTrip: const Duration(milliseconds: 10));
      await tester.pumpAndSettle();
      expect(calls, 1);
      network.report(transportAvailable: false);
      await tester.pump(const Duration(seconds: 10));
      expect(calls, 1, reason: 'offline does not send recovery requests');
      network.report(transportAvailable: true, serverReachable: true);
      await tester.pumpAndSettle();
      expect(calls, 2,
          reason: 'reconnect repairs without waiting for Matrix sync');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 10));
      expect(calls, 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(calls, 3, reason: 'resume immediately repairs pending identity');
    } finally {
      await tester.pumpWidget(const SizedBox());
      client.completeSync();
      await tester.pump();
      identities.dispose();
      NetworkStateManager.shared = null;
      network.dispose();
    }
  });

  testWidgets('pending identity retries without another sync or user tap',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final client = _HeldSyncClient('@self:matrix.example');
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'));
    var calls = 0;
    var pending = 1;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: SecureSessionStore(_MemoryStore()),
        client: MockClient((request) async {
          if (request.url.path.contains('/associations')) {
            calls++;
            if (calls >= 2) pending = 0;
          }
          return http.Response('{}', 503);
        }));
    final identities = _identities();
    await identities.preload();
    await tester.pumpWidget(_home(
        matrix: matrix,
        api: api,
        identityCache: identities,
        previewOnly: false,
        snapshotLoader: () async => _snapshot('local', pending: pending)));
    await tester.pumpAndSettle();
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    try {
      expect(calls, 2);
      expect(find.text('正在恢复会话'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      expect(calls, 2, reason: 'stop scheduled retries after recovery');
    } finally {
      await tester.pumpWidget(const SizedBox());
      client.completeSync();
      await tester.pump();
      identities.dispose();
    }
  });

  testWidgets(
      'pending-only snapshot has no recovery notice or false empty label',
      (tester) async {
    final matrix = MatrixSdkE2eeClient(_NoNetworkClient(),
        homeserver: Uri.parse('https://matrix.example'));
    await tester.pumpWidget(_home(
        matrix: matrix,
        snapshotLoader: () async => MatrixConversationSnapshot(
            vaultRoomId: null,
            reminderRoomId: null,
            rooms: [],
            unresolvedRoomCount: 3)));
    await tester.pumpAndSettle();
    expect(find.text('正在恢复会话'), findsNothing);
    expect(find.text('暂无消息'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pending identity stays silent beside usable known local rooms',
      (tester) async {
    final matrix = MatrixSdkE2eeClient(_NoNetworkClient(),
        homeserver: Uri.parse('https://matrix.example'));
    await tester.pumpWidget(_home(
        matrix: matrix,
        snapshotLoader: () async => _snapshot('本地群聊', pending: 4)));
    await tester.pumpAndSettle();
    expect(find.text('正在恢复会话'), findsNothing);
    expect(find.text('聊天记录已保留，联网后自动重试'), findsNothing);
    expect(find.text('本地群聊'), findsOneWidget);
    expect(find.text('暂无消息'), findsNothing);
    expect(find.text('4'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('known rows stay unchanged across silent identity resolution',
      (tester) async {
    final matrix = MatrixSdkE2eeClient(_NoNetworkClient(),
        homeserver: Uri.parse('https://matrix.example'));
    var pending = 1;
    await tester.pumpWidget(_home(
        matrix: matrix,
        snapshotLoader: () async => _snapshot('本地群聊', pending: pending)));
    await tester.pumpAndSettle();
    expect(find.text('正在恢复会话'), findsNothing);
    pending = 0;
    conversationPreferencesChanged.publish();
    await tester.pumpAndSettle();
    expect(find.text('正在恢复会话'), findsNothing);
    expect(find.text('本地群聊'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'network convergence completes then refreshes; retry is single flight',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final client = _HeldSyncClient('@self:matrix.example');
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'));
    final held = Completer<http.Response>();
    var associationCalls = 0;
    var pending = 1;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: SecureSessionStore(_MemoryStore()),
        client: MockClient((request) async {
          if (request.url.path.contains('/associations')) {
            associationCalls++;
            if (associationCalls == 1) return http.Response('{}', 503);
            return held.future;
          }
          return http.Response('{}', 500);
        }));
    final identities = _identities();
    await identities.preload();
    await tester.pumpWidget(_home(
        matrix: matrix,
        api: api,
        identityCache: identities,
        previewOnly: false,
        snapshotLoader: () async => _snapshot('本地群聊', pending: pending)));
    await tester.pumpAndSettle();
    expect(associationCalls, 1);
    expect(find.text('本地群聊'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(associationCalls, 2);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(associationCalls, 2);
    expect(find.text('正在恢复会话'), findsNothing);
    pending = 0;
    held.complete(http.Response('{}', 503));
    await tester.pumpAndSettle();
    expect(find.text('正在恢复会话'), findsNothing);
    expect(find.text('本地群聊'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    client.completeSync();
    await tester.pump();
    identities.dispose();
  });
  testWidgets(
      'late convergence cannot refresh a replacement account or disposed page',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final oldClient = _HeldSyncClient('@self:matrix.example');
    final oldMatrix = MatrixSdkE2eeClient(oldClient,
        homeserver: Uri.parse('https://matrix.example'));
    final held = Completer<http.Response>();
    var requested = false;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: SecureSessionStore(_MemoryStore()),
        client: MockClient((request) async {
          if (request.url.path.contains('/associations')) {
            requested = true;
            return held.future;
          }
          return http.Response('{}', 500);
        }));
    final identities = _identities();
    await identities.preload();
    await tester.pumpWidget(_home(
        matrix: oldMatrix,
        api: api,
        identityCache: identities,
        previewOnly: false,
        snapshotLoader: () async => _snapshot('旧账号', pending: 1)));
    await tester.pumpAndSettle();
    expect(requested, isTrue);
    final newClient = _HeldSyncClient('@new:matrix.example');
    final newMatrix = MatrixSdkE2eeClient(newClient,
        homeserver: Uri.parse('https://matrix.example'));
    var newLoads = 0;
    await tester.pumpWidget(_home(
        matrix: newMatrix,
        snapshotLoader: () async {
          newLoads++;
          return _snapshot('新账号');
        }));
    await tester.pumpAndSettle();
    final loadsBeforeOldCompletion = newLoads;
    held.complete(http.Response('{}', 503));
    await tester.pumpAndSettle();
    expect(newLoads, loadsBeforeOldCompletion);
    expect(find.text('旧账号'), findsNothing);
    expect(find.text('正在恢复会话'), findsNothing);
    expect(find.text('新账号'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    oldClient.completeSync();
    newClient.completeSync();
    await tester.pump();
    expect(tester.takeException(), isNull);
    identities.dispose();
  });
}

Widget _home({
  required MatrixSdkE2eeClient matrix,
  required Future<MatrixConversationSnapshot> Function() snapshotLoader,
  bool previewOnly = true,
  ProfileRepository? identityCache,
  BusinessApiClient? api,
}) {
  // Directory recovery tests start with an already hydrated caller-owned cache.
  // Actual cold disk hydration is covered by cold_start_identity_test.
  final identities = identityCache ?? ProfileRepository(api ?? _api());
  if (identityCache == null) addTearDown(identities.dispose);
  return CupertinoApp(
      home: MatrixHomePage(
    api: api ?? _api(),
    matrix: matrix,
    themeController: ThemeController(store: _MemoryThemeStore()),
    onCreateGroup: () {},
    previewOnly: previewOnly,
    identityCache: identities,
    snapshotLoader: snapshotLoader,
  ));
}

BusinessApiClient _api() => BusinessApiClient(
    baseUri: Uri.parse('https://business.example'),
    sessionStore: SecureSessionStore(_MemoryStore()),
    client: MockClient((_) async => http.Response('{}', 500)));

MatrixConversationSnapshot _snapshot(String id, {int pending = 0}) =>
    MatrixConversationSnapshot(
      unresolvedRoomCount: pending,
      vaultRoomId: null,
      reminderRoomId: null,
      rooms: [
        MatrixConversationRoomSnapshot(
          id: '!$id:test',
          displayName: id,
          avatar: null,
          isDirect: false,
          directPeerId: null,
          members: const [],
          lastEvent: null,
          preference: const ConversationPreference(),
          notificationCount: 0,
          notificationsEnabled: true,
          name: id,
          isJoined: true,
        ),
      ],
    );

final class _NoNetworkClient extends Client {
  _NoNetworkClient() : super('home-snapshot-refresh-test');
  @override
  String get userID => '@self:matrix.example';
}

final class _MemoryStore implements SecureKeyValueStore {
  @override
  Future<void> delete(String key) async {}
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
}

final class _MemoryThemeStore implements ThemePreferenceStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async {}
}

final class _HeldSyncClient extends Client {
  _HeldSyncClient(this.matrixUserId)
      : super('home-snapshot-held-sync-$matrixUserId');
  final String matrixUserId;
  final Completer<SyncUpdate> _sync = Completer<SyncUpdate>();
  @override
  String get userID => matrixUserId;
  @override
  Future<SyncUpdate> sync(
          {String? filter,
          String? since,
          bool? fullState,
          PresenceType? setPresence,
          int? timeout}) =>
      _sync.future;
  void completeSync() {
    if (!_sync.isCompleted) _sync.complete(SyncUpdate.fromJson(const {}));
  }
}

ProfileRepository _identities() => ProfileRepository.forTesting(
      accountKey: '@self:matrix.example',
      store: _ProfileStore(),
      loadProfile: () async => const ProfileData(
          username: 'self',
          nickname: 'self',
          maskedEmail: '',
          fallbackSeed: 'self'),
      loadContacts: () async => const [
        ContactSummary(
            userId: 'peer',
            username: 'peer',
            matrixUserId: '@peer:matrix.example')
      ],
    );

final class _ProfileStore implements ProfileStore {
  @override
  Future<ProfileSnapshot?> read(String accountKey) async => null;
  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) async {}
}
