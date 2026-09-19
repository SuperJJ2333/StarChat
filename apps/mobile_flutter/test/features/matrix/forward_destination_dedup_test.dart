import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/features/matrix/duplicate_room_registry.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 私聊目标房间 fake：转发候选所需的全部判定面（加密/加入/可发/私聊身份）。
final class _DirectDestRoom extends Room {
  _DirectDestRoom({
    required super.client,
    required super.id,
    this.directPeer,
  });
  final String? directPeer;
  @override
  bool get encrypted => true;
  @override
  Membership get membership => Membership.join;
  @override
  bool get canSendDefaultMessages => true;
  @override
  bool get isDirectChat => directPeer != null;
  @override
  String? get directChatMatrixID => directPeer;
}

final class _ForwardDirectoryClient extends Client {
  _ForwardDirectoryClient()
      : super('forward-dedup',
            httpClient: MockClient((_) async => http.Response('{}', 200)));

  @override
  String? get userID => '@self:matrix.test';
  @override
  Uri? get homeserver => Uri.parse('https://matrix.test');

  // 字典序更大的房间排在前面：默认规则下它必须让位给 '!aaa'（规则四），
  // 登记簿指定 primary 时让位给 '!zzz'（规则一）。
  late final _DirectDestRoom stale =
      _DirectDestRoom(client: this, id: '!zzz:matrix.test', directPeer: '@peer:matrix.test');
  late final _DirectDestRoom canonical =
      _DirectDestRoom(client: this, id: '!aaa:matrix.test', directPeer: '@peer:matrix.test');
  late final _DirectDestRoom group =
      _DirectDestRoom(client: this, id: '!group:matrix.test');

  @override
  List<Room> get rooms => [stale, canonical, group];
  @override
  Room? getRoomById(String roomId) =>
      rooms.where((room) => room.id == roomId).firstOrNull;
}

MatrixSdkE2eeClient _matrix(_ForwardDirectoryClient client,
        {DuplicateRoomRegistry? registry}) =>
    MatrixSdkE2eeClient(
      client,
      homeserver: Uri.parse('https://matrix.test'),
      readContinuityMetadata: (active) async => MatrixClientContinuityMetadata(
          isLoggedIn: true,
          userId: active.userID,
          deviceId: active.deviceID,
          ed25519Fingerprint: 'fixture',
          databaseGeneration: 'fixture'),
      duplicateRooms: registry,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('转发/分享/群发目标：同一好友的两个私聊房间只出现一个入口', () async {
    final client = _ForwardDirectoryClient();
    final lease = await _matrix(client).openRoomLease(client.stale.id);
    final destinations = await lease.forwardingDestinations();
    expect(destinations.map((destination) => destination.id).toSet(),
        {'!aaa:matrix.test', '!group:matrix.test'},
        reason: '同 peer 双房间去重为一行；roomId 字典序兜底选出 !aaa（规则四）');
  });

  test('登记簿记录 canonical 后，转发目标按规则一选中 canonical', () async {
    final client = _ForwardDirectoryClient();
    final registry = DuplicateRoomRegistry();
    await registry.record(
        accountId: '@self:matrix.test',
        peerId: '@peer:matrix.test',
        primaryRoomId: '!zzz:matrix.test',
        duplicateRoomId: '!aaa:matrix.test');
    final lease = await _matrix(client, registry: registry)
        .openRoomLease(client.stale.id);
    final destinations = await lease.forwardingDestinations();
    expect(destinations.map((destination) => destination.id).toSet(),
        {'!zzz:matrix.test', '!group:matrix.test'},
        reason: 'canonical 优先级高于 roomId 字典序（规则一 > 规则四）');
  });
}
