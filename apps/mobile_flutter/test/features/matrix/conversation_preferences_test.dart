import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_preferences.dart';

final class _PreferenceClient extends Client {
  _PreferenceClient() : super('mute-preferences-test');

  final roomsById = <String, Room>{};
  @override
  List<Room> get rooms => roomsById.values.toList();
  @override
  Room? getRoomById(String roomId) => roomsById[roomId];

  @override
  String? get userID => activeUser;

  String? activeUser = '@alice:test';
  void Function()? afterAccountWrite;
  Future<void> Function()? afterPushWrite;

  final writes = <String>[];
  bool offline = false;
  bool pushOffline = false;

  @override
  Future<void> setAccountDataPerRoom(String userId, String roomId, String type,
      Map<String, Object?> data) async {
    writes.add('preference:$roomId');
    if (offline) throw StateError('offline');
    afterAccountWrite?.call();
  }

  @override
  Future<void> setPushRule(
      PushRuleKind kind, String ruleId, List<Object?> actions,
      {String? before,
      String? after,
      List<PushCondition>? conditions,
      String? pattern}) async {
    writes.add('push:${kind.name}:$ruleId:${actions.join(',')}');
    if (offline || pushOffline) throw StateError('offline');
    await afterPushWrite?.call();
  }

  @override
  Future<void> deletePushRule(PushRuleKind kind, String ruleId) async {
    writes.add('delete:${kind.name}:$ruleId');
    if (offline || pushOffline) throw StateError('offline');
  }
}

final class _HttpPreferenceClient extends Client {
  _HttpPreferenceClient(http.Client httpClient)
      : super('mute-http-test', httpClient: httpClient) {
    baseUri = Uri.parse('https://matrix.test/');
    bearerToken = 'test-token';
  }

  final roomsById = <String, Room>{};
  @override
  String? get userID => '@alice:test';
  @override
  List<Room> get rooms => roomsById.values.toList();
  @override
  Room? getRoomById(String roomId) => roomsById[roomId];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('muting writes a Matrix override after the preference', () async {
    final client = _PreferenceClient();
    final room = Room(id: '!muted:test', client: client);
    client.roomsById[room.id] = room;
    await saveLocalConversationPreference(
        room, const ConversationPreference(muted: true));
    await flushConversationPreferences(client);
    expect(client.writes.first, 'preference:!muted:test');
    expect(client.writes.where((write) => write.startsWith('push:override:')),
        hasLength(1));
    expect(client.writes.last, contains('dont_notify'));
  });

  test('unmuting removes only the app-owned rule', () async {
    final client = _PreferenceClient();
    final room = Room(id: '!muted:test', client: client);
    client.roomsById[room.id] = room;
    await saveLocalConversationPreference(
        room, const ConversationPreference(muted: true));
    await flushConversationPreferences(client);
    client.writes.clear();
    await saveLocalConversationPreference(room, const ConversationPreference());
    await flushConversationPreferences(client);
    expect(client.writes.where((write) => write.startsWith('delete:')),
        hasLength(1));
    expect(client.writes.last, startsWith('delete:override:com.liuhetong.'));
  });

  test('offline mute is retried on the next flush', () async {
    final client = _PreferenceClient()..offline = true;
    final room = Room(id: '!offline:test', client: client);
    client.roomsById[room.id] = room;
    await saveLocalConversationPreference(
        room, const ConversationPreference(muted: true));
    await flushConversationPreferences(client);
    client.offline = false;
    client.writes.clear();
    await flushConversationPreferences(client);
    expect(client.writes.where((write) => write.startsWith('push:override:')),
        hasLength(1));
  });

  test('offline mute survives recreating the Matrix client', () async {
    final offline = _PreferenceClient()..offline = true;
    final room = Room(id: '!restart:test', client: offline);
    offline.roomsById[room.id] = room;
    await saveLocalConversationPreference(
        room, const ConversationPreference(muted: true));
    await flushConversationPreferences(offline);

    final online = _PreferenceClient();
    online.roomsById[room.id] = Room(id: room.id, client: online);
    await loadConversationPreferences(online);
    await flushConversationPreferences(online);
    expect(online.writes.first, 'preference:!restart:test');
    expect(online.writes.last, startsWith('push:override:'));
  });

  test('rapid mute changes finish with the latest Matrix rule state', () async {
    final client = _PreferenceClient();
    final room = Room(id: '!rapid:test', client: client);
    client.roomsById[room.id] = room;
    await saveLocalConversationPreference(
        room, const ConversationPreference(muted: true));
    final first = flushConversationPreferences(client);
    await saveLocalConversationPreference(room, const ConversationPreference());
    await first;
    await flushConversationPreferences(client);
    expect(client.writes.last, startsWith('delete:override:com.liuhetong.'));
  });

