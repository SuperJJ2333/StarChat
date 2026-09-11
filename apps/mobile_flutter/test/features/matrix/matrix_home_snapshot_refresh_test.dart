import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_home_page.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_home_snapshot_refresh_coordinator.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/ui/theme/theme_controller.dart';
import 'package:matrix/matrix.dart';

void main() {
  test('coalesces a burst into one running pass and one fresh trailing pass',
      () async {
    final first = Completer<int>();
    final second = Completer<int>();
    final coordinator = SnapshotRefreshCoordinator<int>();
    var calls = 0;
    var active = 0;
    var peakActive = 0;

    Future<int> load() {
      calls++;
      active++;
      peakActive = peakActive < active ? active : peakActive;
      final result = calls == 1 ? first.future : second.future;
      return result.whenComplete(() => active--);
    }

    var publications = 0;
    void publish(int _) => publications++;
    final initial = coordinator.request(load, onValue: publish);
    expect(calls, 0, reason: 'same-turn work has not started yet');
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    final burstA = coordinator.request(load, onValue: publish);
    final burstB = coordinator.request(load, onValue: publish);
    expect(calls, 1);
    expect(peakActive, 1);

    first.complete(1);
    await initial;
    expect(calls, 2, reason: 'the burst needs exactly one fresh pass');
    var burstCompleted = false;
    unawaited(burstA.whenComplete(() => burstCompleted = true));
    await Future<void>.delayed(Duration.zero);
    expect(burstCompleted, isFalse);

    second.complete(2);
    await burstA;
    await burstB;
    expect(peakActive, 1);
    expect(publications, 2, reason: 'one publication per actual pass');
  });

  test('coalesces same-turn callers into one initial pass', () async {
    final coordinator = SnapshotRefreshCoordinator<int>();
    var calls = 0;
    Future<int> load() async => ++calls;

    final first = coordinator.request(load, onValue: (_) {});
    final second = coordinator.request(load, onValue: (_) {});
    await Future.wait([first, second]);
    expect(calls, 1);
  });

  test('a failed pass settles waiters and a later request can recover',
      () async {
    final coordinator = SnapshotRefreshCoordinator<int>();
    var calls = 0;

    Future<int> load() async {
      calls++;
      if (calls == 1) throw StateError('offline');
      return 2;
    }

    await expectLater(
        coordinator.request(load, onValue: (_) {}), throwsStateError);
    await coordinator.request(load, onValue: (_) {});
    expect(calls, 2);
  });

  test(
      'settles a synchronously throwing loader and accepts a synchronous future',
      () async {
    final coordinator = SnapshotRefreshCoordinator<int>();
    await expectLater(
        coordinator.request(() => throw StateError('offline'), onValue: (_) {}),
        throwsStateError);
    var published = 0;
    await coordinator.request(() => SynchronousFuture(3),
        onValue: (_) => published++);
    expect(published, 1);
  });

  testWidgets(
      'held home snapshots run one active pass and one fresh trailing pass',
      (tester) async {
    final first = Completer<MatrixConversationSnapshot>();
    final second = Completer<MatrixConversationSnapshot>();
    var calls = 0;
    var active = 0;
    var peakActive = 0;
    Future<MatrixConversationSnapshot> load() {
      calls++;
      active++;
      peakActive = peakActive < active ? active : peakActive;
      return (calls == 1 ? first.future : second.future)
          .whenComplete(() => active--);
    }

    await _pumpHome(tester, snapshotLoader: load);
    expect(calls, 1);
    conversationPreferencesChanged.publish();
    conversationPreferencesChanged.publish();
    await tester.pump();
    expect(calls, 1);

    first.complete(_snapshot('first'));
    await tester.pump();
    await tester.pump();
    expect(calls, 2);
    expect(peakActive, 1);

    second.complete(_snapshot('fresh'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('conversation-!fresh:test')),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'failed snapshot keeps the page recoverable and dispose ignores late work',
      (tester) async {
    final held = Completer<MatrixConversationSnapshot>();
    var calls = 0;
    Future<MatrixConversationSnapshot> load() {
      calls++;
      if (calls == 1) return Future.error(StateError('offline'));
      return held.future;
    }

    await _pumpHome(tester, snapshotLoader: load);
    await tester.pump();
    conversationPreferencesChanged.publish();
    await tester.pump();
    expect(calls, 2, reason: 'a later notification retries after failure');

    await tester.pumpWidget(const SizedBox());
    held.complete(_snapshot('late'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('matrix replacement rejects its old held snapshot',
      (tester) async {
    final oldHeld = Completer<MatrixConversationSnapshot>();
    final newHeld = Completer<MatrixConversationSnapshot>();
    var oldCalls = 0;
    var newCalls = 0;
    final oldMatrix = MatrixSdkE2eeClient(_NoNetworkClient(),
        homeserver: Uri.parse('https://old.example'));
    final newMatrix = MatrixSdkE2eeClient(_NoNetworkClient(),
        homeserver: Uri.parse('https://new.example'));

    await tester.pumpWidget(_home(
        matrix: oldMatrix,
        snapshotLoader: () {
          oldCalls++;
          return oldHeld.future;
        }));
    await tester.pump();
    expect(oldCalls, 1);

    await tester.pumpWidget(_home(
        matrix: newMatrix,
        snapshotLoader: () {
          newCalls++;
          return newHeld.future;
        }));
    oldHeld.complete(_snapshot('old'));
    await tester.pump();
    await tester.pump();
    expect(newCalls, 1);

    newHeld.complete(_snapshot('new'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('conversation-!new:test')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('conversation-!old:test')),
        findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('replacement ignores the old stream and accepts the new stream',
      (tester) async {
    final oldClient = _HeldSyncClient('@old:matrix.example');
    final newClient = _HeldSyncClient('@new:matrix.example');
    final oldMatrix = MatrixSdkE2eeClient(oldClient,
        homeserver: Uri.parse('https://old.example'));
    final newMatrix = MatrixSdkE2eeClient(newClient,
        homeserver: Uri.parse('https://new.example'));
    final oldHeld = Completer<MatrixConversationSnapshot>();
    final newHeld = Completer<MatrixConversationSnapshot>();
    var oldCalls = 0;
    var newCalls = 0;

    await tester.pumpWidget(_home(
        matrix: oldMatrix,
        previewOnly: false,
        snapshotLoader: () {
          oldCalls++;
          return oldCalls == 1
              ? Future.value(_snapshot('old'))
              : oldHeld.future;
        }));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('conversation-!old:test')),
        findsOneWidget);
    expect(oldCalls, greaterThanOrEqualTo(2));
    await tester.pumpWidget(_home(
        matrix: newMatrix,
        previewOnly: false,
        snapshotLoader: () {
          newCalls++;
          return newCalls == 1
              ? newHeld.future
              : Future.value(_snapshot('stream'));
        }));
    expect(find.byKey(const ValueKey<String>('conversation-!old:test')),
        findsNothing,
        reason: 'a different account clears an already-published old room');
    oldHeld.complete(_snapshot('old-late'));
    await tester.pump();
    await tester.pump();
    expect(newCalls, 1);

    oldClient.completeSync();
    await tester.pump();
    expect(newCalls, 1,
        reason: 'the detached old stream cannot refresh new UI');

    newClient.completeSync();
    await newMatrix.syncIfActive();
    await tester.pump();
    newHeld.complete(_snapshot('new'));
    await tester.pump();
    await tester.pump();
    expect(newCalls, 2,
        reason: 'the replacement client stream schedules fresh work');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('conversation-!stream:test')),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'external identity-cache replacement refreshes the same matrix page',
      (tester) async {
    final firstIdentity = ProfileRepository(_api());
    firstIdentity.contactsByMatrixId = {
      '@peer:matrix.example': _contact('First remark'),
    };
    final replacementIdentity = ProfileRepository(_api());
    replacementIdentity.contactsByMatrixId = {
      '@peer:matrix.example': _contact('Fresh remark'),
    };
    final matrix = MatrixSdkE2eeClient(_NoNetworkClient(),
        homeserver: Uri.parse('https://matrix.example'));
    var calls = 0;
    Future<MatrixConversationSnapshot> load() async {
      calls++;
      return _directSnapshot();
    }

    await tester.pumpWidget(_home(
        matrix: matrix, identityCache: firstIdentity, snapshotLoader: load));
    await tester.pumpAndSettle();
    expect(find.text('First remark'), findsOneWidget);

    await tester.pumpWidget(_home(
        matrix: matrix,
        identityCache: replacementIdentity,
        snapshotLoader: load));
    await tester.pumpAndSettle();
    expect(find.text('Fresh remark'), findsOneWidget);
    expect(calls, greaterThanOrEqualTo(2));
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _pumpHome(WidgetTester tester,
    {required Future<MatrixConversationSnapshot> Function() snapshotLoader}) {
  final matrix = MatrixSdkE2eeClient(_NoNetworkClient(),
      homeserver: Uri.parse('https://matrix.example'));
  return tester
      .pumpWidget(_home(matrix: matrix, snapshotLoader: snapshotLoader));
}

Widget _home({
  required MatrixSdkE2eeClient matrix,
  required Future<MatrixConversationSnapshot> Function() snapshotLoader,
  bool previewOnly = true,
  ProfileRepository? identityCache,
}) =>
    CupertinoApp(
        home: MatrixHomePage(
      api: _api(),
      matrix: matrix,
      themeController: ThemeController(store: _MemoryThemeStore()),
      onCreateGroup: () {},
      previewOnly: previewOnly,
      identityCache: identityCache,
      snapshotLoader: snapshotLoader,
    ));

BusinessApiClient _api() => BusinessApiClient(
    baseUri: Uri.parse('https://business.example'),
    sessionStore: SecureSessionStore(_MemoryStore()),
    client: MockClient((_) async => http.Response('{}', 500)));

MatrixConversationSnapshot _snapshot(String id) => MatrixConversationSnapshot(
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

MatrixConversationSnapshot _directSnapshot() => MatrixConversationSnapshot(
      vaultRoomId: null,
      reminderRoomId: null,
      rooms: [
        MatrixConversationRoomSnapshot(
          id: '!direct:test',
          displayName: 'Public peer',
          avatar: null,
          isDirect: true,
          directPeerId: '@peer:matrix.example',
          members: const [
            MatrixMemberSnapshot(
                id: '@peer:matrix.example',
                displayName: 'Public peer',
                avatar: null),
          ],
          lastEvent: null,
          preference: const ConversationPreference(),
          notificationCount: 0,
          notificationsEnabled: true,
          name: 'Public peer',
          isJoined: true,
        ),
      ],
    );

ContactDetails _contact(String remark) => ContactDetails(
    userId: remark,
    username: remark,
    matrixUserId: '@peer:matrix.example',
    remark: remark);

final class _NoNetworkClient extends Client {
  _NoNetworkClient() : super('home-snapshot-refresh-test');
  @override
  String get userID => '@self:matrix.example';
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
