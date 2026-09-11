import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_read_state.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_home_page.dart';
import 'package:liuhetong_mobile/ui/theme/theme_controller.dart';
import 'package:matrix/matrix.dart';

void main() {
  testWidgets('same event ID content edit replaces the home preview',
      (tester) async {
    MatrixConversationSnapshot snapshot(String body) =>
        MatrixConversationSnapshot(
            vaultRoomId: null,
            reminderRoomId: null,
            rooms: [
              for (final id in ['!edit:test', '!sibling:test'])
                MatrixConversationRoomSnapshot(
                    id: id,
                    displayName: id,
                    avatar: null,
                    isDirect: false,
                    directPeerId: null,
                    members: const [],
                    lastEvent: MatrixEventSnapshot(
                        eventId: id == '!edit:test' ? r'$same' : r'$other',
                        type: 'm.room.message',
                        text: id == '!edit:test' ? body : 'sibling',
                        body: id == '!edit:test' ? body : 'sibling',
                        originServerTs: DateTime(2026, 9, 11),
                        senderId: '@peer:test',
                        sender: const MatrixMemberSnapshot(
                            id: '@peer:test',
                            displayName: 'Peer',
                            avatar: null),
                        redacted: false),
                    preference: const ConversationPreference(),
                    notificationCount: 0,
                    notificationsEnabled: true,
                    name: id)
            ]);
    var current = snapshot('old preview');
    final projected = <String>[];
    final matrix = MatrixSdkE2eeClient(_SnapshotClient(),
        homeserver: Uri.parse('https://matrix.example'));
    await tester.pumpWidget(CupertinoApp(
        home: MatrixHomePage(
            api: _api(),
            matrix: matrix,
            themeController: ThemeController(store: _ThemeStore()),
            onCreateGroup: () {},
            previewOnly: true,
            snapshotLoader: () async => current,
            onRoomProjection: projected.add)));
    await tester.pumpAndSettle();
    expect(find.textContaining('old preview'), findsOneWidget);
    projected.clear();
    current = snapshot('new preview');
    conversationPreferencesChanged.publish();
    await tester.pumpAndSettle();
    expect(projected, contains('!edit:test'));
    expect(find.textContaining('new preview'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('local unread clear reprojects a fixed event without a sync edit',
      (tester) async {
    ConversationReadState.shared().resetForTest();
    final event = MatrixEventSnapshot(
        eventId: r'$fixed',
        type: 'm.room.message',
        text: 'message',
        body: 'message',
        originServerTs: DateTime(2026, 9, 11),
        senderId: '@peer:test',
        sender: const MatrixMemberSnapshot(
            id: '@peer:test', displayName: 'Peer', avatar: null),
        redacted: false);
    final snapshot = MatrixConversationSnapshot(
        vaultRoomId: null,
        reminderRoomId: null,
        rooms: [
          MatrixConversationRoomSnapshot(
              id: '!read:test',
              displayName: 'Named group',
              avatar: null,
              isDirect: false,
              directPeerId: null,
              members: const [],
              lastEvent: event,
              preference: const ConversationPreference(),
              notificationCount: 5,
              notificationsEnabled: true,
              name: 'Named group')
        ]);
    final projected = <String>[];
    final matrix = MatrixSdkE2eeClient(_SnapshotClient(),
        homeserver: Uri.parse('https://matrix.example'));
    await tester.pumpWidget(CupertinoApp(
        home: MatrixHomePage(
            api: _api(),
            matrix: matrix,
            themeController: ThemeController(store: _ThemeStore()),
            onCreateGroup: () {},
            previewOnly: true,
            snapshotLoader: () async => snapshot,
            onRoomProjection: projected.add)));
    await tester.pumpAndSettle();
    expect(find.text('5'), findsOneWidget);
    projected.clear();
    ConversationReadState.shared()
        .markCleared('!read:test', eventId: r'$fixed');
    conversationPreferencesChanged.publish();
    await tester.pumpAndSettle();
    expect(projected, ['!read:test']);
    expect(find.text('5'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('real SDK home projects only its changed room', (tester) async {
    final client = _SnapshotClient();
    final groups = <_MeasuredRoom>[];
    for (var index = 0; index < 500; index++) {
      final room = _MeasuredRoom(id: '!room$index:test', client: client);
      if (index < 50) {
        groups.add(room);
        room.users.addAll([
          for (var member = 0; member < 1000; member++)
            User('@member$member:test',
                membership: 'join', displayName: 'Member $member', room: room)
        ]);
      }
      client.roomsForTest.add(room);
    }
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'));
    final first = await matrix.conversations.snapshot();
    final second = await matrix.conversations.snapshot();
    expect(identical(first.rooms.first, second.rooms.first), isFalse);
    expect(identical(first.rooms.first.members, second.rooms.first.members),
        isTrue);
    expect(groups.fold(0, (sum, room) => sum + room.participantReads), 50);
    final projected = <String>[];
    final identities = <String>[];
    final rowBuilds = <String>[];
    await tester.pumpWidget(CupertinoApp(
        home: MatrixHomePage(
            api: _api(),
            matrix: matrix,
            themeController: ThemeController(store: _ThemeStore()),
            onCreateGroup: () {},
            previewOnly: true,
            onRoomProjection: projected.add,
            onIdentityProjection: identities.add,
            onConversationRowBuild: rowBuilds.add)));
    await tester.pumpAndSettle();
    expect(projected, hasLength(500));
    expect(identities, isEmpty);
    expect(rowBuilds, isNotEmpty);
    projected.clear();
    rowBuilds.clear();
    conversationPreferencesChanged.publish();
    await tester.pumpAndSettle();
    expect(projected, isEmpty);
    expect(rowBuilds, isEmpty);
    final changed = User('@member0:test',
        membership: 'join', displayName: 'Renamed', room: groups.first);
    groups.first.users[0] = changed;
    groups.first.setState(changed);
    conversationPreferencesChanged.publish();
    await tester.pumpAndSettle();
    expect(projected, ['!room0:test']);
    expect(rowBuilds, ['!room0:test']);
    await tester.pumpWidget(const SizedBox());
  });
}

BusinessApiClient _api() => BusinessApiClient(
    baseUri: Uri.parse('https://business.example'),
    sessionStore: SecureSessionStore(_Store()),
    client: MockClient((_) async => http.Response('{}', 500)));

final class _SnapshotClient extends Client {
  _SnapshotClient() : super('home-projection-test');
  final roomsForTest = <Room>[];
  @override
  List<Room> get rooms => roomsForTest;
}

final class _MeasuredRoom extends Room {
  _MeasuredRoom({required super.id, required super.client});
  final users = <User>[];
  int participantReads = 0;
  @override
  String get name => 'Group $id';
  @override
  List<User> getParticipants(
      [List<Membership> membershipFilter = const [
        Membership.join,
        Membership.invite,
        Membership.knock
      ]]) {
    participantReads++;
    return users
        .where((user) => membershipFilter.contains(user.membership))
        .toList();
  }
}

final class _Store implements SecureKeyValueStore {
  @override
  Future<void> delete(String key) async {}
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
}

final class _ThemeStore implements ThemePreferenceStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async {}
}