  test('a push failure remains durable after the account-data write', () async {
    final client = _PreferenceClient()..pushOffline = true;
    final room = Room(id: '!retry:test', client: client);
    client.roomsById[room.id] = room;
    await saveLocalConversationPreference(
        room, const ConversationPreference(muted: true));
    await flushConversationPreferences(client);
    client.pushOffline = false;
    client.writes.clear();
    await flushConversationPreferences(client);
    expect(client.writes, hasLength(1));
    expect(client.writes.single, startsWith('push:override:'));
  });

  test('logout during account-data write prevents the following push write',
      () async {
    final client = _PreferenceClient();
    final room = Room(id: '!logout:test', client: client);
    client.roomsById[room.id] = room;
    await saveLocalConversationPreference(
        room, const ConversationPreference(muted: true));
    client.afterAccountWrite = () => client.activeUser = null;
    await flushConversationPreferences(client,
        shouldContinue: () => client.userID != null);
    expect(client.writes, ['preference:!logout:test']);
  });

  test('an old muted account preference is projected to Matrix push', () async {
    final client = _PreferenceClient();
    final room = Room(id: '!legacy:test', client: client);
    room.roomAccountData['com.liuhetong.group_chat.settings.v1'] =
        BasicRoomEvent(
            type: 'com.liuhetong.group_chat.settings.v1',
            content: {'muted': true});
    client.roomsById[room.id] = room;
    await loadConversationPreferences(client);
    await flushConversationPreferences(client);
    expect(client.writes, hasLength(1));
    expect(client.writes.single, startsWith('push:override:'));
  });

  test('remote unmute removes an app rule applied by this device', () async {
    final client = _PreferenceClient();
    final room = Room(id: '!remote-unmute:test', client: client);
    client.roomsById[room.id] = room;
    final muted = ConversationPreference.fromContent({'muted': true});
    await saveLocalConversationPreference(room, muted);
    await flushConversationPreferences(client);
    room.roomAccountData[conversationPreferenceType] = BasicRoomEvent(
        type: conversationPreferenceType, content: muted.toContent());
    await reconcileConversationPreferences(client);
    client.writes.clear();
    room.roomAccountData[conversationPreferenceType] = BasicRoomEvent(
        type: conversationPreferenceType,
        content: const ConversationPreference(muted: false).toContent());
    await loadConversationPreferences(client);
    await flushConversationPreferences(client);
    expect(client.writes, hasLength(1));
    expect(client.writes.single, startsWith('delete:override:'));
  });

  test('remote unmute cancels a failed legacy mute migration', () async {
    final client = _PreferenceClient()..pushOffline = true;
    final room = Room(id: '!failed-migration:test', client: client);
    client.roomsById[room.id] = room;
    room.roomAccountData[conversationPreferenceType] = BasicRoomEvent(
        type: conversationPreferenceType, content: {'muted': true});
    await loadConversationPreferences(client);
    await flushConversationPreferences(client);
    room.roomAccountData[conversationPreferenceType] = BasicRoomEvent(
        type: conversationPreferenceType, content: {'muted': false});
    client.pushOffline = false;
    client.writes.clear();
    await loadConversationPreferences(client);
    await flushConversationPreferences(client);
    expect(client.writes.where((write) => write.startsWith('push:')), isEmpty);
    expect(client.writes.single, startsWith('delete:override:'));
  });

  test('in-flight legacy mute drains a newer remote unmute', () async {
    final entered = Completer<void>();
    final held = Completer<void>();
    final client = _PreferenceClient()
      ..afterPushWrite = () {
        if (!entered.isCompleted) entered.complete();
        return held.future;
      };
    final room = Room(id: '!held-migration:test', client: client);
    client.roomsById[room.id] = room;
    room.roomAccountData[conversationPreferenceType] = BasicRoomEvent(
        type: conversationPreferenceType, content: {'muted': true});
    await loadConversationPreferences(client);
    final flush = flushConversationPreferences(client);
    await entered.future;
    room.roomAccountData[conversationPreferenceType] = BasicRoomEvent(
        type: conversationPreferenceType, content: {'muted': false});
    await loadConversationPreferences(client);
    held.complete();
    await flush;
    expect(client.writes.last, startsWith('delete:override:'));
  });

