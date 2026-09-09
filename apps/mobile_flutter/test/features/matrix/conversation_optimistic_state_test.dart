import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'local_conversation_delete_test.dart' show LocalDeleteRoom;
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_read_state.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'matrix_client_factory_test.dart'
    show SnapshotClient, SnapshotRoom, MatrixTestPaths;

class PendingPreferenceClient extends SnapshotClient {
  PendingPreferenceClient([this.accountId = '@me:test']);
  final String accountId;
  @override
  String? get userID => accountId;
  final pending = Completer<void>();
  final writes = <Map<String, dynamic>>[];
  @override
  Future<void> setAccountDataPerRoom(
      String userId, String roomId, String type, Map<String, dynamic> content) {
    writes.add(content);
    return pending.future;
  }
}

void main() {
  setUp(() => PathProviderPlatform.instance = MatrixTestPaths());
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ConversationReadState.shared().resetForTest();
  });
  test(
      'pin and unread update with network pending, survive restart and clear on open',
      () async {
    final client = PendingPreferenceClient();
    final room =
        SnapshotRoom(id: '!optimistic:test', client: client, joined: true);
    client.snapshotRooms.add(room);
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    try {
      await matrix.conversations
          .mutate(room.id, MatrixConversationMutation.togglePin)
          .timeout(const Duration(milliseconds: 250));
      await matrix.conversations
          .mutate(room.id, MatrixConversationMutation.markUnread)
          .timeout(const Duration(milliseconds: 250));
      final preference =
          (await matrix.conversations.snapshot()).rooms.single.preference;
      expect(preference.pinned, isTrue);
      expect(preference.manualUnread, isTrue);
      expect(preference.pinnedAt, isNotNull);
      final restartedClient = PendingPreferenceClient();
      restartedClient.snapshotRooms.add(
          SnapshotRoom(id: room.id, client: restartedClient, joined: true));
      final restarted = MatrixSdkE2eeClient(restartedClient,
          homeserver: Uri.parse('https://test'));
      final restored =
          (await restarted.conversations.snapshot()).rooms.single.preference;
      expect(restored.pinnedAt, preference.pinnedAt);
      expect(restored.manualUnread, isTrue);
      await restarted.conversations
          .markReadOnOpen(room.id)
          .timeout(const Duration(milliseconds: 250));
      expect(
          (await restarted.conversations.snapshot())
              .rooms
              .single
              .preference
              .manualUnread,
          isFalse);
      await restarted.conversations
          .mutate(room.id, MatrixConversationMutation.togglePin)
          .timeout(const Duration(milliseconds: 250));
      expect(
          (await restarted.conversations.snapshot())
              .rooms
              .single
              .preference
              .pinned,
          isFalse);
      restartedClient.pending.complete();
    } finally {
      client.pending.complete();
    }
  });
  test('all-room unread clear is immediate while remote writes are pending',
      () async {
    final client = PendingPreferenceClient();
    final room = LocalDeleteRoom(id: '!all-read:test', client: client);
    room.snapshotEvent = Event(
        room: room,
        type: EventTypes.Message,
        eventId: 'old',
        senderId: '@peer:test',
        originServerTs: DateTime.utc(2026),
        content: {'body': 'fixture'});
    client.snapshotRooms.add(room);
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    await matrix.conversations
        .mutate(room.id, MatrixConversationMutation.markUnread);
    expect(await matrix.conversations.totalUnreadCount(), 1);
    await matrix.conversations
        .clearAllUnread()
        .timeout(const Duration(milliseconds: 250));
    expect(await matrix.conversations.totalUnreadCount(), 0);
    expect(
        (await matrix.conversations.snapshot())
            .rooms
            .single
            .preference
            .manualUnread,
        isFalse);
    await matrix.conversations
        .mutate(room.id, MatrixConversationMutation.markUnread);
    expect(await matrix.conversations.totalUnreadCount(), 1,
        reason: 'Explicit manual unread overrides the previous clear boundary');
    client.pending.complete();
  });

  test('acknowledgement does not roll back latest local edit before sync',
      () async {
    final client = PendingPreferenceClient();
    final room = SnapshotRoom(id: '!stale:test', client: client, joined: true);
    client.snapshotRooms.add(room);
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    await matrix.conversations
        .mutate(room.id, MatrixConversationMutation.togglePin);
    await matrix.conversations
        .mutate(room.id, MatrixConversationMutation.togglePin);
    await matrix.conversations
        .mutate(room.id, MatrixConversationMutation.markUnread);
    client.pending.complete();
    await Future<void>.delayed(Duration.zero);
    final state =
        (await matrix.conversations.snapshot()).rooms.single.preference;
    expect(state.pinned, isFalse);
    expect(state.manualUnread, isTrue);
    expect(client.writes.last['pinned'], false);
    expect(client.writes.last['manual_unread'], true);
    expect(preferenceForRoom(room).manualUnread, isTrue);
  });
  test('explicit local deletion removes pending preferences for this account',
      () async {
    final client = PendingPreferenceClient();
    client.pending.complete();
    final room = SnapshotRoom(
        id: '!delete-preferences:test', client: client, joined: true);
    client.snapshotRooms.add(room);
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'), clearClientData: (_) async {});
    await matrix.conversations
        .mutate(room.id, MatrixConversationMutation.togglePin);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('conversation_preferences.v1.${client.userID}'),
        isTrue);
    await matrix.clearLocalChatData();
    expect(prefs.containsKey('conversation_preferences.v1.${client.userID}'),
        isFalse);
  });
  test('matching sync releases overlay so later remote preferences are visible',
      () async {
    final client = PendingPreferenceClient();
    client.pending.complete();
    final room = SnapshotRoom(id: '!ack:test', client: client, joined: true);
    client.snapshotRooms.add(room);
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    await matrix.conversations
        .mutate(room.id, MatrixConversationMutation.togglePin);
    await Future<void>.delayed(Duration.zero);
    final local = preferenceForRoom(room);
    room.roomAccountData[conversationPreferenceType] = BasicRoomEvent(
        roomId: room.id,
        type: conversationPreferenceType,
        content: local.toContent());
    expect(
        (await matrix.conversations.snapshot()).rooms.single.preference.pinned,
        isTrue);
    room.roomAccountData[conversationPreferenceType] = BasicRoomEvent(
        roomId: room.id,
        type: conversationPreferenceType,
        content:
            local.copyWith(pinned: false, clearPinnedAt: true).toContent());
    expect(
        (await matrix.conversations.snapshot()).rooms.single.preference.pinned,
        isFalse);
  });
  test('clearing account A never suppresses account B in the same room',
      () async {
    MatrixSdkE2eeClient owner(String accountId) {
      final client = PendingPreferenceClient(accountId)..pending.complete();
      final room = LocalDeleteRoom(id: '!shared:test', client: client);
      room.snapshotEvent = Event(
          room: room,
          type: EventTypes.Message,
          eventId: 'shared-event',
          senderId: '@peer:test',
          originServerTs: DateTime.utc(2026),
          content: {});
      client.snapshotRooms.add(room);
      return MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    }

    final first = owner('@a:test');
    await first.conversations.clearAllUnread();
    expect(await first.conversations.totalUnreadCount(), 0);
    final second = owner('@b:test');
    expect(await second.conversations.totalUnreadCount(), 5);
  });

  test('corrupt local preferences do not prevent loading conversations',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('conversation_preferences.v1.@me:test', '{broken');
    final client = PendingPreferenceClient()..pending.complete();
    client.snapshotRooms
        .add(SnapshotRoom(id: '!corrupt:test', client: client, joined: true));
    final owner =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    expect(
        (await owner.conversations.snapshot()).rooms.single.preference.pinned,
        isFalse);
  });
}
