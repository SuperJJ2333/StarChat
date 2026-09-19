import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/direct_room_directory_convergence.dart';
import 'package:liuhetong_mobile/features/matrix/duplicate_room_registry.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'direct_room_identity_integration_test.dart';
import 'matrix_client_factory_test.dart' show SnapshotClient;

final class AssociationClient extends SnapshotClient {
  final directory = <String, dynamic>{};
  final roomsById = <String, Room>{};
  final accountWrites = <Map<String, Object?>>[];
  @override
  Map<String, dynamic> get directChats => directory;
  @override
  List<Room> get rooms => roomsById.values.toList();
  @override
  Room? getRoomById(String id) => roomsById[id];
  @override
  Future<void> setAccountData(
      String userId, String type, Map<String, Object?> body) async {
    accountWrites.add(body);
    accountData[type] = BasicEvent(type: type, content: body);
    if (type == 'm.direct') {
      directory
        ..clear()
        ..addAll(body);
    }
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  AssociationClient fixture() {
    final client = AssociationClient();
    for (final id in ['!old:test', '!primary:test']) {
      client.roomsById[id] = IdentityFlowRoom(
          client: client,
          id: id,
          membership: Membership.join,
          summary: RoomSummary.fromJson({'m.joined_member_count': 2}));
    }
    client.directory['@peer:test'] = ['!old:test', '!primary:test'];
    return client;
  }

  test('canonical unavailable never destroys cross-device room identity',
      () async {
    final client = fixture();
    await convergeDirectDirectory(client,
        businessUserIdOf: (_) => 'peer',
        canonicalRoomIdOf: (_) async => throw StateError('offline'));
    expect(client.directory['@peer:test'], ['!old:test', '!primary:test']);
    expect(client.accountWrites, isEmpty);
  });

  test('canonical association syncs without deleting legacy m.direct sources',
      () async {
    final client = fixture();
    await convergeDirectDirectory(client,
        registry: DuplicateRoomRegistry(),
        businessUserIdOf: (_) => 'peer',
        canonicalRoomIdOf: (_) async => '!primary:test');
    expect(client.directory['@peer:test'], ['!old:test', '!primary:test']);
    expect(
        client.accountData.keys.any(
            (type) => type.startsWith('com.changliao.direct_conversation.')),
        isTrue);
  });
  test(
      'fresh device without m.direct restores primary and all historical identities',
      () async {
    final client = fixture()..directory.clear();
    final registry = DuplicateRoomRegistry();
    await convergeDirectDirectory(client,
        registry: registry,
        knownMatrixPeers: ['@peer:test'],
        businessUserIdOf: (_) => 'peer',
        associationsOf: (_) async => const DirectRoomAssociations(
            primaryRoomId: '!primary:test',
            roomIds: ['!old:test', '!primary:test']));
    expect(
        registry.peerIdForRoom(client.userID!, '!primary:test'), '@peer:test');
    expect(registry.peerIdForRoom(client.userID!, '!old:test'), '@peer:test');
    expect(client.directory, isEmpty);
  });
}