  test('mute rule uses the SDK HTTP API with room_id condition', () async {
    final requests = <http.Request>[];
    final client = _HttpPreferenceClient(MockClient((request) async {
      requests.add(request);
      return http.Response('{}', 200);
    }));
    final room = Room(id: '!wire:test', client: client);
    client.roomsById[room.id] = room;
    await saveLocalConversationPreference(
        room, const ConversationPreference(muted: true));
    await flushConversationPreferences(client);
    final push = requests.singleWhere(
        (request) => request.url.path.contains('/pushrules/global/override/'));
    expect(push.method, 'PUT');
    expect(push.body, contains('"dont_notify"'));
    expect(push.body, contains('"room_id"'));
    expect(push.body, contains('!wire:test'));
    await saveLocalConversationPreference(room, const ConversationPreference());
    await flushConversationPreferences(client);
    final deletes = requests.where((request) => request.method == 'DELETE');
    expect(deletes, hasLength(1));
    expect(deletes.single.url.pathSegments.last,
        conversationMutePushRuleId('!wire:test'));
  });
  test('latest pin comes first despite new activity', () {
    final first = ConversationProjection(
      roomId: '!first:test',
      isGroup: true,
      lastActivity: DateTime.utc(2026, 8, 18, 12),
      preference: ConversationPreference(
        pinned: true,
        pinnedAt: DateTime.utc(2026, 8, 18, 8),
      ),
    );
    final second = ConversationProjection(
      roomId: '!second:test',
      isGroup: true,
      lastActivity: DateTime.utc(2026, 8, 18, 10),
      preference: ConversationPreference(
        pinned: true,
        pinnedAt: DateTime.utc(2026, 8, 18, 9),
      ),
    );

    expect(orderConversations([second, first]), [second, first]);
  });

  test('ordinary conversations use descending activity order', () {
    final old = ConversationProjection(
      roomId: '!old:test',
      isGroup: false,
      lastActivity: DateTime.utc(2026, 8, 17),
    );
    final latest = ConversationProjection(
      roomId: '!latest:test',
      isGroup: false,
      lastActivity: DateTime.utc(2026, 8, 18),
    );
    expect(orderConversations([old, latest]), [latest, old]);
  });

  test('preference codec preserves notification exceptions and pin time', () {
    final preference = ConversationPreference.fromContent({
      'pinned': true,
      'pinned_at': '2026-08-18T08:00:00.000Z',
      'muted': true,
      'folded': true,
      'notify_mention_me': true,
      'notify_mention_all': false,
      'notify_announcement': true,
      'followed_member_ids': ['@a:test', '@b:test'],
    });
    expect(preference.pinnedAt, DateTime.utc(2026, 8, 18, 8));
    expect(preference.folded, isTrue);
    expect(preference.followedMemberIds, ['@a:test', '@b:test']);
    expect(preference.toContent()['notify_mention_all'], isFalse);
  });

  test('muting a fresh room starts with every exception disabled', () {
    final preference = ConversationPreference.fromContent({'muted': true});
    expect(preference.notifyMentionMe, isFalse);
    expect(preference.notifyMentionAll, isFalse);
    expect(preference.notifyAnnouncement, isFalse);
  });

  test('legacy muted true defaults do not imply explicit exceptions', () {
    final legacy = ConversationPreference.fromContent({
      'muted': true,
      'notify_mention_me': true,
      'notify_mention_all': true,
      'notify_announcement': true,
    });
    expect(legacy.notifyMentionMe, isFalse);
    expect(legacy.notifyMentionAll, isFalse);
    expect(legacy.notifyAnnouncement, isFalse);
    final explicit = ConversationPreference.fromContent({
      'muted': true,
      'mute_exceptions_explicit': true,
      'notify_mention_me': true,
    });
    expect(explicit.notifyMentionMe, isTrue);
  });

  test('preference rewrite preserves group remark and unknown settings', () {
    final before = ConversationPreference.fromContent({
      'muted': false,
      'remark': '项目群',
      'future_setting': {'enabled': true},
    });
    final after = before.copyWith(muted: true).toContent();
    expect(after['remark'], '项目群');
    expect(after['future_setting'], {'enabled': true});
  });

  test('member order removes leavers and appends new or rejoined members', () {
    expect(
      reconcileMemberOrder(
        const ['@a:test', '@b:test', '@c:test'],
        const ['@a:test', '@c:test', '@d:test'],
      ),
      const ['@a:test', '@c:test', '@d:test'],
    );
    expect(
      reconcileMemberOrder(
        const ['@a:test', '@c:test', '@d:test'],
        const ['@a:test', '@b:test', '@c:test', '@d:test'],
      ),
      const ['@a:test', '@c:test', '@d:test', '@b:test'],
    );
  });
}
