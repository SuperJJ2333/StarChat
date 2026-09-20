import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_read_state.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'matrix_client_factory_test.dart'
    show MatrixTestPaths, SnapshotClient, SnapshotRoom;

/// BUG-23 残余自愈夹具：服务器未读挂在尾部为通话信令的房间上
/// （通话中进程被杀 → 重启后信令仍未读）。
final class CallTailRoom extends SnapshotRoom {
  CallTailRoom({
    required super.client,
    required super.id,
    this.unread = 2,
    bool manualUnread = false,
  }) : super(joined: true) {
    if (manualUnread) {
      roomAccountData[conversationPreferenceType] = BasicRoomEvent(
        type: conversationPreferenceType,
        content: const {'manual_unread': true},
      );
    }
  }

  final int unread;
  final readMarkers = <String>[];

  @override
  bool get isDirectChat => true;
  @override
  String? get directChatMatrixID => '@peer:test';
  @override
  int get notificationCount => unread;

  @override
  Future<void> setReadMarker(String? eventId,
      {String? mRead, bool? public}) async {
    readMarkers.add(eventId!);
  }
}

Event _tail(Room room, String type, String eventId) => Event(
    room: room,
    type: type,
    eventId: eventId,
    senderId: '@peer:test',
    originServerTs: DateTime.utc(2026, 9, 20),
    content: const {});

void main() {
  setUp(() {
    PathProviderPlatform.instance = MatrixTestPaths();
    SharedPreferences.setMockInitialValues({});
    ConversationReadState.shared().resetForTest();
  });

  test('尾部为通话终态信令且仍有服务器未读 → 静默推进一次已读', () async {
    final client = SnapshotClient();
    final room = CallTailRoom(client: client, id: '!call:test');
    room.snapshotEvent = _tail(room, 'm.call.hangup', r'$hangup');
    client.snapshotRooms.add(room);
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));

    await matrix.conversations.snapshot();
    expect(room.readMarkers, [r'$hangup'],
        reason: '通话终态信令虚增的服务器未读必须自愈：推进到尾部事件');

    await matrix.conversations.snapshot();
    expect(room.readMarkers, [r'$hangup'],
        reason: '同一尾部事件只推进一次，不得在每次快照重复发送已读回执');
  });

  test('invite 尾部不是终态——通话可能仍在进行，不触发自愈', () async {
    final client = SnapshotClient();
    final room = CallTailRoom(client: client, id: '!ring:test');
    room.snapshotEvent = _tail(room, 'm.call.invite', r'$invite');
    client.snapshotRooms.add(room);
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));

    await matrix.conversations.snapshot();

    expect(room.readMarkers, isEmpty, reason: '来电/通话中不得推进已读');
  });

  test('尾部是普通消息时不触发自愈', () async {
    final client = SnapshotClient();
    final room = CallTailRoom(client: client, id: '!chat:test');
    room.snapshotEvent = Event(
        room: room,
        type: EventTypes.Message,
        eventId: r'$msg',
        senderId: '@peer:test',
        originServerTs: DateTime.utc(2026, 9, 20),
        content: {'body': 'hello'});
    client.snapshotRooms.add(room);
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));

    await matrix.conversations.snapshot();

    expect(room.readMarkers, isEmpty, reason: '真实消息未读只能由用户查看消除');
  });

  test('手动未读优先于自愈', () async {
    final client = SnapshotClient();
    final room = CallTailRoom(
        client: client, id: '!manual:test', manualUnread: true);
    room.snapshotEvent = _tail(room, 'm.call.hangup', r'$hangup2');
    client.snapshotRooms.add(room);
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));

    await matrix.conversations.snapshot();

    expect(room.readMarkers, isEmpty, reason: 'BUG-15 手动未读必须保持');
  });
}
