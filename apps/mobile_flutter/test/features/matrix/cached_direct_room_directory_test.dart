import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/cached_direct_room_directory.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_controller.dart';

class Directory implements CanonicalDirectRoomDirectory {
  Future<String?> Function() lookup = () async => '!room:server';
  @override
  Future<String?> canonicalRoomId(String peer) => lookup();
  @override
  Future<String?> registerRoom(String peer, String room) async => room;
}

void main() {
  test(
      'known authoritative room opens while directory network waits; account isolated',
      () async {
    SharedPreferences.setMockInitialValues({});
    final upstream = Directory();
    final cache =
        CachedDirectRoomDirectory(accountId: 'alice', upstream: upstream);
    expect(await cache.canonicalRoomId('bob'), '!room:server');
    final gate = Completer<String?>();
    upstream.lookup = () => gate.future;
    final restored =
        CachedDirectRoomDirectory(accountId: 'alice', upstream: upstream);
    expect(
        await restored
            .canonicalRoomId('bob')
            .timeout(const Duration(seconds: 1)),
        '!room:server');
    var otherCompleted = false;
    final other =
        CachedDirectRoomDirectory(accountId: 'carol', upstream: upstream)
            .canonicalRoomId('bob')
            .then((value) => otherCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(otherCompleted, isFalse);
    gate.complete('!replacement:server');
    await other;
  });
}
